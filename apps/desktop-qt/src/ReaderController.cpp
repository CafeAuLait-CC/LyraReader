#include "ReaderController.h"
#include "NativeRaster.h"
#include "RasterCache.h"
#include "RenderBudget.h"
#include <QUuid>
#include <QLineF>
#include <algorithm>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFile>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QtConcurrentRun>
#include <QPromise>
#include <QJSValue>
#include <QUrlQuery>
#include "SignatureArtwork.h"
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
    QVariantMap recovery;
    QVariantMap xfa;
    QString revision;
    QString error;
};
struct RasterResult { ResidentImage image; QString error; double actualScale = 0; qint64 elapsedMs = 0;bool cancelled=false,pressure=false; };
struct CommandResult { QVariant result; QString error; std::shared_ptr<NativeRasterSource> source; };
double quantizedRasterScale(double scale) {
    return scale>=.125 ? std::ceil(scale*8)/8.0 : std::exp2(std::ceil(std::log2(scale)*4)/4);
}
}

ReaderController::ReaderController(QObject *parent) : QObject(parent),m_cachePrefix(QUuid::createUuid().toString()+QLatin1Char('/')),m_mutations(std::make_shared<CommandQueue>()) {
    initAi();
    connect(this,&ReaderController::dataChanged,this,&ReaderController::unsavedChangesChanged);
    connect(this,&ReaderController::noteDraftsChanged,this,&ReaderController::unsavedChangesChanged);
    connect(this,&ReaderController::editDraftsChanged,this,&ReaderController::unsavedChangesChanged);
}
bool ReaderController::hasUnsavedChanges()const {
    const auto marks=m_data.value(QStringLiteral("marks")).toMap();
    const bool localOnly=m_data.value(QStringLiteral("xfa_status")).toMap().value(QStringLiteral("is_xfa")).toBool();
    return marks.value(QStringLiteral("page_pending")).toBool() ||
        (!localOnly && marks.value(QStringLiteral("pdf_dirty")).toBool()) || !m_noteDrafts.isEmpty() || hasEditDrafts();
}
ReaderController::~ReaderController(){clearRasterCache();NativeImageProvider::unregisterSource(m_contentSourceKey);}
void ReaderController::clearRasterCache(){RasterJobs::cancel(m_activeRaster);RasterCache::clearPrefix(m_cachePrefix);m_tileDemand.clear();m_pageDemand.clear();m_manualDemand.clear();}
int ReaderController::cpuCacheKiB(){return RasterCache::costKiB();}

void ReaderController::setEditDraft(const QString &key,const QVariant &value) {
    if(key!=QStringLiteral("forms") && key!=QStringLiteral("redactions") && key!=QStringLiteral("content"))return;
    const auto next=value.metaType()==QMetaType::fromType<QJSValue>() ? value.value<QJSValue>().toVariant() : value;
    const bool empty=next.isNull() || (key==QStringLiteral("redactions") ? next.toList().isEmpty() : next.toMap().isEmpty());
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
    if(m_snapshotMode){setError(tr("This preview is read-only."));return;}
    if (!url.isLocalFile()) {
        setError(tr("Choose a local PDF file. This version cannot open remote URLs."));
        return;
    }
    m_lastUrl = url;
    const auto generation = ++m_generation;
    resetAi();m_document.reset();setRasterSource({});
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
        m_document = std::move(result.document);setRasterSource(std::move(result.source));
        m_pages = std::move(result.pages);
        m_data.insert(QStringLiteral("signature_status"),result.signature);emit dataChanged();
        m_data.insert(QStringLiteral("recovery"),result.recovery);
        m_data.insert(QStringLiteral("xfa_status"),result.xfa);
        m_data.insert(QStringLiteral("document_revision"),result.revision);
        if(!result.recovery.value(QStringLiteral("error")).toString().isEmpty())setError(result.recovery.value(QStringLiteral("error")).toString());
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
        result.recovery = object.value(QStringLiteral("recovery")).toObject().toVariantMap();
        result.xfa = object.value(QStringLiteral("xfa_status")).toObject().toVariantMap();
        result.revision = object.value(QStringLiteral("revision")).toString();
        result.source=NativeRasterSource::prepare(result.document,false,&result.error);
        return result;
    }));
}

