#include "ReaderController.h"
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QtConcurrentRun>
#include <QPromise>
#include <cmath>
#include <deque>
#include <functional>
#include <mutex>

// FIFO mutations outlive their QObject host. Closing a tab cannot cancel a pending note flush.
class CommandQueue:public std::enable_shared_from_this<CommandQueue> {
public:
    void append(std::function<void()> task){
        std::lock_guard<std::mutex> lock(m_mutex);m_tasks.push_back(std::move(task));
        if(m_running)return;m_running=true;
        const auto self=shared_from_this();
        (void)QtConcurrent::run([self]{
            for(;;){std::function<void()> next;
                {std::lock_guard<std::mutex> lock(self->m_mutex);if(self->m_tasks.empty()){self->m_running=false;return;}next=std::move(self->m_tasks.front());self->m_tasks.pop_front();}
                next();
            }
        });
    }
private:
    std::mutex m_mutex;std::deque<std::function<void()>>m_tasks;bool m_running=false;
};

namespace {
QString takeError(LyraReaderBuffer &buffer) {
    const auto message = QString::fromUtf8(reinterpret_cast<const char *>(buffer.data), qsizetype(buffer.len));
    lyra_reader_desktop_buffer_free(buffer);
    buffer = {};
    return message;
}
struct OpenResult {
    std::shared_ptr<LyraReaderDesktopDocument> document;
    QVariantList pages;
    double width = 0;
    double height = 0;
    QVariantMap signature;
    QString error;
};
struct RasterResult { QImage image; QString error; double actualScale = 0; qint64 elapsedMs = 0; };
struct CommandResult { QVariant result; QString error; };
void releasePixels(void *info) {
    auto *buffer = static_cast<LyraReaderBuffer *>(info);
    lyra_reader_desktop_buffer_free(*buffer);
    delete buffer;
}
}

ReaderController::ReaderController(QObject *parent) : QObject(parent),m_mutations(std::make_shared<CommandQueue>()) {}

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
    m_documentHeight = 0;
    m_data.clear(); m_textPages.clear(); m_textPending.clear();m_noteDrafts.clear();emit noteDraftsChanged();
    emit dataChanged(); emit textPagesChanged();
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
            m_passwordRequired = result.error.contains(QStringLiteral("Encrypted:"));
            emit passwordRequiredChanged();
            emit openFinished(false);
            return;
        }
        m_document = std::move(result.document);
        m_pages = std::move(result.pages);
        m_data.insert(QStringLiteral("signature_status"),result.signature);emit dataChanged();
        m_documentWidth = result.width;
        m_documentHeight = result.height;
        emit documentChanged();
        emit openFinished(true);
        submit(QStringLiteral("outline"));
        submit(QStringLiteral("metadata"));
        submit(QStringLiteral("annotations"));
        submit(QStringLiteral("marks"));
    });
    const auto path = url.toLocalFile().toUtf8();
    const auto secret = password.toUtf8();
    watcher->setFuture(QtConcurrent::run([path, secret] {
        OpenResult result;
        LyraReaderBuffer error{}, info{};
        auto *raw = lyra_reader_desktop_open(reinterpret_cast<const std::uint8_t *>(path.constData()), path.size(),
            secret.isEmpty() ? nullptr : reinterpret_cast<const std::uint8_t *>(secret.constData()), secret.size(), &error);
        if (!raw) { result.error = takeError(error); return result; }
        result.document = std::shared_ptr<LyraReaderDesktopDocument>(raw, lyra_reader_desktop_close);
        if (!lyra_reader_desktop_info(raw, &info, &error)) { result.error = takeError(error); return result; }
        QJsonParseError parseError{};
        const auto json = QJsonDocument::fromJson(QByteArray::fromRawData(
            reinterpret_cast<const char *>(info.data), qsizetype(info.len)), &parseError);
        lyra_reader_desktop_buffer_free(info);
        if (parseError.error != QJsonParseError::NoError || !json.isObject()) {
            result.error = QStringLiteral("The document service returned invalid page information.");
            return result;
        }
        const auto object = json.object();
        result.pages = object.value(QStringLiteral("pages")).toArray().toVariantList();
        result.width = object.value(QStringLiteral("width")).toDouble();
        result.height = object.value(QStringLiteral("height")).toDouble();
        result.signature = object.value(QStringLiteral("signature_status")).toObject().toVariantMap();
        return result;
    }));
}

void ReaderController::retryPassword(const QString &password) { openFile(m_lastUrl, password); }

