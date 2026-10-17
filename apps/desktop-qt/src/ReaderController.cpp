#include "ReaderController.h"
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QtConcurrentRun>
#include <cmath>

namespace {
QString takeError(ArisBuffer &buffer) {
    const auto message = QString::fromUtf8(reinterpret_cast<const char *>(buffer.data), qsizetype(buffer.len));
    aris_reader_desktop_buffer_free(buffer);
    buffer = {};
    return message;
}
struct OpenResult {
    std::shared_ptr<ArisDesktopDocument> document;
    QVariantList pages;
    double width = 0;
    QString error;
};
struct RasterResult { QImage image; QString error; double actualScale = 0; qint64 elapsedMs = 0; };
void releasePixels(void *info) {
    auto *buffer = static_cast<ArisBuffer *>(info);
    aris_reader_desktop_buffer_free(*buffer);
    delete buffer;
}
}

ReaderController::ReaderController(QObject *parent) : QObject(parent) {}

void ReaderController::setError(const QString &error) {
    if (m_error == error) return;
    m_error = error;
    emit errorChanged();
}

void ReaderController::dismissError() { setError({}); }

void ReaderController::openFile(const QUrl &url, const QString &password) {
    if (!url.isLocalFile()) {
        setError(tr("Choose a local PDF file. This version cannot open remote URLs."));
        return;
    }
    m_lastUrl = url;
    const auto generation = ++m_generation;
    m_document.reset();
    m_pages.clear();
    m_cache.clear();
    m_pending.clear();
    m_failed.clear();
    m_requests.clear();
    m_documentWidth = 0;
    m_title = QFileInfo(url.toLocalFile()).fileName();
    m_loading = true;
    m_passwordRequired = false;
    setError({});
    emit documentReset();
    emit documentChanged();
    emit loadingChanged();
    emit passwordRequiredChanged();
    auto *watcher = new QFutureWatcher<OpenResult>(this);
    connect(watcher, &QFutureWatcher<OpenResult>::finished, this, [this, watcher, generation] {
        auto result = watcher->result();
        watcher->deleteLater();
        if (generation != m_generation) return;
        m_loading = false;
        emit loadingChanged();
        if (!result.error.isEmpty()) {
            setError(result.error);
            m_passwordRequired = result.error.startsWith(QStringLiteral("Encrypted:"));
            emit passwordRequiredChanged();
            emit openFinished(false);
            return;
        }
        m_document = std::move(result.document);
        m_pages = std::move(result.pages);
        m_documentWidth = result.width;
        emit documentChanged();
        emit openFinished(true);
    });
    const auto path = url.toLocalFile().toUtf8();
    const auto secret = password.toUtf8();
    watcher->setFuture(QtConcurrent::run([path, secret] {
        OpenResult result;
        ArisBuffer error{}, info{};
        auto *raw = aris_reader_desktop_open(reinterpret_cast<const std::uint8_t *>(path.constData()), path.size(),
            secret.isEmpty() ? nullptr : reinterpret_cast<const std::uint8_t *>(secret.constData()), secret.size(), &error);
        if (!raw) { result.error = takeError(error); return result; }
        result.document = std::shared_ptr<ArisDesktopDocument>(raw, aris_reader_desktop_close);
        if (!aris_reader_desktop_info(raw, &info, &error)) { result.error = takeError(error); return result; }
        QJsonParseError parseError{};
        const auto json = QJsonDocument::fromJson(QByteArray::fromRawData(
            reinterpret_cast<const char *>(info.data), qsizetype(info.len)), &parseError);
        aris_reader_desktop_buffer_free(info);
        if (parseError.error != QJsonParseError::NoError || !json.isObject()) {
            result.error = QStringLiteral("The document service returned invalid page information.");
            return result;
        }
        const auto object = json.object();
        result.pages = object.value(QStringLiteral("pages")).toArray().toVariantList();
        result.width = object.value(QStringLiteral("width")).toDouble();
        return result;
    }));
}