bool ReaderController::openSnapshot(const std::shared_ptr<NativeRasterSource> &source,const QUrl &identity,const QString &title) {
    if(!source || m_document || m_source || m_snapshotMode)return false;
    m_snapshotMode=true;setRasterSource(source);m_lastUrl=identity;m_title=title;++m_generation;
    m_loading=true;emit documentChanged();emit loadingChanged();
    submit(QStringLiteral("layout"),{{QStringLiteral("mode"),QStringLiteral("Continuous")},{QStringLiteral("gap"),12}});
    return true;
}
void ReaderController::closeSnapshot() {
    if(!m_snapshotMode)return;
    ++m_generation;clearRasterCache();m_requests.clear();m_pending.clear();m_failed.clear();
    setRasterSource({});m_pages.clear();m_textPages.clear();m_textPending.clear();m_data.clear();
    m_documentWidth=0;m_documentHeight=0;m_loading=false;
    emit documentReset();emit documentChanged();emit textPagesChanged();emit dataChanged();emit loadingChanged();
}
quint64 ReaderController::submitSnapshot(quint64 id,const QString &operation,const QVariantMap &arguments) {
    static const QSet<QString> readable{QStringLiteral("layout"),QStringLiteral("text"),QStringLiteral("outline"),QStringLiteral("references"),QStringLiteral("figures"),QStringLiteral("page_targets"),QStringLiteral("resolve_citations")};
    const auto source=m_source;const auto generation=m_generation;
    if(!source || !readable.contains(operation)) {
        const auto error=source ? tr("This preview is read-only.") : tr("This preview is closed.");
        QMetaObject::invokeMethod(this,[this,id,operation,error]{setError(error);emit commandFinished(id,operation,{},error);},Qt::QueuedConnection);return id;
    }
    const bool latest=operation==QStringLiteral("layout");if(latest)m_latestRead.insert(operation,id);
    ++m_pendingCommands;emit commandsChanged();
    auto *watcher=new QFutureWatcher<CommandResult>(this);
    connect(watcher,&QFutureWatcher<CommandResult>::finished,this,[this,watcher,id,operation,arguments,source,generation,latest]{
        const auto result=watcher->result();watcher->deleteLater();--m_pendingCommands;emit commandsChanged();
        if(source!=m_source || generation!=m_generation || (latest && m_latestRead.value(operation)!=id))return;
        const bool opening=m_loading && operation==QStringLiteral("layout");
        if(!result.error.isEmpty())setError(result.error);
        else if(operation==QStringLiteral("layout")) {
            const auto layout=result.result.toMap();m_pages=layout.value(QStringLiteral("pages")).toList();
            m_documentWidth=layout.value(QStringLiteral("width")).toDouble();m_documentHeight=layout.value(QStringLiteral("height")).toDouble();emit documentChanged();
        }else if(operation==QStringLiteral("text")) {
            const auto page=arguments.value(QStringLiteral("page")).toInt();m_textPages.insert(QString::number(page),result.result);emit textPagesChanged();
        }else {m_data.insert(operation,result.result);emit dataChanged();}
        if(operation==QStringLiteral("text"))m_textPending.remove(arguments.value(QStringLiteral("page")).toInt());
        if(opening){m_loading=false;emit loadingChanged();emit openFinished(result.error.isEmpty());}
        emit commandFinished(id,operation,result.result,result.error);
    });
    watcher->setFuture(QtConcurrent::run([source,operation,arguments]{CommandResult result;auto request=arguments;request.insert(QStringLiteral("op"),operation);result.result=source->query(request,&result.error);return result;}));
    return id;
}