quint64 ReaderController::submit(const QString &operation, const QVariantMap &arguments) {
    const auto id = ++m_commandSequence;
    const auto document = m_document;
    if (!document) {
        QMetaObject::invokeMethod(this, [this,id,operation] {
            emit commandFinished(id, operation, {}, tr("No document is open."));
        }, Qt::QueuedConnection);
        return id;
    }
    auto request = QJsonObject::fromVariantMap(arguments);
    request.insert(QStringLiteral("op"), operation);
    const auto bytes = QJsonDocument(request).toJson(QJsonDocument::Compact);
    const bool mutation=operation.startsWith(QStringLiteral("mark_")) || operation.startsWith(QStringLiteral("marks_")) || operation.startsWith(QStringLiteral("bookmark_")) || operation.startsWith(QStringLiteral("file_")) || operation.startsWith(QStringLiteral("page_")) || operation.startsWith(QStringLiteral("save_")) || operation.startsWith(QStringLiteral("replace_")) || operation==QStringLiteral("extract_pages");
    if(mutation)++m_mutationSequence;
    const auto mutationSequence=m_mutationSequence;
    const auto generation = m_generation;
    const bool latestOnly=operation==QStringLiteral("search") || operation==QStringLiteral("bibtex") || operation==QStringLiteral("layout") || operation==QStringLiteral("ai_preview");
    if(latestOnly)m_latestRead.insert(operation,id);
    ++m_pendingCommands;
    emit commandsChanged();
    auto *watcher = new QFutureWatcher<CommandResult>(this);
    connect(watcher, &QFutureWatcher<CommandResult>::finished, this, [this,watcher,id,operation,arguments,generation,latestOnly,document,mutation,mutationSequence] {
        const auto outcome = watcher->result();
        watcher->deleteLater();
        --m_pendingCommands;
        emit commandsChanged();
        // A page revision invalidates raster/read results, but later queued mutations
        // still belong to this same document and must deliver their new state.
        if(document!=m_document || (!mutation && generation!=m_generation))return;
        if(operation==QStringLiteral("marks") && mutationSequence!=m_mutationSequence)return;
        if(latestOnly && m_latestRead.value(operation)!=id)return;
        if (!outcome.error.isEmpty()) setError(outcome.error);
        else if (operation==QStringLiteral("page_stage") || operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("page_apply")) {
            const auto revision=outcome.result.toMap();
            const auto info=revision.value(QStringLiteral("info")).toMap();
            ++m_generation;m_cache.clear();m_pending.clear();m_failed.clear();m_requests.clear();m_textPages.clear();m_textPending.clear();
            m_pages=info.value(QStringLiteral("pages")).toList();m_documentWidth=info.value(QStringLiteral("width")).toDouble();m_documentHeight=info.value(QStringLiteral("height")).toDouble();
            m_data.clear();m_data.insert(QStringLiteral("marks"),revision.value(QStringLiteral("marks")));m_data.insert(QStringLiteral("signature_status"),info.value(QStringLiteral("signature_status")));
            emit documentReset();emit documentChanged();emit dataChanged();emit textPagesChanged();
            submit(QStringLiteral("outline"));submit(QStringLiteral("metadata"));
        } else if (operation == QStringLiteral("text")) {
            const int page = arguments.value(QStringLiteral("page")).toInt();
            m_textPending.remove(page);
            m_textPages.insert(QString::number(page), outcome.result);
            emit textPagesChanged();
        } else if (operation == QStringLiteral("layout")) {
            const auto layout = outcome.result.toMap();
            m_pages = layout.value(QStringLiteral("pages")).toList();
            m_documentWidth = layout.value(QStringLiteral("width")).toDouble();
            m_documentHeight = layout.value(QStringLiteral("height")).toDouble();
            emit documentChanged();
        } else {
            const bool marks=operation==QStringLiteral("marks") || operation.startsWith(QStringLiteral("mark_")) || operation.startsWith(QStringLiteral("bookmark_")) || operation.startsWith(QStringLiteral("marks_")) || operation.startsWith(QStringLiteral("file_"));
            m_data.insert(marks ? QStringLiteral("marks") : operation, outcome.result);
            emit dataChanged();
        }
        if (!outcome.error.isEmpty() && operation == QStringLiteral("text"))
            m_textPending.remove(arguments.value(QStringLiteral("page")).toInt());
        if(outcome.error.isEmpty() && operation==QStringLiteral("mark_update")) {
            const auto annotationId=arguments.value(QStringLiteral("id")).toString();
            const auto patch=arguments.value(QStringLiteral("patch")).toMap();
            if(patch.contains(QStringLiteral("note")) && m_noteDrafts.value(annotationId)==patch.value(QStringLiteral("note")))clearNoteDraft(annotationId);
        }
        emit commandFinished(id, operation, outcome.result, outcome.error);
    });
    auto task=[document,bytes] {
        CommandResult result;
        LyraReaderBuffer output{}, error{};
        if (!lyra_reader_desktop_command(document.get(), reinterpret_cast<const std::uint8_t *>(bytes.constData()), bytes.size(), &output, &error)) {
            result.error = takeError(error);
            return result;
        }
        QJsonParseError parseError{};
        const auto json = QJsonDocument::fromJson(QByteArray::fromRawData(reinterpret_cast<const char *>(output.data), qsizetype(output.len)), &parseError);
        lyra_reader_desktop_buffer_free(output);
        if (parseError.error != QJsonParseError::NoError || !json.isObject())
            result.error = QStringLiteral("The document service returned an invalid response.");
        else result.result = json.object().value(QStringLiteral("result")).toVariant();
        return result;
    };
    if(mutation){
        auto promise=std::make_shared<QPromise<CommandResult>>();promise->start();watcher->setFuture(promise->future());
        m_mutations->append([task,promise]{try{promise->addResult(task());}catch(...){promise->addResult(CommandResult{{},QStringLiteral("The command worker stopped unexpectedly.")});}promise->finish();});
    }else watcher->setFuture(QtConcurrent::run(std::move(task)));
    return id;
}

