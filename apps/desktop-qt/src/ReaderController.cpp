#include "ReaderController.h"
#include "NativeRaster.h"
#include "RasterCache.h"
#include <QUuid>
#include <QLineF>
#include <algorithm>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QtConcurrentRun>
#include <QPromise>
#include <QJSValue>
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
    std::shared_ptr<NativeRasterSource> source;
    QVariantList pages;
    double width = 0;
    double height = 0;
    QVariantMap signature;
    QString error;
};
struct RasterResult { QImage image; QString error; double actualScale = 0; qint64 elapsedMs = 0; };
struct CommandResult { QVariant result; QString error; std::shared_ptr<NativeRasterSource> source; };
}

ReaderController::ReaderController(QObject *parent) : QObject(parent),m_cachePrefix(QUuid::createUuid().toString()+QLatin1Char('/')),m_mutations(std::make_shared<CommandQueue>()) {initAi();}
ReaderController::~ReaderController(){clearRasterCache();}
void ReaderController::clearRasterCache(){RasterCache::clearPrefix(m_cachePrefix);m_tileDemand.clear();}
int ReaderController::cpuCacheKiB(){return RasterCache::costKiB();}

void ReaderController::setEditDraft(const QString &key,const QVariant &value) {
    if(key!=QStringLiteral("forms") && key!=QStringLiteral("redactions"))return;
    const auto next=value.metaType()==QMetaType::fromType<QJSValue>() ? value.value<QJSValue>().toVariant() : value;
    const bool empty=next.isNull() || (key==QStringLiteral("forms") ? next.toMap().isEmpty() : next.toList().isEmpty());
    if(empty){if(m_editDrafts.remove(key))emit editDraftsChanged();return;}
    if(m_editDrafts.value(key)==next)return;
    m_editDrafts.insert(key,next);emit editDraftsChanged();
}

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
    resetAi();m_document.reset();m_source.reset();
    m_pages.clear();
    clearRasterCache();
    m_pending.clear();
    m_failed.clear();
    m_requests.clear();
    m_documentWidth = 0;
    m_documentHeight = 0;
    m_data.clear(); m_textPages.clear(); m_textPending.clear();m_noteDrafts.clear();emit noteDraftsChanged();m_editDrafts.clear();emit editDraftsChanged();
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
        m_document = std::move(result.document);m_source=std::move(result.source);
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
        result.source=NativeRasterSource::prepare(result.document,false,&result.error);
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
    if((operation.startsWith(QStringLiteral("page_")) || operation.startsWith(QStringLiteral("replace_"))) && m_aiState.value(QStringLiteral("running")).toBool()) {
        const auto error=tr("Cancel the active AI request before changing the open document.");
        QMetaObject::invokeMethod(this,[this,id,operation,error]{setError(error);emit commandFinished(id,operation,{},error);},Qt::QueuedConnection);return id;
    }
    if((operation==QStringLiteral("page_stage") || operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_apply") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("save_merge") || operation==QStringLiteral("save_split")) && hasEditDrafts()) {
        const auto error=tr("Save or clear pending form edits and redaction marks before changing pages.");
        QMetaObject::invokeMethod(this,[this,id,operation,error]{setError(error);emit commandFinished(id,operation,{},error);},Qt::QueuedConnection);
        return id;
    }
    const QString draftKey=(operation==QStringLiteral("save_forms") || operation==QStringLiteral("replace_forms")) ? QStringLiteral("forms") :
        ((operation==QStringLiteral("save_redactions") || operation==QStringLiteral("replace_redactions")) ? QStringLiteral("redactions") : QString{});
    const auto savedDraft=m_editDrafts.value(draftKey);
    QVariantList draftValues;
    if(draftKey==QStringLiteral("forms")) {const auto fields=savedDraft.toMap();for(const auto &field:fields)draftValues.append(field);}
    const bool draftMatchesRequest=!draftKey.isEmpty() && !savedDraft.isNull() &&
        (draftKey==QStringLiteral("forms") ? draftValues==arguments.value(QStringLiteral("values")).toList() : savedDraft.toList()==arguments.value(QStringLiteral("areas")).toList());
    auto request = QJsonObject::fromVariantMap(arguments);
    request.insert(QStringLiteral("op"), operation);
    const auto bytes = QJsonDocument(request).toJson(QJsonDocument::Compact);
    const bool mutation=operation.startsWith(QStringLiteral("mark_")) || operation.startsWith(QStringLiteral("marks_")) || operation.startsWith(QStringLiteral("bookmark_")) || operation.startsWith(QStringLiteral("file_")) || operation.startsWith(QStringLiteral("page_")) || operation.startsWith(QStringLiteral("save_")) || operation.startsWith(QStringLiteral("replace_")) || operation==QStringLiteral("extract_pages");
    if(mutation)++m_mutationSequence;
    const auto mutationSequence=m_mutationSequence;
    const auto generation = m_generation;
    const bool latestOnly=operation==QStringLiteral("search") || operation==QStringLiteral("bibtex") || operation==QStringLiteral("layout") || operation==QStringLiteral("ai_preview") || operation==QStringLiteral("split_plan");
    if(latestOnly)m_latestRead.insert(operation,id);
    ++m_pendingCommands;
    emit commandsChanged();
    auto *watcher = new QFutureWatcher<CommandResult>(this);
    connect(watcher, &QFutureWatcher<CommandResult>::finished, this, [this,watcher,id,operation,arguments,generation,latestOnly,document,mutation,mutationSequence,draftKey,savedDraft,draftMatchesRequest] {
        const auto outcome = watcher->result();
        watcher->deleteLater();
        --m_pendingCommands;
        emit commandsChanged();
        // A page revision invalidates raster/read results, but later queued mutations
        // still belong to this same document and must deliver their new state.
        if(document!=m_document || (!mutation && generation!=m_generation))return;
        if(operation==QStringLiteral("marks") && mutationSequence!=m_mutationSequence)return;
        if(latestOnly && m_latestRead.value(operation)!=id)return;
        if (!outcome.error.isEmpty() && operation!=QStringLiteral("split_plan") && !operation.startsWith(QStringLiteral("ai_"))) setError(outcome.error);
        else if (operation==QStringLiteral("page_stage") || operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("page_apply")) {
            m_source=outcome.source;
            const auto revision=outcome.result.toMap();
            const auto info=revision.value(QStringLiteral("info")).toMap();
            ++m_generation;resetAi();clearRasterCache();m_pending.clear();m_failed.clear();m_requests.clear();m_textPages.clear();m_textPending.clear();
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
        if(outcome.error.isEmpty() && draftMatchesRequest && m_editDrafts.value(draftKey)==savedDraft)
            setEditDraft(draftKey,{});
        if(outcome.error.isEmpty() && operation==QStringLiteral("mark_update")) {
            const auto annotationId=arguments.value(QStringLiteral("id")).toString();
            const auto patch=arguments.value(QStringLiteral("patch")).toMap();
            if(patch.contains(QStringLiteral("note")) && m_noteDrafts.value(annotationId)==patch.value(QStringLiteral("note")))clearNoteDraft(annotationId);
        }
        emit commandFinished(id, operation, outcome.result, outcome.error);
    });
    auto task=[document,bytes,operation] {
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
        if(result.error.isEmpty() && (operation==QStringLiteral("page_stage") || operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("page_apply")))
            result.source=NativeRasterSource::prepare(document,false,&result.error);
        return result;
    };
    if(mutation || operation==QStringLiteral("ai_start") || operation==QStringLiteral("ai_cancel")){
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

QImage ReaderController::cachedPage(int page,double scale,bool embedded) const {
    return RasterCache::get(m_cachePrefix+rasterKey(page,scale,embedded));
}
QImage ReaderController::cachedTile(const QString &key)const{return RasterCache::get(m_cachePrefix+key);}
double ReaderController::tileScale(int level){return std::exp2(double(level)/4.0);}
void ReaderController::enqueue(const Request &request) {
    if(RasterCache::contains(m_cachePrefix+request.key) || m_pending.contains(request.key) || m_failed.contains(request.key))return;
    while(m_requests.size()>=128){m_pending.remove(m_requests.last().key);m_requests.removeLast();}
    m_pending.insert(request.key);
    auto position=m_requests.begin();while(position!=m_requests.end() && position->priority>=request.priority)++position;
    m_requests.insert(position,request);
}
void ReaderController::requestPage(int page,double scale,bool embedded) {
    if(!m_source || page<0 || page>=pageCount() || !std::isfinite(scale) || scale<=0 || scale>128)return;
    scale=std::ceil(scale*8)/8.0;const auto dimensions=m_pages.at(page).toMap();
    const QRectF region(0,0,dimensions.value(QStringLiteral("width")).toDouble(),dimensions.value(QStringLiteral("height")).toDouble());
    enqueue({page,scale,rasterKey(page,scale,embedded),embedded,false,region,embedded?0:2});startNextRaster();
}
void ReaderController::pruneTileRequests() {
    QSet<QString> wanted;for(const auto &keys:m_tileDemand)wanted.unite(keys);
    for(auto it=m_requests.begin();it!=m_requests.end();) {
        if(it->tile && !wanted.contains(it->key)){m_pending.remove(it->key);it=m_requests.erase(it);}else ++it;
    }
}
void ReaderController::clearTileDemand(quintptr consumer){m_tileDemand.remove(consumer);pruneTileRequests();}
QList<TileSpec> ReaderController::requestTiles(quintptr consumer,int page,int level,const QRectF &visible,const QSet<QString> &retained) {
    if(!m_source || page<0 || page>=pageCount() || visible.isEmpty() || !std::isfinite(visible.x()) || !std::isfinite(visible.y()) || !std::isfinite(visible.width()) || !std::isfinite(visible.height())){clearTileDemand(consumer);return {};}
    const auto dimensions=m_pages.at(page).toMap();
    const QRectF full(0,0,dimensions.value(QStringLiteral("width")).toDouble(),dimensions.value(QStringLiteral("height")).toDouble());
    const auto view=visible.intersected(full);if(view.isEmpty()){clearTileDemand(consumer);return {};}
    level=qBound(-24,level,28);
    // Quarter-octave density tiers limit oversampling to 1.42x the visible pixel area.
    // Very large displays lower one tier if needed to keep this page's demand bounded.
    while(level>-24){const double edge=512/tileScale(level);const auto count=(std::ceil(view.right()/edge)-std::floor(view.left()/edge))*(std::ceil(view.bottom()/edge)-std::floor(view.top()/edge));if(count<=96)break;--level;}
    const double scale=tileScale(level),edge=512/scale;
    if(!std::isfinite(full.width()) || !std::isfinite(full.height()) || full.width()/edge>2147483645.0 || full.height()/edge>2147483645.0){clearTileDemand(consumer);return {};}
    const int left=qMax(0,int(std::floor(view.left()/edge))),top=qMax(0,int(std::floor(view.top()/edge)));
    const int right=qMin(int(std::ceil(full.width()/edge)),int(std::ceil(view.right()/edge)));
    const int bottom=qMin(int(std::ceil(full.height()/edge)),int(std::ceil(view.bottom()/edge)));
    QList<TileSpec> result;
    for(int row=top;row<bottom;++row)for(int column=left;column<right;++column){
        const auto target=QRectF(column*edge,row*edge,edge,edge).intersected(full);
        const auto render=target.adjusted(-1/scale,-1/scale,1/scale,1/scale).intersected(full);
        const auto key=QStringLiteral("tile:%1:%2:%3:%4").arg(page).arg(level).arg(column).arg(row);
        result.append({key,page,level,column,row,scale,target,render});
    }
    std::sort(result.begin(),result.end(),[&](const auto &a,const auto &b){return QLineF(a.target.center(),view.center()).length()<QLineF(b.target.center(),view.center()).length();});
    QSet<QString> wanted;for(const auto &tile:result)wanted.insert(tile.key);
    m_tileDemand.insert(consumer,wanted);pruneTileRequests();
    for(const auto &tile:result)if(!retained.contains(tile.key))enqueue({page,scale,tile.key,false,true,tile.render,1});
    startNextRaster();return result;
}
void ReaderController::startNextRaster() {
    if(m_rendering || m_requests.isEmpty() || !m_source)return;
    const auto request=m_requests.takeFirst();const auto generation=m_generation;const auto source=m_source;
    m_rendering=true;
    auto *watcher=new QFutureWatcher<RasterResult>(this);
    connect(watcher,&QFutureWatcher<RasterResult>::finished,this,[this,watcher,request,generation]{
        auto result=watcher->result();watcher->deleteLater();m_rendering=false;
        if(generation!=m_generation){++m_discarded;}
        else {
            m_pending.remove(request.key);
            if(result.image.isNull()){m_failed.insert(request.key);setError(result.error);}
            else {
                RasterCache::put(m_cachePrefix+request.key,result.image);++m_completed;
                if(request.tile)emit tileReady(request.page);
                else {qInfo().nospace()<<"lyra-reader-qt-raster: page="<<request.page<<" requested="<<request.scale<<" actual="<<result.actualScale<<" bytes="<<result.image.sizeInBytes()<<" ms="<<result.elapsedMs<<" global-cache-kib="<<RasterCache::costKiB();emit pageReady(request.page,request.scale);}
            }
        }
        emit statisticsChanged();startNextRaster();
    });
    watcher->setFuture(QtConcurrent::run([source,request]{
        RasterResult result;QElapsedTimer timer;timer.start();
        result.image=source->crop(request.page,request.region,request.scale,request.embedded,false,&result.error,&result.actualScale);
        result.elapsedMs=timer.elapsed();return result;
    }));
}