void ReaderController::setRasterSource(std::shared_ptr<NativeRasterSource> source) {
    NativeImageProvider::unregisterSource(m_contentSourceKey);m_contentSourceKey.clear();m_source=std::move(source);
}
QUrl ReaderController::contentPreviewUrl(int page,const QString &target,const QString &revision,double width,double height,double deviceScale) {
    if(!m_source || page<0 || page>=pageCount() || !std::isfinite(width) || !std::isfinite(height) || !std::isfinite(deviceScale) || width<=0 || height<=0 || width>8192 || height>8192 || deviceScale<=0)return {};
    const auto snapshot=m_data.value(QStringLiteral("content_objects")).toMap();
    if(snapshot.value(QStringLiteral("revision")).toString()!=revision || snapshot.value(QStringLiteral("page")).toInt()!=page)return {};
    QVariantMap item;for(const auto &value:snapshot.value(QStringLiteral("items")).toList())if(value.toMap().value(QStringLiteral("id")).toString()==target){item=value.toMap();break;}
    const auto kind=item.value(QStringLiteral("kind")).toString();if(kind!=QStringLiteral("image") && kind!=QStringLiteral("graphic"))return {};
    if(m_contentSourceKey.isEmpty())m_contentSourceKey=NativeImageProvider::registerSource(m_source);
    QUrl url(QStringLiteral("image://lyrapreview/")+m_contentSourceKey+QLatin1Char('/')+QString::number(page));QUrlQuery query;
    const auto add=[&](const QString &key,double number){query.addQueryItem(key,QString::number(number,'g',15));};
    const double pixelWidth=qBound(1.0,std::ceil(width*qBound(1.0,deviceScale,4.0)/32)*32,2048.0),pixelHeight=qBound(1.0,std::ceil(height*qBound(1.0,deviceScale,4.0)/32)*32,2048.0);
    if(kind==QStringLiteral("image")){
        query.addQueryItem(QStringLiteral("kind"),QStringLiteral("bitmap"));query.addQueryItem(QStringLiteral("target"),target);query.addQueryItem(QStringLiteral("revision"),revision);
        add(QStringLiteral("width"),pixelWidth);add(QStringLiteral("height"),pixelHeight);
    }else{
        const auto box=item.value(QStringLiteral("bounds")).toMap();const double x=box.value(QStringLiteral("x")).toDouble(),y=box.value(QStringLiteral("y")).toDouble(),w=box.value(QStringLiteral("width")).toDouble(),h=box.value(QStringLiteral("height")).toDouble();
        if(!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(w) || !std::isfinite(h) || w<=0 || h<=0)return {};
        add(QStringLiteral("x"),x);add(QStringLiteral("y"),y);add(QStringLiteral("w"),w);add(QStringLiteral("h"),h);add(QStringLiteral("scale"),qBound(.01,qMin(pixelWidth/w,pixelHeight/h),16.0));query.addQueryItem(QStringLiteral("annotations"),QStringLiteral("0"));
    }
    url.setQuery(query);return url;
}

void ReaderController::retryPassword(const QString &password) { openFile(m_lastUrl, password); }