void ReaderController::requestText(int page) {
    if (page < 0 || page >= pageCount() || m_textPages.contains(QString::number(page)) || m_textPending.contains(page)) return;
    m_textPending.insert(page);
    submit(QStringLiteral("text"), {{QStringLiteral("page"),page}});
}

void ReaderController::setLayout(const QString &mode, double gap) {
    submit(QStringLiteral("layout"), {{QStringLiteral("mode"),mode},{QStringLiteral("gap"),gap}});
}

double ReaderController::fitWidth(double viewportWidth) const {
    return lyra_reader_desktop_fit_width(m_documentWidth, viewportWidth);
}

double ReaderController::zoomOffset(double offset, double anchor, double oldZoom, double newZoom) const {
    return lyra_reader_desktop_zoom_offset(offset, anchor, oldZoom, newZoom);
}

QString ReaderController::rasterKey(int page, double scale,bool embedded) {
    return QString::number(page) + QLatin1Char(':') + QString::number(int(std::ceil(scale * 8)))+(embedded?QStringLiteral(":annotations"):QString{});
}

QImage ReaderController::cachedPage(int page, double scale,bool embedded) const {
    if (auto *image = m_cache.object(rasterKey(page, scale,embedded))) return *image;
    return {};
}

void ReaderController::requestPage(int page, double scale,bool embedded) {
    if (!m_document || page < 0 || page >= pageCount() || !std::isfinite(scale) || scale <= 0) return;
    scale = std::ceil(scale * 8) / 8.0;
    const auto key = rasterKey(page, scale,embedded);
    if (m_cache.contains(key) || m_pending.contains(key) || m_failed.contains(key)) return;
    // The canvas and thumbnails can need different densities of the same page.
    // Keep both requests; visible items retry if a very fast jump displaces their work.
    while (m_requests.size() >= 32) { m_pending.remove(m_requests.last().key); m_requests.removeLast(); }
    m_pending.insert(key);
    auto position = m_requests.begin();
    while (position != m_requests.end() && position->scale >= scale) ++position;
    m_requests.insert(position, {page, scale, key,embedded});
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
                qInfo().nospace() << "lyra-reader-qt-raster: page=" << request.page << " requested=" << request.scale
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
        LyraReaderBitmap bitmap{};
        LyraReaderBuffer error{};
        const auto render=request.embedded ? lyra_reader_desktop_render_annotated : lyra_reader_desktop_render;
        if (!render(document.get(), std::uint32_t(request.page), request.scale, &bitmap, &error)) {
            result.error = takeError(error);
            return result;
        }
        result.actualScale = bitmap.scale;
        // QImage shares the Rust allocation and releases it using the same allocator.
        // No BGRA->RGBA conversion or extra full-page CPU copy on this boundary.
        result.image = QImage(bitmap.pixels.data, int(bitmap.width), int(bitmap.height), bitmap.stride,
            QImage::Format_ARGB32_Premultiplied, releasePixels, new LyraReaderBuffer(bitmap.pixels));
        result.elapsedMs = timer.elapsed();
        return result;
    }));
}