void ReaderController::retryPassword(const QString &password) { openFile(m_lastUrl, password); }

double ReaderController::fitWidth(double viewportWidth) const {
    return aris_reader_desktop_fit_width(m_documentWidth, viewportWidth);
}

double ReaderController::zoomOffset(double offset, double anchor, double oldZoom, double newZoom) const {
    return aris_reader_desktop_zoom_offset(offset, anchor, oldZoom, newZoom);
}

QString ReaderController::rasterKey(int page, double scale) {
    return QString::number(page) + QLatin1Char(':') + QString::number(int(std::ceil(scale * 8)));
}

QImage ReaderController::cachedPage(int page, double scale) const {
    if (auto *image = m_cache.object(rasterKey(page, scale))) return *image;
    return {};
}

void ReaderController::requestPage(int page, double scale) {
    if (!m_document || page < 0 || page >= pageCount() || !std::isfinite(scale) || scale <= 0) return;
    scale = std::ceil(scale * 8) / 8.0;
    const auto key = rasterKey(page, scale);
    if (m_cache.contains(key) || m_pending.contains(key) || m_failed.contains(key)) return;
    // A rapid zoom must not queue dozens of obsolete resolutions of the same page.
    for (auto it = m_requests.begin(); it != m_requests.end();) {
        if (it->page == page) { m_pending.remove(it->key); it = m_requests.erase(it); }
        else ++it;
    }
    // ListView virtualizes items; keep this queue bounded during very fast page jumps.
    while (m_requests.size() >= 12) { m_pending.remove(m_requests.first().key); m_requests.removeFirst(); }
    m_pending.insert(key);
    m_requests.append({page, scale, key});
    startNextRaster();
}

void ReaderController::startNextRaster() {
    if (m_rendering || m_requests.isEmpty() || !m_document) return;
    const auto request = m_requests.takeFirst();
    const auto generation = m_generation;
    const auto document = m_document;
    m_rendering = true;
    auto *watcher = new QFutureWatcher<RasterResult>(this);
    connect(watcher, &QFutureWatcher<RasterResult>::finished, this, [this, watcher, request, generation] {
        auto result = watcher->result();
        watcher->deleteLater();
        m_rendering = false;
        if (generation != m_generation) {
            ++m_discarded;
        } else {
            m_pending.remove(request.key);
            if (result.image.isNull()) {
                m_failed.insert(request.key);
                setError(result.error);
            } else {
                const int cost = int((result.image.sizeInBytes() + 1023) / 1024);
                m_cache.insert(request.key, new QImage(result.image), cost);
                ++m_completed;
                qInfo().nospace() << "aris-qt-raster: page=" << request.page << " requested=" << request.scale
                    << " actual=" << result.actualScale << " bytes=" << result.image.sizeInBytes()
                    << " ms=" << result.elapsedMs << " cpu-cache-kib=" << m_cache.totalCost();
                emit pageReady(request.page, request.scale);
            }
        }
        emit statisticsChanged();
        startNextRaster();
    });
    watcher->setFuture(QtConcurrent::run([document, request] {
        RasterResult result;
        QElapsedTimer timer;
        timer.start();
        ArisBitmap bitmap{};
        ArisBuffer error{};
        if (!aris_reader_desktop_render(document.get(), std::uint32_t(request.page), request.scale, &bitmap, &error)) {
            result.error = takeError(error);
            return result;
        }
        result.actualScale = bitmap.scale;
        // QImage shares the Rust allocation and releases it using the same allocator.
        // No BGRA->RGBA conversion or extra full-page CPU copy on this boundary.
        result.image = QImage(bitmap.pixels.data, int(bitmap.width), int(bitmap.height), bitmap.stride,
            QImage::Format_ARGB32_Premultiplied, releasePixels, new ArisBuffer(bitmap.pixels));
        result.elapsedMs = timer.elapsed();
        return result;
    }));
}