quint64 ReaderController::submit(const QString &operation, const QVariantMap &arguments) {
    const auto id = ++m_commandSequence;
    const auto document = m_document;
    if(m_snapshotMode)return submitSnapshot(id,operation,arguments);
    if (!document) {
        QMetaObject::invokeMethod(this, [this,id,operation] {
            emit commandFinished(id, operation, {}, tr("No document is open."));
        }, Qt::QueuedConnection);
        return id;
    }
    if((operation==QStringLiteral("content_stage") || operation.startsWith(QStringLiteral("page_")) || operation.startsWith(QStringLiteral("replace_")) || operation==QStringLiteral("document_save")) && m_aiState.value(QStringLiteral("running")).toBool()) {
        const auto error=tr("Cancel the active AI request before changing the open document.");
        QMetaObject::invokeMethod(this,[this,id,operation,error]{setError(error);emit commandFinished(id,operation,{},error);},Qt::QueuedConnection);return id;
    }
    const bool blockedDrafts=operation==QStringLiteral("content_stage") ?
        (m_editDrafts.contains(QStringLiteral("forms")) || m_editDrafts.contains(QStringLiteral("redactions"))) : hasEditDrafts();
    if((operation==QStringLiteral("content_stage") || operation==QStringLiteral("page_stage") || operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_apply") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("save_merge") || operation==QStringLiteral("save_split")) && blockedDrafts) {
        const auto error=tr("Save or clear pending form edits and redaction marks before changing pages.");
        QMetaObject::invokeMethod(this,[this,id,operation,error]{setError(error);emit commandFinished(id,operation,{},error);},Qt::QueuedConnection);
        return id;
    }
    if(operation==QStringLiteral("content_stage") && !m_noteDrafts.isEmpty()) {
        const auto error=tr("Save or discard the pending annotation note before editing PDF content.");
        QMetaObject::invokeMethod(this,[this,id,operation,error]{setError(error);emit commandFinished(id,operation,{},error);},Qt::QueuedConnection);return id;
    }
    // Save As keeps the current original and its drafts open; only in-place Save clears them.
    const bool unifiedSave=operation==QStringLiteral("document_save");
    const QString draftKey=operation==QStringLiteral("content_stage") ? QStringLiteral("content") : (unifiedSave || operation==QStringLiteral("save_forms") || operation==QStringLiteral("replace_forms")) ? QStringLiteral("forms") :
        ((operation==QStringLiteral("save_redactions") || operation==QStringLiteral("replace_redactions")) ? QStringLiteral("redactions") : QString{});
    const auto savedDraft=m_editDrafts.value(draftKey);
    const auto discardedNotes=m_noteDrafts,discardedEdits=m_editDrafts;
    QVariantList draftValues;
    if(draftKey==QStringLiteral("forms")) {const auto fields=savedDraft.toMap();for(const auto &field:fields)draftValues.append(field);}
    const bool draftMatchesRequest=!draftKey.isEmpty() && !savedDraft.isNull() &&
        (draftKey==QStringLiteral("content") ?
            savedDraft.toMap().value(QStringLiteral("command")).toMap()==arguments.value(QStringLiteral("command")).toMap() && savedDraft.toMap().value(QStringLiteral("page")).toInt()==arguments.value(QStringLiteral("page")).toInt() :
            draftKey==QStringLiteral("forms") ? draftValues==arguments.value(unifiedSave ? QStringLiteral("forms") : QStringLiteral("values")).toList() : savedDraft.toList()==arguments.value(QStringLiteral("areas")).toList());
    auto request = QJsonObject::fromVariantMap(arguments);
    request.insert(QStringLiteral("op"), operation);
    const auto bytes = QJsonDocument(request).toJson(QJsonDocument::Compact);
    const bool eraseControl=operation.startsWith(QStringLiteral("ink_erase_")) && operation!=QStringLiteral("ink_erase_commit");
    const bool mutation=operation==QStringLiteral("content_stage") || operation==QStringLiteral("document_discard") || operation==QStringLiteral("document_save") || operation==QStringLiteral("ink_erase_commit") || operation.startsWith(QStringLiteral("mark_")) || operation.startsWith(QStringLiteral("marks_")) || operation.startsWith(QStringLiteral("bookmark_")) || operation.startsWith(QStringLiteral("file_")) || operation.startsWith(QStringLiteral("page_")) || operation.startsWith(QStringLiteral("save_")) || operation.startsWith(QStringLiteral("replace_")) || operation==QStringLiteral("extract_pages");
    if(mutation)++m_mutationSequence;
    const auto mutationSequence=m_mutationSequence;
    const auto generation = m_generation;
    const bool latestOnly=operation==QStringLiteral("search") || operation==QStringLiteral("bibtex") || operation==QStringLiteral("layout") || operation==QStringLiteral("ai_preview") || operation==QStringLiteral("split_plan") || operation==QStringLiteral("content_objects");
    if(latestOnly)m_latestRead.insert(operation,id);
    ++m_pendingCommands;
    emit commandsChanged();
    auto *watcher = new QFutureWatcher<CommandResult>(this);
    connect(watcher, &QFutureWatcher<CommandResult>::finished, this, [this,watcher,id,operation,arguments,generation,latestOnly,document,mutation,eraseControl,mutationSequence,draftKey,savedDraft,draftMatchesRequest,discardedNotes,discardedEdits] {
        const auto outcome = watcher->result();
        watcher->deleteLater();
        --m_pendingCommands;
        emit commandsChanged();
        // A page revision invalidates raster/read results, but later queued mutations
        // still belong to this same document and must deliver their new state.
        if(document!=m_document || (!mutation && generation!=m_generation))return;
        if((operation==QStringLiteral("marks") || operation==QStringLiteral("content_objects")) && mutationSequence!=m_mutationSequence)return;
        if(latestOnly && m_latestRead.value(operation)!=id)return;
        if (!outcome.error.isEmpty() && operation!=QStringLiteral("split_plan") && !operation.startsWith(QStringLiteral("ai_"))) setError(outcome.error);
        else if (operation==QStringLiteral("content_stage") || operation==QStringLiteral("page_stage") || operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("page_apply") || operation==QStringLiteral("document_save") || operation==QStringLiteral("document_discard")) {
            setRasterSource(outcome.source);
            const auto revision=outcome.result.toMap();
            const auto info=revision.value(QStringLiteral("info")).toMap();
            const bool reloadForms=m_data.contains(QStringLiteral("forms"));
            ++m_generation;resetAi();clearRasterCache();m_pending.clear();m_failed.clear();m_requests.clear();m_textPages.clear();m_textPending.clear();
            m_pages=info.value(QStringLiteral("pages")).toList();m_documentWidth=info.value(QStringLiteral("width")).toDouble();m_documentHeight=info.value(QStringLiteral("height")).toDouble();
            m_data.clear();m_data.insert(QStringLiteral("marks"),revision.value(QStringLiteral("marks")));m_data.insert(QStringLiteral("signature_status"),info.value(QStringLiteral("signature_status")));
            m_data.insert(QStringLiteral("xfa_status"),info.value(QStringLiteral("xfa_status")));
            m_data.insert(QStringLiteral("document_revision"),info.value(QStringLiteral("revision")));
            emit documentReset();emit documentChanged();emit dataChanged();emit textPagesChanged();
            submit(QStringLiteral("outline"));submit(QStringLiteral("metadata"));
            if(reloadForms)submit(QStringLiteral("forms"));
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
        } else if (!eraseControl) {
            const bool marks=operation==QStringLiteral("ink_erase_commit") || operation==QStringLiteral("marks") || operation.startsWith(QStringLiteral("mark_")) || operation.startsWith(QStringLiteral("marks_")) || operation.startsWith(QStringLiteral("bookmark_")) || operation.startsWith(QStringLiteral("file_"));
            m_data.insert(marks ? QStringLiteral("marks") : operation, outcome.result);
            emit dataChanged();
        }
        if (!outcome.error.isEmpty() && operation == QStringLiteral("text"))
            m_textPending.remove(arguments.value(QStringLiteral("page")).toInt());
        if(outcome.error.isEmpty() && draftMatchesRequest && m_editDrafts.value(draftKey)==savedDraft)
            setEditDraft(draftKey,{});
        if(!outcome.error.isEmpty() && operation==QStringLiteral("content_stage") && draftMatchesRequest && m_editDrafts.value(draftKey)==savedDraft) {
            auto preserved=savedDraft.toMap();preserved.insert(QStringLiteral("error"),outcome.error);setEditDraft(draftKey,preserved);
        }
        if(outcome.error.isEmpty() && operation==QStringLiteral("document_discard")) {
            for(auto it=discardedNotes.cbegin();it!=discardedNotes.cend();++it)if(m_noteDrafts.value(it.key())==it.value())clearNoteDraft(it.key());
            for(auto it=discardedEdits.cbegin();it!=discardedEdits.cend();++it)if(m_editDrafts.value(it.key())==it.value())setEditDraft(it.key(),{});
        }
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
        if(result.error.isEmpty() && (operation==QStringLiteral("content_stage") || operation==QStringLiteral("page_stage") || operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("page_apply") || operation==QStringLiteral("document_save") || operation==QStringLiteral("document_discard")))
            result.source=NativeRasterSource::prepare(document,false,&result.error);
        return result;
    };
    if(mutation || eraseControl || operation==QStringLiteral("ai_start") || operation==QStringLiteral("ai_cancel")){
        auto promise=std::make_shared<QPromise<CommandResult>>();promise->start();watcher->setFuture(promise->future());
        m_mutations->append([task,promise]{try{promise->addResult(task());}catch(...){promise->addResult(CommandResult{{},QStringLiteral("The command worker stopped unexpectedly.")});}promise->finish();});
    }else watcher->setFuture(QtConcurrent::run(std::move(task)));
    return id;
}

QStringList ReaderController::signatureFonts() const {return SignatureArtwork::fonts();}
QVariantMap ReaderController::typedSignatureImage(const QString &name,const QString &family) const {return SignatureArtwork::typed(name,family);}
QVariantMap ReaderController::signatureImage(const QUrl &url) const {
    if(!url.isLocalFile())return {{"error",tr("Choose a local PNG or JPEG signature image.")}};
    QFile file(url.toLocalFile());
    if(!file.open(QIODevice::ReadOnly) || file.size()>8*1024*1024)return {{"error",tr("The signature image could not be read or exceeds 8 MiB.")}};
    const auto bytes=file.read(8*1024*1024+1);const auto size=NativeImageProvider::artworkSize(bytes);
    if(size.isEmpty())return {{"error",tr("Choose a PNG or JPEG up to 8192 pixels per side and 16 megapixels.")}};
    return {{"image",QString::fromLatin1(bytes.toBase64())},{"width",size.width()},{"height",size.height()}};
}
void ReaderController::requestText(int page) {
    if (page < 0 || page >= pageCount() || m_textPages.contains(QString::number(page)) || m_textPending.contains(page)) return;
    m_textPending.insert(page);
    submit(QStringLiteral("text"), {{QStringLiteral("page"),page}});
}

void ReaderController::setLayout(const QString &mode, double gap) {
    submit(QStringLiteral("layout"), {{QStringLiteral("mode"),mode},{QStringLiteral("gap"),gap}});
}

double ReaderController::zoomOffset(double offset, double anchor, double oldZoom, double newZoom) const {
    return lyra_reader_desktop_zoom_offset(offset, anchor, oldZoom, newZoom);
}

QString ReaderController::rasterKey(int page, double scale,bool embedded) {
    return QString::number(page) + QLatin1Char(':') + QString::number(quantizedRasterScale(scale),'g',14)+(embedded?QStringLiteral(":annotations"):QString{});
}

QImage ReaderController::cachedPage(int page,double scale,bool embedded) const {
    return RasterCache::get(m_cachePrefix+rasterKey(page,scale,embedded));
}
QImage ReaderController::cachedTile(const QString &key)const{return RasterCache::get(m_cachePrefix+key);}
double ReaderController::tileScale(int level){return std::exp2(double(level)/4.0);}
void ReaderController::enqueue(const Request &request) {
    if(RasterCache::contains(m_cachePrefix+request.key) || m_pending.contains(request.key) || m_failed.contains(request.key))return;
    while(m_requests.size()>=128){m_pending.remove(m_requests.last().key);m_manualDemand.remove(m_requests.last().key);m_requests.removeLast();}
    m_pending.insert(request.key);
    auto position=m_requests.begin();while(position!=m_requests.end() && position->priority>=request.priority)++position;
    m_requests.insert(position,request);
}
void ReaderController::requestPage(int page,double scale,bool embedded) {
    requestPageInternal(page,scale,embedded,true);
}
void ReaderController::requestPageForConsumer(quintptr consumer,int page,double scale,bool embedded) {
    if(!m_source || page<0 || page>=pageCount() || !std::isfinite(scale) || scale<=0 || scale>128){clearRasterDemand(consumer);return;}
    m_pageDemand.insert(consumer,rasterKey(page,scale,embedded));pruneTileRequests();
    requestPageInternal(page,scale,embedded,false);
}
void ReaderController::requestPageInternal(int page,double scale,bool embedded,bool manual) {
    if(!m_source || page<0 || page>=pageCount() || !std::isfinite(scale) || scale<=0 || scale>128)return;
    scale=quantizedRasterScale(scale);const auto dimensions=m_pages.at(page).toMap();
    const QRectF region(0,0,dimensions.value(QStringLiteral("width")).toDouble(),dimensions.value(QStringLiteral("height")).toDouble());
    if(manual && !RasterCache::contains(m_cachePrefix+rasterKey(page,scale,embedded)))m_manualDemand.insert(rasterKey(page,scale,embedded));
    enqueue({page,scale,rasterKey(page,scale,embedded),embedded,false,region,embedded?0:2});startNextRaster();
}
void ReaderController::pruneTileRequests() {
    QSet<QString> wanted;for(const auto &keys:m_tileDemand)wanted.unite(keys);
    QSet<QString> pages=m_manualDemand;for(const auto &key:m_pageDemand)pages.insert(key);
    for(auto it=m_requests.begin();it!=m_requests.end();) {
        if(!(it->tile?wanted:pages).contains(it->key)){m_pending.remove(it->key);it=m_requests.erase(it);}else ++it;
    }
    if(m_activeRaster && !(m_activeRasterIsTile?wanted:pages).contains(m_activeRasterKey))RasterJobs::cancel(m_activeRaster);
}
void ReaderController::clearTileDemand(quintptr consumer){m_tileDemand.remove(consumer);pruneTileRequests();}
void ReaderController::clearRasterDemand(quintptr consumer){m_pageDemand.remove(consumer);clearTileDemand(consumer);}
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
    auto ticket=RasterJobs::enqueue();if(!ticket){
        if(!m_rasterRetryQueued){m_rasterRetryQueued=true;QTimer::singleShot(100,this,[this]{m_rasterRetryQueued=false;startNextRaster();});}
        return;
    }
    const auto request=m_requests.takeFirst();const auto generation=m_generation;const auto source=m_source;
    // Preview snapshots have no annotation overlay: bake PDF-owned annotations into each
    // raster without disabling PageItem's bounded tile path (the embedded-thumbnail flag).
    const bool annotated=request.embedded || m_snapshotMode;
    m_rendering=true;m_activeRaster=ticket;m_activeRasterKey=request.key;m_activeRasterIsTile=request.tile;
    auto *watcher=new QFutureWatcher<RasterResult>(this);
    connect(watcher,&QFutureWatcher<RasterResult>::finished,this,[this,watcher,request,generation]{
        auto result=watcher->result();watcher->deleteLater();m_rendering=false;m_activeRaster.reset();
        if(generation!=m_generation || result.cancelled){++m_discarded;if(generation==m_generation)m_pending.remove(request.key);}
        else if(result.pressure) {
            m_pending.remove(request.key);
            QTimer::singleShot(100,this,[this,request,generation] {
                if(generation!=m_generation)return;
                bool wanted=!request.tile && (m_manualDemand.contains(request.key) || m_pageDemand.values().contains(request.key));
                if(request.tile)for(const auto &keys:m_tileDemand)wanted=wanted || keys.contains(request.key);
                if(wanted){enqueue(request);startNextRaster();}
            });
        }else {
            m_pending.remove(request.key);
            m_manualDemand.remove(request.key);
            if(result.image.isNull()){m_failed.insert(request.key);setError(result.error);}
            else {
                RasterCache::put(m_cachePrefix+request.key,result.image.pixels);++m_completed;
                if(request.tile)emit tileReady(request.page);
                else {qInfo().nospace()<<"lyra-reader-qt-raster: page="<<request.page<<" requested="<<request.scale<<" actual="<<result.actualScale<<" bytes="<<result.image.pixels.sizeInBytes()<<" ms="<<result.elapsedMs<<" global-cache-kib="<<RasterCache::costKiB();emit pageReady(request.page,request.scale);}
            }
        }
        emit statisticsChanged();startNextRaster();
    });
    watcher->setFuture(QtConcurrent::run(RasterJobs::pool(),[source,request,ticket,annotated]{
        RasterJobs::Run run(ticket);RasterResult result;QElapsedTimer timer;timer.start();
        if(ticket->cancelled.load()){result.cancelled=true;return result;}
        auto reservation=RenderBudget::reserve(RenderBudget::Kind::Resident,RenderBudget::maximumJobBytes);
        if(!reservation){result.pressure=true;return result;}
        auto image=source->crop(request.page,request.region,request.scale,annotated,false,&result.error,&result.actualScale);
        if(!image.isNull())result.image=ResidentImage::publish(std::move(reservation),std::move(image));
        if(ticket->cancelled.load()){result.image={};result.cancelled=true;}
        result.elapsedMs=timer.elapsed();return result;
    }));
}
