#include "ReadingSourceHighlight.h"
#include <QFutureWatcher>
#include <QJsonValue>
#include <QtConcurrentRun>
#include <cmath>
#include <limits>

ReadingSourceHighlight::ReadingSourceHighlight(QObject *parent) : QObject(parent) {
    m_timer.setSingleShot(true);
    connect(&m_timer, &QTimer::timeout, this, &ReadingSourceHighlight::advance);
}
ReadingSourceHighlight::~ReadingSourceHighlight() {
    if (m_cancel) m_cancel->store(true);
}
bool ReadingSourceHighlight::reset() {
    cancelLookup();
    m_identity.reset();
    return clearFlash();
}
bool ReadingSourceHighlight::clearFlash() {
    m_timer.stop(); m_clock.invalidate();
    const bool changed = !m_state.isEmpty(); m_state.clear();
    return changed;
}
void ReadingSourceHighlight::cancelLookup() {
    ++m_epoch;
    if (m_cancel) m_cancel->store(true);
    m_pending.reset();
}
void ReadingSourceHighlight::clear() { if (reset()) emit stateChanged(); }
void ReadingSourceHighlight::setReader(ReaderController *reader) {
    if (m_reader == reader) return;
    const bool changed = reset();
    disconnect(m_documentConnection); disconnect(m_destroyedConnection);
    m_reader = reader;
    if (reader) {
        m_documentConnection = connect(reader, &ReaderController::documentChanged, this, [this] {
            if ((!m_state.isEmpty() || m_pending || m_running) && m_reader
                && (m_generation != m_reader->documentGeneration() || m_identity.lock() != m_reader->renderSource())) clear();
        });
        m_destroyedConnection = connect(reader, &QObject::destroyed, this, [this] {
            m_reader = nullptr;
            const bool changed = reset();
            const QPointer<ReadingSourceHighlight> alive(this);
            emit readerChanged();
            if (alive && changed) emit stateChanged();
        });
    }
    const QPointer<ReadingSourceHighlight> alive(this);
    emit readerChanged();
    if (alive && changed) emit stateChanged();
}
bool ReadingSourceHighlight::ready(int page) const {
    return m_reader && !m_reader->loading() && page >= 0 && page < m_reader->pageCount() && m_reader->renderSource();
}
void ReadingSourceHighlight::locate(int page, const QString &text) {
    if (!ready(page)) { emit failed(tr("The source document changed or is still loading.")); return; }
    // Like the Mac task, retain the current fading passage while the next lookup
    // runs. Its old deadline must not cancel that newer request when it expires.
    const bool changed = (m_generation != m_reader->documentGeneration() || m_identity.lock() != m_reader->renderSource()) && clearFlash();
    cancelLookup();
    m_generation = m_reader->documentGeneration(); m_identity = m_reader->renderSource();
    m_pending = Request{m_epoch, m_reader, m_generation, m_reader->renderSource(), page, text};
    const QPointer<ReadingSourceHighlight> alive(this);
    if (changed) emit stateChanged();
    if (alive) startPending();
}
void ReadingSourceHighlight::startPending() {
    if (m_running || !m_pending) return;
    const auto request = std::move(*m_pending); m_pending.reset();
    if (!request.reader || request.reader != m_reader || request.generation != m_reader->documentGeneration()
        || request.source != m_reader->renderSource()) return;
    m_running = true; m_cancel = std::make_shared<std::atomic_bool>(false);
    const auto cancelled = m_cancel;
    struct Result { QVariantList rects; QString error; };
    auto *watcher = new QFutureWatcher<Result>(this);
    connect(watcher, &QFutureWatcher<Result>::finished, this, [this, watcher, request] {
        const auto result = watcher->result(); watcher->deleteLater(); m_running = false;
        const QPointer<ReadingSourceHighlight> alive(this);
        if (request.epoch == m_epoch && request.reader && request.reader == m_reader
            && request.generation == m_reader->documentGeneration() && request.source == m_reader->renderSource()) {
            if (!result.error.isEmpty()) emit failed(result.error);
            else present(request.page, result.rects);
        }
        if (alive) startPending();
    });
    // One running lookup and one replaceable pending request. Cancellation can
    // skip a queued query; an already executing PDF call is not preempted.
    watcher->setFuture(QtConcurrent::run([request, cancelled] {
        Result result;
        const auto value = request.source->query({{"op", "ai_reading_source"}, {"page", request.page}, {"text", request.text}}, &result.error, cancelled);
        if (result.error.isEmpty()) {
            if (value.metaType() != QMetaType::fromType<QVariantList>()) result.error = QStringLiteral("Invalid source geometry response.");
            else result.rects = value.toList();
        }
        return result;
    }));
}
void ReadingSourceHighlight::show(int page, const QVariantList &rects) {
    if (!ready(page)) { emit failed(tr("The source document changed or is still loading.")); return; }
    const bool changed = reset();
    m_generation = m_reader->documentGeneration(); m_identity = m_reader->renderSource();
    const QPointer<ReadingSourceHighlight> alive(this);
    const auto epoch = m_epoch;
    if (changed) emit stateChanged();
    if (alive && epoch == m_epoch) present(page, rects);
}
void ReadingSourceHighlight::present(int page, const QVariantList &rects) {
    // Bound a native overlay's geometry separately from AI/request text limits.
    constexpr qsizetype maximumOverlayRects = 16384;
    if (rects.size() > maximumOverlayRects) { emit failed(tr("The source geometry exceeds the display budget.")); return; }
    QVariantList boxes;
    double firstY = 0;
    for (const auto &value : rects) {
        const auto row = value.toMap();
        double coordinates[4];
        int index = 0;
        for (const auto *key : {"x_pt", "y_pt", "width_pt", "height_pt"}) {
            const auto number = QJsonValue::fromVariant(row.value(QString::fromLatin1(key)));
            // The RHI eventually uses float vertices; retain ample transform
            // headroom before a file-controlled coordinate crosses that boundary.
            constexpr double maximumSceneCoordinate = double(std::numeric_limits<float>::max()) / 65536.;
            if (!number.isDouble() || !std::isfinite(number.toDouble())
                || std::abs(number.toDouble()) > maximumSceneCoordinate) { emit failed(tr("Invalid source geometry.")); return; }
            coordinates[index++] = number.toDouble();
        }
        if (coordinates[2] <= 0 || coordinates[3] <= 0) continue;
        if (!std::isfinite(coordinates[0] + coordinates[2]) || !std::isfinite(coordinates[1] + coordinates[3])) {
            emit failed(tr("Invalid source geometry.")); return;
        }
        firstY = boxes.isEmpty() ? coordinates[1] : qMin(firstY, coordinates[1]);
        boxes.append(QVariantMap{{"x", coordinates[0]}, {"y", coordinates[1]}, {"width", coordinates[2]}, {"height", coordinates[3]}});
    }
    const QPointer<ReadingSourceHighlight> alive(this);
    const auto epoch = m_epoch;
    if (!boxes.isEmpty()) {
        m_clock.start(); m_timer.start(450);
        m_state = {{"page", page}, {"rects", boxes}, {"phase", "full"}};
        emit stateChanged();
    } else if (clearFlash()) emit stateChanged();
    if (alive && epoch == m_epoch) emit revealed(page, qMax(0., firstY - 40.));
}
void ReadingSourceHighlight::advance() {
    if (m_state.isEmpty() || !m_clock.isValid()) return;
    const auto elapsed = m_clock.elapsed();
    if (elapsed >= 1400) { if (clearFlash()) emit stateChanged(); return; }
    const QString phase = elapsed >= 900 ? QStringLiteral("faint") : elapsed >= 450 ? QStringLiteral("soft") : QStringLiteral("full");
    const auto next = elapsed >= 900 ? 1400 : elapsed >= 450 ? 900 : 450;
    m_timer.start(int(qMax<qint64>(1, next - elapsed)));
    if (m_state.value("phase").toString() != phase) { m_state.insert("phase", phase); emit stateChanged(); }
}
