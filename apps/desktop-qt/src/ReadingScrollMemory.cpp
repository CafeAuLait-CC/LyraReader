#include "ReadingScrollMemory.h"
#include "ReaderController.h"
#include <QCache>
#include <QKeyEvent>
#include <QLoggingCategory>
#include <QQuickItem>
#include <QQuickWindow>
#include <cmath>

// Reader-owned UI state also follows a transferred tab. Cache eviction forgets
// an old view position only; it cannot alter notes, drafts, records or requests.
class ReadingScrollState final : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    quint64 generation = 0;
    QCache<QString, QPointF> positions{512};
};
namespace {
Q_LOGGING_CATEGORY(scrollTrace, "lyra.reading.scroll", QtWarningMsg)
ReadingScrollState *state(ReaderController *reader) {
    auto *result = reader->findChild<ReadingScrollState *>(QString(), Qt::FindDirectChildrenOnly);
    if (!result) result = new ReadingScrollState(reader);
    if (result->generation != reader->documentGeneration()) {
        result->positions.clear();
        result->generation = reader->documentGeneration();
    }
    return result;
}
bool dimension(QObject *object, const char *name, double &value) {
    bool ok = false; value = object->property(name).toDouble(&ok);
    return ok && std::isfinite(value);
}
}
void ReadingScrollMemory::trace(const char *event) const {
    // Opt-in UI diagnostics contain no file paths, text, questions or note IDs.
    const auto role = [](const QString &key) {
        if (key == "summary" || key == "notes" || key == "translation-document" || key == "translation-selection") return key;
        return key.startsWith("note-") ? QStringLiteral("note") : QStringLiteral("other");
    };
    qCDebug(scrollTrace) << event << "helper" << reinterpret_cast<quintptr>(this)
        << "reader/bound" << reinterpret_cast<quintptr>(m_reader.data()) << reinterpret_cast<quintptr>(m_boundReader.data())
        << "key/bound" << role(m_key) << role(m_boundKey) << "gen/epoch" << m_generation << m_epoch
        << "active/ready/restoring/user/valid" << m_active << m_ready << m_restoring << m_userOverride << m_lastValid
        << "target/last" << m_target << m_last
        << "view-y/h/extent" << (m_viewport ? m_viewport->property("contentY") : QVariant())
        << (m_viewport ? m_viewport->height() : 0) << (m_viewport ? m_viewport->property("contentHeight") : QVariant());
}
ReadingScrollMemory::ReadingScrollMemory(QObject *parent) : QObject(parent) {
    m_update.setSingleShot(true); m_clamp.setSingleShot(true);
    connect(&m_update, &QTimer::timeout, this, &ReadingScrollMemory::update);
    connect(&m_clamp, &QTimer::timeout, this, [this] {
        if (m_clampEpoch == m_epoch) restore(true);
    });
}
ReadingScrollMemory::~ReadingScrollMemory() {
    flush();
    if (m_window) m_window->removeEventFilter(this);
}
ReaderController *ReadingScrollMemory::reader() const { return m_reader; }
QQuickItem *ReadingScrollMemory::viewport() const { return m_viewport; }
void ReadingScrollMemory::setReader(ReaderController *reader) {
    if (m_reader == reader) return;
    flush();
    for (const auto &connection : m_readerConnections) QObject::disconnect(connection);
    m_readerConnections.clear(); m_reader = reader;
    if (reader) {
        m_readerConnections.append(connect(reader, &ReaderController::documentChanged, this, [this] {
            if (m_reader && m_reader->documentGeneration() != m_generation) rebind();
            else geometryChanged();
        }));
        m_readerConnections.append(connect(reader, &ReaderController::loadingChanged, this, &ReadingScrollMemory::geometryChanged));
        m_readerConnections.append(connect(reader, &QObject::destroyed, this, [this] { rebind(); emit readerChanged(); }));
    }
    rebind(); emit readerChanged();
}
void ReadingScrollMemory::setViewport(QQuickItem *viewport) {
    if (m_viewport == viewport) return;
    flush();
    for (const auto &connection : m_viewConnections) QObject::disconnect(connection);
    m_viewConnections.clear(); m_viewport = viewport;
    if (viewport) {
        if (viewport->metaObject()->indexOfProperty("contentY") >= 0) {
        m_viewConnections.append(connect(viewport, SIGNAL(contentXChanged()), this, SLOT(positionChanged())));
        m_viewConnections.append(connect(viewport, SIGNAL(contentYChanged()), this, SLOT(positionChanged())));
        for (const auto *signal : {SIGNAL(contentWidthChanged()), SIGNAL(contentHeightChanged()), SIGNAL(originXChanged()), SIGNAL(originYChanged())})
            m_viewConnections.append(connect(viewport, signal, this, SLOT(geometryChanged())));
        m_viewConnections.append(connect(viewport, SIGNAL(movementStarted()), this, SLOT(movementStarted())));
        }
        m_viewConnections.append(connect(viewport, &QQuickItem::widthChanged, this, &ReadingScrollMemory::geometryChanged));
        m_viewConnections.append(connect(viewport, &QQuickItem::heightChanged, this, &ReadingScrollMemory::geometryChanged));
        m_viewConnections.append(connect(viewport, &QQuickItem::visibleChanged, this, &ReadingScrollMemory::geometryChanged));
        m_viewConnections.append(connect(viewport, &QQuickItem::windowChanged, this, [this] { bindWindow(); geometryChanged(); }));
        m_viewConnections.append(connect(viewport, &QObject::destroyed, this, [this] { rebind(); bindWindow(); emit viewportChanged(); }));
    }
    bindWindow(); rebind(); emit viewportChanged();
}
void ReadingScrollMemory::setKey(const QString &key) {
    if (m_key == key) return;
    flush(); m_key = key; rebind(); emit keyChanged();
}
void ReadingScrollMemory::setActive(bool active) {
    if (m_active == active) return;
    flush(); m_active = active; rebind(); emit activeChanged();
}
void ReadingScrollMemory::setReady(bool ready) {
    if (m_ready == ready) return;
    flush(); m_ready = ready; rebind();
    if (m_viewport && m_viewport->property("moving").toBool()) userIntent();
    emit readyChanged();
}
bool ReadingScrollMemory::eligible(bool requireReady) const {
    return m_active && (!requireReady || m_ready || m_userOverride) && m_reader && m_boundReader == m_reader
        && m_reader->documentGeneration() == m_generation && !m_reader->loading()
        && !m_key.isEmpty() && m_key.size() <= 256 && m_key == m_boundKey
        && m_viewport && m_viewport->isVisible();
}
bool ReadingScrollMemory::geometry(Geometry &result) const {
    if (!m_viewport || m_viewport->width() <= 0 || m_viewport->height() <= 0) return false;
    double x, y, ox, oy, width, height;
    if (!dimension(m_viewport, "contentX", x) || !dimension(m_viewport, "contentY", y)
        || !dimension(m_viewport, "originX", ox) || !dimension(m_viewport, "originY", oy)
        || !dimension(m_viewport, "contentWidth", width) || !dimension(m_viewport, "contentHeight", height)) return false;
    // Qt ItemView uses -1 for its automatic non-scrolling dimension. That
    // documented native sentinel has no scroll range; other negatives fail.
    if (width == -1) width = m_viewport->width();
    if (height == -1) height = m_viewport->height();
    if (width < 0 || height < 0) return false;
    result.origin = {ox, oy}; result.position = {x, y};
    result.maximum = {qMax(0.0, width - m_viewport->width()), qMax(0.0, height - m_viewport->height())};
    result.offset = {qBound(0.0, x - ox, result.maximum.x()), qBound(0.0, y - oy, result.maximum.y())};
    return true;
}
void ReadingScrollMemory::flush() {
    if (!m_lastValid || !m_boundReader || m_boundReader->documentGeneration() != m_generation || m_boundKey.isEmpty()) return;
    auto *cache = state(m_boundReader);
    if (auto *position = cache->positions.object(m_boundKey)) {
        if (*position != m_last) trace("store");
        *position = m_last;
    } else { trace("store-new"); cache->positions.insert(m_boundKey, new QPointF(m_last)); }
}
void ReadingScrollMemory::rebind() {
    flush(); ++m_epoch; m_update.stop(); m_clamp.stop(); m_setting = false;
    m_boundReader = m_reader; m_boundKey = m_key;
    m_generation = m_reader ? m_reader->documentGeneration() : 0;
    m_lastValid = false; m_restoring = true; m_userOverride = false; m_target = {};
    if (m_reader && !m_key.isEmpty() && m_key.size() <= 256)
        if (const auto *position = state(m_reader)->positions.object(m_key)) m_target = *position;
    trace("rebind"); geometryChanged();
}
void ReadingScrollMemory::geometryChanged() {
    if (!m_setting && eligible()) m_update.start(0);
}
void ReadingScrollMemory::positionChanged() {
    // Defer sampling until this event's owner/model bindings have settled.
    // A tab switch flushes the last settled position, never a new tab's clamp.
    if (!m_setting && eligible() && !m_restoring) m_update.start(0);
}
void ReadingScrollMemory::update() {
    if (!eligible()) return;
    if (m_restoring) restore(false);
    else remember();
}
void ReadingScrollMemory::restore(bool clamp) {
    if (!m_restoring || !eligible()) return;
    trace(clamp ? "restore-clamp" : "restore");
    const auto epoch = m_epoch; QPointer<ReadingScrollMemory> guard(this);
    const auto current = [&] { return guard && epoch == m_epoch && eligible(); };
    const auto layout = [&] {
        // ItemView can change its origin when it creates variable-height rows.
        // Settle visible native rows, then use the new origin rather than
        // repeatedly adding an old absolute contentY. No full-document work.
        if (m_viewport->metaObject()->indexOfMethod("forceLayout()") >= 0)
            QMetaObject::invokeMethod(m_viewport, "forceLayout", Qt::DirectConnection);
        return current();
    };
    m_setting = true;
    if (!layout()) { if (guard) m_setting = false; return; }
    Geometry value;
    if (!geometry(value)) { m_setting = false; return; }
    if (!clamp && (m_target.x() > value.maximum.x() + .5 || m_target.y() > value.maximum.y() + .5)) {
        m_setting = false; trace("await-extent");
        if (!m_clamp.isActive()) { m_clampEpoch = m_epoch; m_clamp.start(80); }
        return;
    }
    for (int pass = 0; pass < 4; ++pass) {
        if (!geometry(value)) break;
        const QPointF target{value.origin.x() + qBound(0.0, m_target.x(), value.maximum.x()),
                             value.origin.y() + qBound(0.0, m_target.y(), value.maximum.y())};
        m_viewport->setProperty("contentX", target.x());
        if (!current()) { if (guard) m_setting = false; return; }
        m_viewport->setProperty("contentY", target.y());
        if (!current() || !layout()) { if (guard) m_setting = false; return; }
        Geometry after; if (!geometry(after)) break;
        const QPointF expected{after.origin.x() + qBound(0.0, m_target.x(), after.maximum.x()),
                               after.origin.y() + qBound(0.0, m_target.y(), after.maximum.y())};
        if (qAbs(after.position.x() - expected.x()) < .5 && qAbs(after.position.y() - expected.y()) < .5) break;
    }
    // A genuinely changing layout keeps its nearest available native position;
    // never spin or fight input waiting for an exact geometry to materialize.
    m_setting = false; m_restoring = false; m_clamp.stop();
    remember();
}
void ReadingScrollMemory::remember() {
    if (!eligible()) return;
    Geometry value; if (!geometry(value)) return;
    m_last = value.offset; m_lastValid = true; flush();
}
void ReadingScrollMemory::capturePosition() {
    // Called before a validated, same-owner view model replaces its data. A
    // genuine input may have moved the viewport before the coalesced sampler
    // runs. Never replace an in-progress restore with its temporary geometry.
    if (!m_restoring && eligible()) remember();
}
void ReadingScrollMemory::resetPosition(ReaderController *expected, qulonglong generation, const QString &key) {
    // A source picker resets its destination timeline, not the timeline being
    // left. Ignore a stale UI callback; this optional state is never persisted.
    if (!expected || m_reader != expected || expected->documentGeneration() != generation
        || key.isEmpty() || key.size() > 256) return;
    const bool currentKey = m_boundKey == key;
    if (currentKey) m_lastValid = false;
    state(expected)->positions.insert(key, new QPointF);
    if (currentKey) rebind();
}
void ReadingScrollMemory::userIntent() {
    if (!eligible(false)) return;
    trace("user-intent");
    m_inputReader = m_reader; m_inputViewport = m_viewport;
    m_inputGeneration = m_generation; m_inputKey = m_key;
    ++m_epoch; m_clamp.stop(); m_update.stop(); m_restoring = false; m_userOverride = true;
    Geometry value;
    if (geometry(value)) { m_last = value.offset; m_lastValid = true; flush(); }
    // Let native input move first; this does not consume or synthesize input.
    m_update.start(0);
}
void ReadingScrollMemory::completeUserScroll() {
    // Lazy rows may suspend readiness during the wheel operation itself. The
    // completed input still wins, but can never cross into another owner/view.
    if (!eligible(false) || m_inputReader != m_reader || m_inputViewport != m_viewport
        || m_inputGeneration != m_generation || m_inputKey != m_key) return;
    userIntent();
    capturePosition();
}
void ReadingScrollMemory::bindWindow() {
    auto *window = m_viewport ? m_viewport->window() : nullptr;
    if (m_window == window) return;
    if (m_window) m_window->removeEventFilter(this);
    m_window = window;
    if (m_window) m_window->installEventFilter(this);
}
bool ReadingScrollMemory::eventFilter(QObject *object, QEvent *event) {
    if (object != m_window || !eligible(false)) return false;
    if (event->type() == QEvent::KeyPress) {
        const auto key = static_cast<QKeyEvent *>(event)->key();
        bool within = false;
        for (auto *item = m_window->activeFocusItem(); item; item = item->parentItem())
            if (item == m_viewport) { within = true; break; }
        if (within && (key == Qt::Key_Up || key == Qt::Key_Down || key == Qt::Key_Left || key == Qt::Key_Right
            || key == Qt::Key_PageUp || key == Qt::Key_PageDown || key == Qt::Key_Home || key == Qt::Key_End)) userIntent();
    }
    return false;
}
#include "ReadingScrollMemory.moc"
