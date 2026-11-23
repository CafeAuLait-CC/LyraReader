#include "ReaderController.h"
#include "NativeRaster.h"
#include "RenderBudget.h"
#include <QFutureWatcher>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>
#include <QUuid>
#include <QtConcurrentRun>
#include <cmath>
#include <limits>

namespace {
QString aiView(const QString &action) {
    if(action==QStringLiteral("RegionQuestion"))return QStringLiteral("region");
    if(action==QStringLiteral("TranslateSelection"))return QStringLiteral("translation");
    if(action==QStringLiteral("DocumentChat"))return QStringLiteral("chat");
    return QStringLiteral("summary");
}
}

QVariantList ReaderController::aiMathMarkup(const QString &text) const {
    if(text.size()>128*1024 || (!text.contains(QLatin1String("\\("))
        && !text.contains(QLatin1String("\\[")) && !text.contains(QLatin1Char('$'))))return {};
    const auto utf8=text.toUtf8();
    LyraReaderBuffer output{},error{};
    const bool ok=lyra_reader_desktop_math_markup(reinterpret_cast<const std::uint8_t *>(utf8.constData()),
        std::size_t(utf8.size()),&output,&error);
    const auto result=ok ? QJsonDocument::fromJson(QByteArray::fromRawData(
        reinterpret_cast<const char *>(output.data),qsizetype(output.len))).array().toVariantList() : QVariantList{};
    lyra_reader_desktop_buffer_free(output);
    lyra_reader_desktop_buffer_free(error);
    return result;
}

void ReaderController::initAi() {
    initTranslations();initDocumentReading();initRegionPersistence();initSummaryCatalog();initSummaryBatch();
    m_chatDraftTimer.setSingleShot(true);
    m_chatDraftTimer.setInterval(350);
    connect(&m_chatDraftTimer,&QTimer::timeout,this,[this]{flushAiChatDraft();});
    m_aiTimer.setInterval(60);
    connect(&m_aiTimer,&QTimer::timeout,this,[this]{
        if(!m_aiState.value(QStringLiteral("running")).toBool()){m_aiTimer.stop();return;}
        if(m_translationActive){if(!m_aiPollId)m_aiPollId=submit(QStringLiteral("translation_poll"),{{QStringLiteral("token"),m_translationActiveToken}});return;}
        if(!m_aiPollId)m_aiPollId=submit(m_summaryBatchActive?QStringLiteral("ai_summary_batch_poll"):QStringLiteral("ai_poll"),m_summaryBatchActive?QVariantMap{{QStringLiteral("token"),m_summaryBatchActiveToken}}:QVariantMap{});
    });
    connect(this,&ReaderController::commandFinished,this,&ReaderController::handleAiCommand);
}
void ReaderController::resetAi(bool preserveTranslationViews) {
    resetTranslations(preserveTranslationViews);resetSummaryBatch();
    ++m_aiPreviewEpoch;m_aiSummaryPreviewUnitId.clear();m_aiSummaryPreviewLanguage.clear();
    resetSummaryCatalog();
    resetRegionPersistence();
    m_aiRegionRestoreId=0;m_regionContinuationPending=false;m_regionContinuationSettings.clear();
    clearAiRegionPaper();
    resetDocumentReading();
    ++m_aiRegionEpoch;RasterJobs::cancel(m_aiRegionJob);m_aiRegionJob.reset();m_aiRegion.clear();emit aiRegionChanged();
    m_aiRegionImage=QUrl{};emit aiRegionImageChanged();
    m_regionHistory.clear();m_aiRegionSaveId=0;m_generatedRegionNoteSaveId=0;emit regionHistoryChanged();
    m_chatDraftTimer.stop();m_chatDraftSaveId=0;m_savedChatDraft.clear();m_chatDraftSnapshot.clear();m_afterChatDraft.reset();
    m_aiTimer.stop();m_aiPreviewId=0;m_aiStartId=0;m_aiPollId=0;m_aiChatLoadId=0;m_aiState.clear();emit aiStateChanged();
}
void ReaderController::cancelAiRegionCapture() {
    m_aiRegionRestoreId=0;m_regionContinuationPending=false;m_regionContinuationSettings.clear();
    m_pendingRegionCapture.clear();
    clearAiRegionPaper();
    ++m_aiRegionEpoch;RasterJobs::cancel(m_aiRegionJob);m_aiRegionJob.reset();
    if(m_aiRegion.value(QStringLiteral("loading")).toBool()){m_aiRegion.clear();emit aiRegionChanged();}
}
void ReaderController::resetAiRegion() {
    resetRegionPersistence();
    m_regionSaveError.clear();emit regionNoteDraftChanged();
    cancelAiRegionCapture();m_aiRegion.clear();
    m_aiRegionImage=QUrl{};emit aiRegionImageChanged();
    const auto responseView=m_aiState.value(QStringLiteral("responseView")).toString();
    if(m_aiState.value(QStringLiteral("running")).toBool() &&
       (responseView==QStringLiteral("region") || responseView==QStringLiteral("region_note")))cancelAi();
    const auto view=m_aiState.value(QStringLiteral("previewView")).toString();
    if(view==QStringLiteral("region") || view==QStringLiteral("region_note"))invalidateAiPlan();
    auto results=m_aiState.value(QStringLiteral("results")).toMap();
    results.remove(QStringLiteral("region"));results.remove(QStringLiteral("region_note"));
    m_aiState.insert(QStringLiteral("results"),results);
    m_aiState.remove(QStringLiteral("regionNoteCandidate"));
    if(!m_aiState.value(QStringLiteral("running")).toBool()
        && (responseView==QStringLiteral("region") || responseView==QStringLiteral("region_note"))) {
        for(const auto *key:{"output","reasoning","responsePlan","responseView","usage"})m_aiState.remove(QLatin1String(key));
    }
    const auto statusView=m_aiState.value(QStringLiteral("statusView")).toString();
    if(!m_aiState.value(QStringLiteral("running")).toBool()
        && (statusView==QStringLiteral("region") || statusView==QStringLiteral("region_note"))) {
        m_aiState.remove(QStringLiteral("statusView"));m_aiState.remove(QStringLiteral("status"));
    }
    emit aiStateChanged();
    emit aiRegionChanged();
}
bool ReaderController::captureAiRegion(int page,const QVariantMap &rect,double zoom) {
    if(!m_document || !m_source || m_loading)return false;
    if(m_aiRegion.contains(QStringLiteral("image_png")) && (regionNeedsSave() || m_aiRegionSaveId || regionRequestRunning())) {
        if(!m_regionSaveError.isEmpty()){setError(m_regionSaveError);return false;}
        m_pendingRegionCapture={{QStringLiteral("page"),page},{QStringLiteral("rect"),rect},{QStringLiteral("zoom"),zoom}};
        flushAiRegionNote();return true;
    }
    if(m_pendingCommands || m_aiState.value(QStringLiteral("running")).toBool())return false;
    resetAiRegion();
    // Snapshot only already indexed boxes on this page. Placement must not finish a
    // document-wide figure scan or consult a later, mutable tab state from the worker.
    const auto figures=m_data.value(QStringLiteral("figures")).toList();
    const auto geometryLimit=lyra_reader_desktop_paper_geometry_limit();
    const auto glyphs=m_textPages.value(QString::number(page)).toMap().value(QStringLiteral("chars"));
    const auto glyphCount=std::size_t(glyphs.toList().size());
    if(glyphCount>geometryLimit) {
        m_aiRegion={{QStringLiteral("error"),tr("The page contains too much text geometry to place this area safely.")}};
        emit aiRegionChanged();return false;
    }
    // Capture and PNG conversion hold at most two four-megapixel buffers. The shared Rust
    // guard checks exact geometry before PDFium allocates; this is the global admission lease.
    auto reservation=RenderBudget::reserve(RenderBudget::Kind::Resident,32LL*1024*1024);
    auto ticket=reservation ? RasterJobs::enqueue() : RasterJobs::Handle{};
    if(!ticket){m_aiRegion={{QStringLiteral("error"),tr("The renderer is busy. Try capturing this area again.")}};emit aiRegionChanged();return false;}
    const auto source=m_source;const auto generation=m_generation;const auto epoch=m_aiRegionEpoch;
    m_aiRegionJob=ticket;m_aiRegion={{QStringLiteral("loading"),true}};emit aiRegionChanged();
    struct Captured {QVariantMap data;QString error;QUrl image;};
    auto *watcher=new QFutureWatcher<Captured>(this);
    connect(watcher,&QFutureWatcher<Captured>::finished,this,[this,watcher,source,generation,epoch] {
        const auto result=watcher->result();watcher->deleteLater();
        if(epoch!=m_aiRegionEpoch || generation!=m_generation || source!=m_source)return;
        m_aiRegionJob.reset();m_aiRegion=result.data;
        if(result.error.isEmpty())m_aiRegion.insert(QStringLiteral("history_id"),QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper());
        m_aiRegionImage=result.image;emit aiRegionImageChanged();
        if(!result.error.isEmpty())m_aiRegion={{QStringLiteral("error"),result.error}};
        emit aiRegionChanged();
        if(result.error.isEmpty())markRegionDirty();
    });
    watcher->setFuture(QtConcurrent::run(RasterJobs::pool(),[source,ticket,reservation,page,rect,zoom,figures,glyphs,glyphCount,geometryLimit] {
        RasterJobs::Run run(ticket);Captured result;
        if(ticket->cancelled)return result;
        QVariantList indexedRegions;
        for(const auto &value:figures) {
            const auto figure=value.toMap();
            if(figure.value(QStringLiteral("page")).toInt()!=page)continue;
            if(std::size_t(indexedRegions.size())>=geometryLimit-glyphCount) {
                result.error=tr("The page contains too much figure geometry to place this area safely.");
                return result;
            }
            indexedRegions.append(figure);
        }
        QVariantMap request{{QStringLiteral("op"),QStringLiteral("capture_region")},{QStringLiteral("page"),page},{QStringLiteral("rect"),rect},{QStringLiteral("zoom"),zoom},{QStringLiteral("indexed_regions"),indexedRegions}};
        if(glyphs.isValid())request.insert(QStringLiteral("glyphs"),glyphs);
        result.data=source->query(request,&result.error).toMap();
        // URL construction can scan several MiB. Do it once on this worker, never in a
        // QML binding that is re-evaluated on every question keystroke or streaming poll.
        if(result.error.isEmpty())result.image=QUrl(QStringLiteral("data:image/png;base64,")+result.data.value(QStringLiteral("image_png")).toString());
        return result;
    }));
    return true;
}
quint64 ReaderController::reopenAiRegion(const QString &id,const QString &revision) {
    if(!m_document || !m_source || m_loading || m_pendingCommands || m_aiState.value(QStringLiteral("running")).toBool() || !m_regionNoteDraft.isEmpty() || !m_regionSaveError.isEmpty() || (hasUnsavedReadingNotes() && m_aiRegion.value(QStringLiteral("history_id")).toString()!=id))return 0;
    if(m_aiRegion.contains(QStringLiteral("image_png")) && !m_aiRegion.value(QStringLiteral("saved")).toBool() && m_aiRegion.value(QStringLiteral("history_id")).toString()!=id) {
        setError(tr("Save the current region to Reading notes before opening another conversation."));return 0;
    }
    m_aiRegionRestoreEpoch=m_aiRegionEpoch;
    m_aiRegionRestoreId=submit(QStringLiteral("region_reopen"),{{QStringLiteral("id"),id},{QStringLiteral("expected_history_revision"),revision}});
    return m_aiRegionRestoreId;
}
void ReaderController::clearAiRegionPaper() {
    ++m_aiRegionPaperEpoch;m_aiRegionPaperSpec.clear();
    if(m_aiRegionPaperCancel)m_aiRegionPaperCancel->store(true);
    if(m_aiRegionPaper.isEmpty())return;
    m_aiRegionPaper.clear();emit aiRegionPaperChanged();
}
double ReaderController::unshiftedPaperScroll(double displayY,double reveal) const {
    return mapPaperScroll(displayY,false,reveal);
}
double ReaderController::shiftedPaperScroll(double sourceY,double reveal) const {
    return mapPaperScroll(sourceY,true,reveal);
}
double ReaderController::mapPaperScroll(double value,bool shifted,double reveal) const {
    if(!std::isfinite(reveal) || reveal<0 || reveal>1)return std::numeric_limits<double>::quiet_NaN();
    const auto map=shifted ? lyra_reader_desktop_paper_shifted_scroll : lyra_reader_desktop_paper_unshifted_scroll;
    if(m_aiRegionPaper.isEmpty())return map(value,0,0);
    bool topOk=false,gapOk=false;
    const auto top=m_aiRegionPaper.value(QStringLiteral("gap_top")).toDouble(&topOk);
    const auto gap=m_aiRegionPaper.value(QStringLiteral("card")).toMap().value(QStringLiteral("gap_pt")).toDouble(&gapOk);
    // A first pending or failed plan has no valid display rows. Decline persistence until
    // the shell has a real map, rather than storing conversation coordinates as PDF points.
    if(!topOk || !gapOk)return std::numeric_limits<double>::quiet_NaN();
    return map(value,top,gap*reveal);
}
void ReaderController::configureAiRegionPaper(const QString &mode,double pageGap,double cardGap) {
    if(!m_source || m_loading || !m_aiRegion.contains(QStringLiteral("image_png"))) {clearAiRegionPaper();return;}
    const auto cardId=m_aiRegion.value(QStringLiteral("history_id")).toString();
    if(cardId.isEmpty()){clearAiRegionPaper();return;}
    if(!std::isfinite(cardGap) || cardGap<0 || !std::isfinite(pageGap)) {
        ++m_aiRegionPaperEpoch;
        if(m_aiRegionPaperCancel)m_aiRegionPaperCancel->store(true);
        m_aiRegionPaperSpec.clear();m_aiRegionPaper={{QStringLiteral("error"),tr("The inserted area layout is invalid.")}};
        emit aiRegionPaperChanged();return;
    }
    const auto plan=m_aiRegion.value(QStringLiteral("paper_plan")).toMap();
    const QVariantMap card{{QStringLiteral("page"),m_aiRegion.value(QStringLiteral("page"))},
        {QStringLiteral("split_pt"),plan.value(QStringLiteral("split_pt"))},{QStringLiteral("gap_pt"),cardGap}};
    const QVariantMap request{{QStringLiteral("op"),QStringLiteral("layout")},
        {QStringLiteral("mode"),mode},{QStringLiteral("gap"),pageGap},{QStringLiteral("paper_card"),card}};
    if(request==m_aiRegionPaperSpec && (m_aiRegionPaperInFlight || !m_aiRegionPaper.contains(QStringLiteral("error"))))return;
    ++m_aiRegionPaperEpoch;
    m_aiRegionPaperSpec=request;
    if(m_aiRegionPaperCancel)m_aiRegionPaperCancel->store(true);
    const bool wasLoading=m_aiRegionPaper.value(QStringLiteral("loading")).toBool();
    m_aiRegionPaper.insert(QStringLiteral("loading"),true);if(!wasLoading)emit aiRegionPaperChanged();
    startAiRegionPaperPlan();
}
void ReaderController::startAiRegionPaperPlan() {
    // One active snapshot per reader, plus the latest replaceable request. Epoch rejection
    // alone would still enqueue a document-sized allocation for every resize/zoom event.
    if(m_aiRegionPaperInFlight || m_aiRegionPaperSpec.isEmpty() || !m_source)return;
    m_aiRegionPaperInFlight=true;
    const auto request=m_aiRegionPaperSpec;const auto epoch=m_aiRegionPaperEpoch;
    const auto card=request.value(QStringLiteral("paper_card")).toMap();
    const auto cardId=m_aiRegion.value(QStringLiteral("history_id")).toString();
    const auto source=m_source;const auto generation=m_generation;const auto captureEpoch=m_aiRegionEpoch;
    const auto cancelled=std::make_shared<std::atomic_bool>(false);m_aiRegionPaperCancel=cancelled;
    struct Planned {QVariantMap value;QString error;bool cancelled=false;};
    auto *watcher=new QFutureWatcher<Planned>(this);
    connect(watcher,&QFutureWatcher<Planned>::finished,this,[this,watcher,source,generation,captureEpoch,epoch,cardId,card,cancelled] {
        const auto outcome=watcher->result();watcher->deleteLater();
        m_aiRegionPaperInFlight=false;m_aiRegionPaperCancel.reset();
        if(!outcome.cancelled && !cancelled->load() && epoch==m_aiRegionPaperEpoch && captureEpoch==m_aiRegionEpoch && generation==m_generation
                && source==m_source && cardId==m_aiRegion.value(QStringLiteral("history_id")).toString()) {
            if(!outcome.error.isEmpty())m_aiRegionPaper={{QStringLiteral("error"),outcome.error}};
            else {
                m_aiRegionPaper=outcome.value;m_aiRegionPaper.insert(QStringLiteral("id"),cardId);
                m_aiRegionPaper.insert(QStringLiteral("card"),card);
                m_aiRegionPaper.insert(QStringLiteral("source_sha256"),m_aiRegion.value(QStringLiteral("source_sha256")));
            }
            emit aiRegionPaperChanged();
        }
        if(epoch!=m_aiRegionPaperEpoch)startAiRegionPaperPlan();
    });
    watcher->setFuture(QtConcurrent::run([source,request,cancelled] {
        Planned outcome;if(cancelled->load()){outcome.cancelled=true;return outcome;}
        const auto packet=source->query(request,&outcome.error).toMap();
        if(cancelled->load()){outcome.cancelled=true;return outcome;}
        if(outcome.error.isEmpty()) {
            outcome.value=packet.value(QStringLiteral("paper")).toMap();
            if(outcome.value.isEmpty())outcome.error=tr("The renderer did not return the inserted area layout.");
        }
        return outcome;
    }));
}
void ReaderController::setAiRegionQuestion(const QString &text) {
    if(m_aiRegion.value(QStringLiteral("question")).toString()==text)return;
    m_aiRegion.insert(QStringLiteral("question"),text);markRegionDirty(true);
    const auto view=m_aiState.value(QStringLiteral("previewView")).toString();
    if(view==QStringLiteral("region") || view==QStringLiteral("region_note"))invalidateAiPlan();
    emit aiRegionChanged();
}
void ReaderController::prepareAiRegion(const QVariantMap &settings,bool knowledgeNote) {
    if(!m_aiRegion.contains(QStringLiteral("image_png")) || m_aiRegion.value(QStringLiteral("loading")).toBool() || m_pendingCommands || m_aiState.value(QStringLiteral("running")).toBool())return;
    const QString chatgptAccount=knowledgeNote?QString{}:settings.value(QStringLiteral("chatgptAccount")).toString();
    if(regionNeedsSave()) {
        if(knowledgeNote)return;
        invalidateAiPlan();m_regionContinuationPending=true;m_regionContinuationSettings=settings;
        m_regionContinuationQuestion=m_aiRegion.value(QStringLiteral("question")).toString();m_regionContinuationEpoch=m_aiRegionEpoch;
        if(!chatgptAccount.isEmpty())m_aiState.insert(QStringLiteral("previewChatGptAccount"),chatgptAccount);
        m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("region"));
        m_aiState.insert(QStringLiteral("status"),tr("Saving this conversation before preparing the question…"));emit aiStateChanged();
        if(!saveAiRegionNote()){m_regionContinuationPending=false;m_regionContinuationSettings.clear();}
        return;
    }
    QVariantMap region;
    for(const auto *key:{"page","x_pt","y_pt","width_pt","height_pt","text","image_png","image_width_px","image_height_px"})region.insert(QLatin1String(key),m_aiRegion.value(QLatin1String(key)));
    region.insert(QStringLiteral("send_image"),!chatgptAccount.isEmpty() || settings.value(QStringLiteral("imageInput"),false).toBool());
    region.insert(QStringLiteral("include_document_context"),false);
    QVariantMap request{{QStringLiteral("action"),QStringLiteral("RegionQuestion")},{QStringLiteral("current_page"),region.value(QStringLiteral("page"))},
        {QStringLiteral("selection"),QVariant{}},{QStringLiteral("question"),m_aiRegion.value(QStringLiteral("question"))},
        {QStringLiteral("language"),QVariant{}},{QStringLiteral("history"),QVariantList{}},{QStringLiteral("region"),region},
        {QStringLiteral("document_knowledge"),false},{QStringLiteral("document_knowledge_text"),QVariant{}},{QStringLiteral("document_knowledge_pages"),QVariantList{}},
        {QStringLiteral("base_url"),settings.value(QStringLiteral("baseUrl"),QStringLiteral("http://localhost:11434/v1"))},{QStringLiteral("model"),settings.value(QStringLiteral("model"),QString{})},
        {QStringLiteral("temperature"),QVariant{}},{QStringLiteral("max_tokens"),QVariant{}},
        {QStringLiteral("reasoning_mode"),settings.value(QStringLiteral("reasoningMode"),QStringLiteral("default"))},{QStringLiteral("reasoning_encoding"),settings.value(QStringLiteral("reasoningEncoding"),QStringLiteral("none"))}};
    if(!knowledgeNote) {
        if(!chatgptAccount.isEmpty())request.insert(QStringLiteral("chatgpt_account"),chatgptAccount);
        prepareAi(request);
        return;
    }
    const auto revision=m_regionHistory.value(QStringLiteral("revision")).toString();
    if(!m_aiRegion.value(QStringLiteral("persisted")).toBool() || revision.isEmpty()
        || !m_regionNoteDraft.isEmpty() || !m_regionSaveError.isEmpty())return;
    request.insert(QStringLiteral("action"),QStringLiteral("SummarizeDocument"));
    request.insert(QStringLiteral("region"),QVariant{});
    request.insert(QStringLiteral("question"),QVariant{});
    prepareAi(request,{},{{QStringLiteral("kind"),QStringLiteral("region_note")},{QStringLiteral("detail"),QStringLiteral("Standard")},
        {QStringLiteral("id"),m_aiRegion.value(QStringLiteral("history_id"))},{QStringLiteral("expected_history_revision"),revision}});
}
bool ReaderController::saveGeneratedRegionNote() {
    const auto candidate=m_aiState.value(QStringLiteral("regionNoteCandidate")).toMap();
    const auto id=candidate.value(QStringLiteral("id")).toString();
    if(!m_document || m_pendingCommands || hasUnsavedReadingNotes() || m_aiState.value(QStringLiteral("running")).toBool()
        || id.isEmpty() || id!=m_aiRegion.value(QStringLiteral("history_id")).toString())return false;
    m_generatedRegionNoteSaveId=m_commandSequence+1;
    return submit(QStringLiteral("region_save_generated_note"),{{QStringLiteral("id"),id},
        {QStringLiteral("text"),candidate.value(QStringLiteral("content"))},
        {QStringLiteral("expected_history_revision"),candidate.value(QStringLiteral("revision"))}})!=0;
}
void ReaderController::dismissGeneratedRegionNote() {
    if(m_generatedRegionNoteSaveId || !m_aiState.remove(QStringLiteral("regionNoteCandidate")))return;
    emit aiStateChanged();
}
void ReaderController::setAiInput(const QString &key,const QVariant &value) {
    m_regionContinuationPending=false;m_regionContinuationSettings.clear();
    auto input=m_aiState.value(QStringLiteral("input")).toMap();
    if(key==QStringLiteral("view")) {
        const auto view=value.toString();
        if(view!=QStringLiteral("summary") && view!=QStringLiteral("translation") && view!=QStringLiteral("chat"))return;
        if(input.value(key)==value)return;
        input.insert(key,view);
        input.insert(QStringLiteral("action"),view==QStringLiteral("chat")?4:view==QStringLiteral("translation")?3:input.value(QStringLiteral("summaryAction"),1).toInt());
        input.insert(QStringLiteral("question"),input.value(view==QStringLiteral("chat")?QStringLiteral("chatQuestion"):QStringLiteral("selectionQuestion")));
        m_aiState.insert(QStringLiteral("input"),input);emit aiStateChanged();return;
    }
    if(key==QStringLiteral("summaryDetail")) {
        const auto detail=value.toString();
        if(detail!=QStringLiteral("Brief") && detail!=QStringLiteral("Standard") && detail!=QStringLiteral("Detailed"))return;
    } else if(key==QStringLiteral("translationScope")) {
        const auto scope=value.toString();
        if(scope!=QStringLiteral("selection") && scope!=QStringLiteral("document"))return;
    } else if(key!=QStringLiteral("action") && key!=QStringLiteral("question") && key!=QStringLiteral("language") && key!=QStringLiteral("inplace"))return;
    if(input.value(key)==value && !(key==QStringLiteral("action") && !m_summaryUnitContext.isEmpty()))return;
    if(key==QStringLiteral("action")) {
        bool valid=false;const auto action=value.toInt(&valid);
        if(!valid || action<0 || action>5)return;
        const auto view=action==4?QStringLiteral("chat"):action==3?QStringLiteral("translation"):QStringLiteral("summary");
        input.insert(QStringLiteral("view"),view);
        if(view==QStringLiteral("summary"))input.insert(QStringLiteral("summaryAction"),action);
        input.insert(QStringLiteral("question"),input.value(view==QStringLiteral("chat")?QStringLiteral("chatQuestion"):QStringLiteral("selectionQuestion")));
    }
    const bool chatEdit=key==QStringLiteral("question") && input.value(QStringLiteral("view"))==QStringLiteral("chat");
    if(chatEdit && (documentRevisionPending() || m_aiState.value(QStringLiteral("chatReadOnly")).toBool()))return;
    if(key==QStringLiteral("question"))input.insert(chatEdit?QStringLiteral("chatQuestion"):QStringLiteral("selectionQuestion"),value);
    const bool clearedUnit=key==QStringLiteral("action") && input.value(QStringLiteral("view")).toString()==QStringLiteral("summary") && !m_summaryUnitContext.isEmpty();
    if(clearedUnit)m_summaryUnitContext.clear();
    if(!m_translationActive && !m_translationPreparedToken.isEmpty()) {
        if(m_document)lyra_reader_desktop_cancel_translation(m_document.get());m_translationPreparedToken.clear();
    }
    input.insert(key,value);m_aiState.insert(QStringLiteral("input"),input);
    if(key==QStringLiteral("action") || key==QStringLiteral("summaryDetail") || key==QStringLiteral("language"))
        m_aiState.remove(QStringLiteral("cachedWholeSummary"));
    if(chatEdit) {
        if(chatDraftPending() && !m_aiState.value(QStringLiteral("activeChat")).toBool())
            m_chatDraftTimer.start();
        else
            m_chatDraftTimer.stop();
    }
    ++m_aiPreviewEpoch;m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));
    if(!m_aiState.value(QStringLiteral("running")).toBool()) {
        m_aiState.insert(QStringLiteral("statusView"),input.value(QStringLiteral("view"),QStringLiteral("summary")));
        m_aiState.insert(QStringLiteral("status"),tr("Preview the updated request before sending."));
    }
    QPointer<ReaderController> alive(this);
    if(clearedUnit)emit summaryCatalogChanged();
    if(alive)emit aiStateChanged();
}
void ReaderController::invalidateAiPlan() {
    m_summaryCacheId=0;
    const bool hadPreview=m_aiPreviewId || m_aiState.contains(QStringLiteral("plan")) || m_regionContinuationPending;
    m_regionContinuationPending=false;m_regionContinuationSettings.clear();
    ++m_aiPreviewEpoch;m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));
    m_aiState.remove(QStringLiteral("previewChatGptAccount"));
    m_summaryBatchPreparedToken.clear();
    m_translationPreparedToken.clear();if(m_document)lyra_reader_desktop_cancel_translation(m_document.get());
    if(m_translationActive){cancelInplaceTranslation();return;}
    if(m_summaryBatchActive){cancelSummaryBatch();return;}
    if(m_document && !m_summaryBatchState.isEmpty())lyra_reader_desktop_cancel_summary_batch(m_document.get());
    if(hadPreview){
        if(!m_aiState.value(QStringLiteral("running")).toBool())m_aiState.insert(QStringLiteral("status"),tr("Preview the updated request before sending."));
        emit aiStateChanged();
    }
}
void ReaderController::resetAiChat() {
    m_aiChatLoadId=0;
    m_chatDraftTimer.stop();
    m_savedChatDraft.clear();
    for(const auto *key:{"chatTurns","conversationLimited","chatSession","chatModified","chatReadOnly","chatHistoryWarning","chatDraftWarning"})m_aiState.remove(QLatin1String(key));
    auto results=m_aiState.value(QStringLiteral("results")).toMap();results.remove(QStringLiteral("chat"));m_aiState.insert(QStringLiteral("results"),results);
    if(m_aiState.value(QStringLiteral("previewView")).toString()==QStringLiteral("chat")){++m_aiPreviewEpoch;m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));}
    if(m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("chat")) {
        for(const auto *key:{"output","reasoning","responsePlan","usage","responseView"})m_aiState.remove(QLatin1String(key));
    }
}
void ReaderController::clearAiChat() {
    if(m_aiState.value(QStringLiteral("running")).toBool())return;
    if(chatDraftPending()){newAiChat();return;}
    resetAiChat();
    m_savedChatDraft=chatDraft();
    m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("chat"));m_aiState.insert(QStringLiteral("status"),tr("New conversation ready."));emit aiStateChanged();
}
void ReaderController::newAiChat() {
    if(m_chatDeferredCommand || m_aiState.value(QStringLiteral("running")).toBool())return;
    m_afterChatDraft=QString{};
    if(chatDraftPending())flushAiChatDraft();
    else finishChatTransition();
}
bool ReaderController::reopenAiChat(const QString &id) {
    if(id.isEmpty() || !m_document || m_chatDeferredCommand || (m_pendingCommands && !chatDraftPending())
        || m_aiState.value(QStringLiteral("running")).toBool())return false;
    m_afterChatDraft=id;
    if(chatDraftPending())flushAiChatDraft();
    else finishChatTransition();
    return true;
}
void ReaderController::finishChatTransition() {
    if(!m_afterChatDraft || chatDraftPending())return;
    const auto id=*m_afterChatDraft;
    m_afterChatDraft.reset();
    if(id.isEmpty()) {
        resetAiChat();
        setChatDraft({});
        m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("chat"));
        m_aiState.insert(QStringLiteral("status"),tr("New conversation ready."));
        emit aiStateChanged();
        return;
    }
    m_aiChatLoadEpoch=++m_aiPreviewEpoch;
    m_aiChatLoadId=submit(QStringLiteral("ai_chat_session"),{{QStringLiteral("id"),id}});
}
QString ReaderController::chatDraft()const {
    return m_aiState.value(QStringLiteral("input")).toMap().value(QStringLiteral("chatQuestion")).toString();
}
void ReaderController::setChatDraft(const QString &draft) {
    auto input=m_aiState.value(QStringLiteral("input")).toMap();
    input.insert(QStringLiteral("chatQuestion"),draft);
    if(input.value(QStringLiteral("view"))==QStringLiteral("chat"))
        input.insert(QStringLiteral("question"),draft);
    m_aiState.insert(QStringLiteral("input"),input);
}
QString ReaderController::ensureChatSession() {
    auto session=m_aiState.value(QStringLiteral("chatSession")).toString();
    if(session.isEmpty()) {
        session=QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
        m_aiState.insert(QStringLiteral("chatSession"),session);
    }
    return session;
}
bool ReaderController::chatDraftPending()const {
    return m_document && !m_snapshotMode && !m_aiState.value(QStringLiteral("chatReadOnly")).toBool()
        && (m_chatDraftSaveId || chatDraft()!=m_savedChatDraft);
}
bool ReaderController::chatDraftSaving()const {
    return chatDraftPending() && (m_chatDraftSaveId || m_chatDraftTimer.isActive() || m_aiState.value(QStringLiteral("activeChat")).toBool());
}
void ReaderController::flushAiChatDraft(bool stopResponse) {
    if(!chatDraftPending() || m_chatDraftSaveId)return;
    if(m_aiState.value(QStringLiteral("activeChat")).toBool()) {
        if(stopResponse && !m_aiState.value(QStringLiteral("cancelRequested")).toBool())cancelAi();
        return;
    }
    m_chatDraftTimer.stop();
    m_chatDraftSnapshot=chatDraft();
    if(m_chatDraftSnapshot.isEmpty() && m_aiState.value(QStringLiteral("chatModified")).isNull()) {
        m_savedChatDraft.clear();
        if(m_chatDeferredCommand)finishChatDeferredCommand({});
        else if(m_afterChatDraft)finishChatTransition();
        else emit aiStateChanged();
        return;
    }
    const QVariantMap draft{{QStringLiteral("session_id"),ensureChatSession()},
        {QStringLiteral("expected_modified"),m_aiState.value(QStringLiteral("chatModified"))},
        {QStringLiteral("question"),m_chatDraftSnapshot}};
    QPointer<ReaderController> alive(this);
    const auto generation=m_generation;
    m_chatDraftSaveId=m_commandSequence+1;
    submit(QStringLiteral("ai_chat_draft"),{{QStringLiteral("draft"),draft}});
    if(!alive || generation!=m_generation)return;
    emit aiStateChanged();
}
void ReaderController::discardAiChatDraft() {
    if(m_chatDraftSaveId || m_aiState.value(QStringLiteral("activeChat")).toBool())return;
    m_chatDraftTimer.stop();
    m_afterChatDraft.reset();
    setChatDraft(m_savedChatDraft);
    m_aiState.remove(QStringLiteral("chatDraftWarning"));
    if(m_aiState.value(QStringLiteral("previewView"))==QStringLiteral("chat")) {
        ++m_aiPreviewEpoch;m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));
    }
    emit aiStateChanged();
}
void ReaderController::finishChatDraftSave(const QVariantMap &result,const QString &error) {
    m_chatDraftSaveId=0;
    if(!error.isEmpty()) {
        m_chatDraftTimer.stop();
        m_afterChatDraft.reset();
        m_aiState.insert(QStringLiteral("chatDraftWarning"),error);
        QPointer<ReaderController> alive(this);
        if(m_chatDeferredCommand)finishChatDeferredCommand(error);
        if(!alive)return;
        emit aiStateChanged();
        return;
    }
    m_aiState.remove(QStringLiteral("chatDraftWarning"));
    m_aiState.insert(QStringLiteral("chatModified"),result.value(QStringLiteral("modified")));
    m_savedChatDraft=m_chatDraftSnapshot;
    if(chatDraftPending()) {
        m_chatDraftTimer.start();
    } else if(m_chatDeferredCommand) {
        m_afterChatDraft.reset();
        QPointer<ReaderController> alive(this);
        finishChatDeferredCommand({});
        if(!alive)return;
    } else if(m_afterChatDraft) {
        finishChatTransition();
        return;
    }
    emit aiStateChanged();
}
void ReaderController::finishChatDeferredCommand(const QString &draftError) {
    if(!m_chatDeferredCommand)return;
    auto pending=std::move(*m_chatDeferredCommand);
    m_chatDeferredCommand.reset();
    --m_pendingCommands;
    if(draftError.isEmpty() && pending.generation==m_generation && pending.mutation==m_mutationSequence) {
        // The command retains its original ID and continues against the same PDF revision.
        // Its submission replaces the placeholder pending count.
        QPointer<ReaderController> alive(this);
        const auto count=m_pendingCommands;
        submitWithId(pending.id,pending.operation,pending.arguments);
        if(alive && m_pendingCommands==count)emit commandsChanged();
        return;
    }
    const auto error=draftError.isEmpty()?tr("The document changed while the chat draft was saving. Review the operation again.")
                                         :tr("The chat draft could not be saved. %1").arg(draftError);
    QPointer<ReaderController> alive(this);
    emit commandsChanged();
    if(!alive)return;
    setError(error);
    if(alive)emit commandFinished(pending.id,pending.operation,{},error);
}
void ReaderController::prepareAi(const QVariantMap &request,const QVariantMap &unit,const QVariantMap &reading) {
    if(!m_document || m_aiState.value(QStringLiteral("running")).toBool())return;
    if(request.value(QStringLiteral("action"))==QStringLiteral("DocumentChat") && m_aiState.value(QStringLiteral("chatReadOnly")).toBool())return;
    const auto readingKind=reading.value(QStringLiteral("kind")).toString();
    const auto previewView=(readingKind==QStringLiteral("translation") || readingKind==QStringLiteral("note") || readingKind==QStringLiteral("region_note"))
        ? readingKind : aiView(request.value(QStringLiteral("action")).toString());
    const auto document=m_document;const auto generation=m_generation;const auto epoch=++m_aiPreviewEpoch;
    QPointer<ReaderController> alive(this);
    const auto current=[&]{return alive && document==m_document && generation==m_generation && epoch==m_aiPreviewEpoch;};
    m_aiPreviewId=0;
    m_summaryBatchPreparedToken.clear();
    auto workspaceInput=m_aiState.value(QStringLiteral("input")).toMap();workspaceInput.remove(QStringLiteral("summaryBatch"));m_aiState.insert(QStringLiteral("input"),workspaceInput);
    if(unit.isEmpty() && previewView==QStringLiteral("summary") && !m_summaryUnitContext.isEmpty()) {
        m_summaryUnitContext.clear();emit summaryCatalogChanged();if(!current())return;
    }
    m_aiSummaryPreviewUnitId=unit.isEmpty()?QString{}:m_summaryUnitContext.value(QStringLiteral("id")).toString();
    m_summaryCacheId=0;m_aiState.remove(QStringLiteral("cacheWarning"));
    m_aiSummaryPreviewLanguage=unit.isEmpty()?QString{}:request.value(QStringLiteral("language")).toString();
    if(previewView==QStringLiteral("summary"))m_aiState.remove(QStringLiteral("cachedWholeSummary"));
    if(reading.isEmpty() && previewView!=QStringLiteral("translation") && !m_readingChoiceShown && !m_documentReading.value(QStringLiteral("ready")).toBool()) {
        m_readingChoiceShown=true;m_readingChoicePending=true;emit documentReadingChanged();if(!current())return;
    }
    auto input=request;
    if(input.value(QStringLiteral("action")).toString()==QStringLiteral("DocumentChat")) {
        bool valid=false;const auto limit=m_data.value(QStringLiteral("ai_history_limit")).toUInt(&valid);
        if(!valid || !limit){m_aiState.insert(QStringLiteral("status"),tr("Reopen the document to load its conversation limits."));emit aiStateChanged();return;}
        QVariantList history;
        for(const auto &value:m_aiState.value(QStringLiteral("chatTurns")).toList()) {
            const auto turn=value.toMap();const auto state=turn.value(QStringLiteral("state")).toString();
            if((state==QStringLiteral("finished") || state==QStringLiteral("cancelled")) && !turn.value(QStringLiteral("answer")).toString().trimmed().isEmpty())
                history.append(QVariantMap{{QStringLiteral("question"),turn.value(QStringLiteral("question"))},{QStringLiteral("answer"),turn.value(QStringLiteral("answer"))}});
        }
        input.insert(QStringLiteral("history"),history);
    }
    m_aiState.insert(QStringLiteral("previewQuestion"),unit.isEmpty()?input.value(QStringLiteral("question")):QVariant{});
    m_aiState.insert(QStringLiteral("previewSelection"),reading.isEmpty()?QVariant{}:input.value(QStringLiteral("selection")));
    m_aiState.insert(QStringLiteral("planSent"),false);
    m_aiState.insert(QStringLiteral("previewView"),previewView);
    m_aiState.insert(QStringLiteral("previewChatGptAccount"),input.value(QStringLiteral("chatgpt_account")));
    if(previewView==QStringLiteral("note"))m_aiState.remove(QStringLiteral("noteSuggestion"));
    m_aiState.insert(QStringLiteral("statusView"),m_aiState.value(QStringLiteral("previewView")));
    m_aiState.remove(QStringLiteral("plan"));m_aiState.insert(QStringLiteral("status"),tr("Preparing request locally…"));
    m_aiPlanGeneration=m_generation;emit aiStateChanged();if(!current())return;
    QVariantMap preview{{QStringLiteral("request"),input}};
    if(!reading.isEmpty())preview.insert(QStringLiteral("reading"),reading);
    if(input.value(QStringLiteral("action")).toString()==QStringLiteral("RegionQuestion") && m_aiRegion.value(QStringLiteral("persisted")).toBool())preview.insert(QStringLiteral("region_history_id"),m_aiRegion.value(QStringLiteral("history_id")));
    if(!unit.isEmpty())preview.insert(QStringLiteral("unit"),unit);
    const auto id=submit(unit.isEmpty()?QStringLiteral("ai_preview"):QStringLiteral("ai_summary_prepare"),preview);
    if(current())m_aiPreviewId=id;
}

bool ReaderController::startAi(const QString &key,const QVariantMap &expectedPlan) {
    const auto plan=m_aiState.value(QStringLiteral("plan")).toMap();
    if(!m_document || m_pendingCommands>0 || m_loading || plan.isEmpty() || plan!=expectedPlan || m_aiPlanGeneration!=m_generation || m_aiState.value(QStringLiteral("running")).toBool())return false;
    if(regionNeedsSave() || m_aiRegionSaveId) {
        flushAiRegionNote(false);
        m_aiState.insert(QStringLiteral("status"),tr("Saving reading notes. Send again when saving has finished."));emit aiStateChanged();return false;
    }
    if(plan.value(QStringLiteral("kind")).toString()==QStringLiteral("inplace_translation"))return startInplaceTranslation(key,plan);
    if(plan.value(QStringLiteral("kind")).toString()==QStringLiteral("summary_batch"))return startSummaryBatch(key,plan);
    const auto kind=plan.value(QStringLiteral("kind")).toString();
    if(kind==QStringLiteral("summary_synthesis")) {
        if(m_aiState.value(QStringLiteral("responsePlan")).toMap().value(QStringLiteral("kind"))==QStringLiteral("reading_summary")) {
            const auto parts=m_aiState.value(QStringLiteral("results")).toMap().value(QStringLiteral("summary"));
            m_aiState.insert(QStringLiteral("synthesisParts"),parts);
        }
    } else {
        m_aiState.remove(QStringLiteral("synthesisParts"));
    }
    m_aiActivePreviewEpoch=m_aiPreviewEpoch;
    const auto action=plan.value(QStringLiteral("action")).toString();
    if(action==QStringLiteral("DocumentChat") && m_aiState.value(QStringLiteral("chatReadOnly")).toBool())return false;
    if(action==QStringLiteral("SummarizeAbstract") || action==QStringLiteral("SummarizeSection") || action==QStringLiteral("SummarizePageLine")) {
        m_aiState.insert(QStringLiteral("unitTitle"),m_summaryUnitContext.value(QStringLiteral("title"),m_summaryUnitContext.value(QStringLiteral("unit")).toMap().value(QStringLiteral("title"))));
        m_aiState.insert(QStringLiteral("unitLanguage"),m_aiSummaryPreviewLanguage);
    }else {m_aiState.remove(QStringLiteral("unitTitle"));m_aiState.remove(QStringLiteral("unitLanguage"));}
    m_aiState.insert(QStringLiteral("responsePlan"),plan);
    m_aiState.remove(QStringLiteral("summaryNoteSource"));
    m_aiState.insert(QStringLiteral("planSent"),true);
    const auto responseView=kind==QStringLiteral("reading_note_suggestion") ? QStringLiteral("note")
        : kind==QStringLiteral("region_knowledge_note") ? QStringLiteral("region_note") : aiView(action);
    m_aiState.insert(QStringLiteral("responseView"),responseView);
    if(responseView==QStringLiteral("region_note"))m_aiState.remove(QStringLiteral("regionNoteCandidate"));
    m_aiState.insert(QStringLiteral("statusView"),m_aiState.value(QStringLiteral("responseView")));
    m_aiState.insert(QStringLiteral("activeChat"),action==QStringLiteral("DocumentChat"));
    m_aiState.insert(QStringLiteral("activeQuestion"),m_aiState.value(QStringLiteral("previewQuestion")));
    m_aiState.insert(QStringLiteral("terminalReceived"),false);
    m_aiState.insert(QStringLiteral("cancelRequested"),false);
    m_aiState.insert(QStringLiteral("output"),QString{});m_aiState.insert(QStringLiteral("reasoning"),QString{});
    m_aiState.remove(QStringLiteral("translationBlocks"));m_aiState.remove(QStringLiteral("translationWarning"));
    m_aiState.remove(QStringLiteral("translationHistoryWarning"));
    m_aiState.insert(QStringLiteral("usage"),QVariantMap{});m_aiState.insert(QStringLiteral("diagnostics"),QVariantMap{});
    m_aiState.insert(QStringLiteral("limited"),false);m_aiState.insert(QStringLiteral("running"),true);
    m_aiState.insert(QStringLiteral("status"),tr("Starting request…"));
    m_aiState.insert(QStringLiteral("activeHost"),plan.value(QStringLiteral("host")));
    m_aiState.insert(QStringLiteral("activeModel"),plan.value(QStringLiteral("model")));
    QVariantMap args{{QStringLiteral("plan"),plan}};
    if(plan.contains(QStringLiteral("chatgpt_account"))) {
        args.insert(QStringLiteral("chatgpt_account"),plan.value(QStringLiteral("chatgpt_account")));
        args.insert(QStringLiteral("chatgpt_access_token"),key);
    } else {
        args.insert(QStringLiteral("api_key"),key);
    }
    if(action==QStringLiteral("DocumentChat")) {
        m_chatDraftTimer.stop();
        m_aiState.insert(QStringLiteral("activeChatDraft"),chatDraft());
        args.insert(QStringLiteral("chat"),QVariantMap{{QStringLiteral("session_id"),ensureChatSession()},
            {QStringLiteral("expected_modified"),m_aiState.value(QStringLiteral("chatModified"))},
            {QStringLiteral("draft_snapshot"),m_aiState.value(QStringLiteral("activeChatDraft"))},
            {QStringLiteral("question"),m_aiState.value(QStringLiteral("activeQuestion"))}});
        m_aiState.remove(QStringLiteral("chatHistoryWarning"));
    }
    emit aiStateChanged();
    m_aiState.insert(QStringLiteral("chatOutcome"),QStringLiteral("failed"));
    if(plan.value(QStringLiteral("action")).toString()==QStringLiteral("RegionQuestion")) {
        const auto turn=QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
        m_aiState.insert(QStringLiteral("regionTurn"),turn);args.insert(QStringLiteral("region_id"),m_aiRegion.value(QStringLiteral("history_id")));args.insert(QStringLiteral("turn_id"),turn);
        m_aiRegion.insert(QStringLiteral("saved"),false);emit aiRegionChanged();
    }
    m_aiStartId=submit(QStringLiteral("ai_start"),args);
    if(plan.value(QStringLiteral("action")).toString()==QStringLiteral("RegionQuestion"))markRegionDirty();
    return true;
}
void ReaderController::retainAiResult(const QString &state) {
    const auto view=m_aiState.value(QStringLiteral("responseView")).toString();
    if(view.isEmpty())return;
    QVariantMap result{{QStringLiteral("state"),state},{QStringLiteral("generation"),m_generation}};
    if(view==QStringLiteral("region")){result.insert(QStringLiteral("turn_id"),m_aiState.value(QStringLiteral("regionTurn")));result.insert(QStringLiteral("question"),m_aiState.value(QStringLiteral("activeQuestion")));}
    for(const auto *key:{"output","reasoning","usage","status","responsePlan","translationBlocks","translationWarning","translationHistoryWarning","synthesisParts","summaryNoteSource"})result.insert(QLatin1String(key),m_aiState.value(QLatin1String(key)));
    if(m_aiState.contains(QStringLiteral("unitTitle")))result.insert(QStringLiteral("unitTitle"),m_aiState.value(QStringLiteral("unitTitle")));
    if(m_aiState.contains(QStringLiteral("unitLanguage")))result.insert(QStringLiteral("unitLanguage"),m_aiState.value(QStringLiteral("unitLanguage")));
    auto results=m_aiState.value(QStringLiteral("results")).toMap();results.insert(view,result);m_aiState.insert(QStringLiteral("results"),results);
}
void ReaderController::cancelAi() {
    if(m_translationActive){cancelInplaceTranslation();return;}
    if(m_summaryBatchActive){cancelSummaryBatch();return;}
    if(!m_aiState.value(QStringLiteral("running")).toBool())return;
    m_aiState.insert(QStringLiteral("cancelRequested"),true);
    m_aiState.insert(QStringLiteral("status"),tr("Cancelling…"));emit aiStateChanged();submit(QStringLiteral("ai_cancel"));
}
void ReaderController::finishAiChat(const QString &state,const QString &noteSource) {
    if(!m_aiState.value(QStringLiteral("activeChat")).toBool())return;
    m_aiState.insert(QStringLiteral("activeChat"),false);
    if(chatDraftPending())m_chatDraftTimer.start();
    auto turns=m_aiState.value(QStringLiteral("chatTurns")).toList();const auto plan=m_aiState.value(QStringLiteral("responsePlan")).toMap();
    turns.append(QVariantMap{{QStringLiteral("question"),m_aiState.value(QStringLiteral("activeQuestion"))},{QStringLiteral("answer"),m_aiState.value(QStringLiteral("output"))},{QStringLiteral("reasoning"),m_aiState.value(QStringLiteral("reasoning"))},{QStringLiteral("usage"),m_aiState.value(QStringLiteral("usage"))},{QStringLiteral("state"),state},{QStringLiteral("sources"),plan.value(QStringLiteral("sources"))},{QStringLiteral("source_pages"),plan.value(QStringLiteral("source_pages"))},{QStringLiteral("generation"),m_generation},{QStringLiteral("note_source"),noteSource}});
    const auto limit=m_data.value(QStringLiteral("ai_history_limit")).toUInt();
    // Bound question/answer/reasoning text to eight MiB of UTF-16. The Rust
    // planner owns the smaller request-history character budget and truncation.
    const auto fits=[&] {
        qsizetype remaining=4*1024*1024;
        for(const auto &value:turns)for(const auto *field:{"question","answer","reasoning"}) {
            const auto length=value.toMap().value(QLatin1String(field)).toString().size();
            if(length>remaining)return false;remaining-=length;
        }
        return true;
    };
    while(!turns.isEmpty() && (quint64(turns.size())>limit || !fits())){turns.removeFirst();m_aiState.insert(QStringLiteral("conversationLimited"),true);}
    m_aiState.insert(QStringLiteral("chatTurns"),turns);
}
bool ReaderController::setRegionNoteDraft(const QString &id,const QString &text) {
    if(!m_document || id.isEmpty() || (!m_regionNoteDraft.isEmpty() && m_regionNoteDraft.value(QStringLiteral("id")).toString()!=id))return false;
    const QVariantMap next{{QStringLiteral("id"),id},{QStringLiteral("text"),text}};
    if(next!=m_regionNoteDraft){m_regionNoteDraft=next;emit regionNoteDraftChanged();}return true;
}
void ReaderController::discardRegionNoteDraft(){if(!m_regionNoteDraft.isEmpty()){m_regionNoteDraft.clear();emit regionNoteDraftChanged();}}
quint64 ReaderController::saveRegionNoteDraft() {
    if(!m_document || m_pendingCommands || m_regionNoteDraft.isEmpty())return 0;
    m_regionNoteSaveSnapshot=m_regionNoteDraft;m_regionNoteSaveId=submit(QStringLiteral("region_note"),m_regionNoteSaveSnapshot);return m_regionNoteSaveId;
}
bool ReaderController::setReadingNoteDraft(const QVariantMap &draft) {
    const auto id=draft.value(QStringLiteral("id")).toString();
    if(!m_document || m_snapshotMode || m_loading || m_revisionCommands || id.isEmpty()
       || (!m_readingNoteDraft.isEmpty() && m_readingNoteDraft.value(QStringLiteral("id")).toString()!=id))return false;
    if(m_readingNoteDraft!=draft) {
        m_readingNoteDraft=draft;
        emit regionNoteDraftChanged();
    }
    return true;
}
void ReaderController::discardReadingNoteDraft() {
    if(m_readingNoteSaveId || m_readingNoteDraft.isEmpty())return;
    m_readingNoteDraft.clear();
    emit regionNoteDraftChanged();
}
quint64 ReaderController::saveReadingNoteDraft() {
    if(!m_document || m_snapshotMode || m_loading || m_revisionCommands || m_readingNoteSaveId || m_readingNoteDraft.isEmpty())return 0;
    m_readingNoteSaveSnapshot=m_readingNoteDraft;
    m_readingNoteSaveId=m_commandSequence+1;
    QPointer<ReaderController> alive(this);
    const auto id=submit(QStringLiteral("ai_reading_note_update"),{{QStringLiteral("draft"),m_readingNoteSaveSnapshot}});
    if(alive)emit regionNoteDraftChanged();
    return id;
}
void ReaderController::handleAiCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error) {
    if(operation==QStringLiteral("region_save_generated_note") && id==m_generatedRegionNoteSaveId) {
        m_generatedRegionNoteSaveId=0;
        m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("region_note"));
        m_aiState.insert(QStringLiteral("status"),error.isEmpty()?tr("Knowledge note saved."):error);
        if(error.isEmpty()) {
            m_regionHistory=result.toMap();m_aiState.remove(QStringLiteral("regionNoteCandidate"));
            QPointer<ReaderController> alive(this);
            const auto generation=m_generation;
            emit regionHistoryChanged();if(!alive || generation!=m_generation)return;
            if(m_regionHistory.value(QStringLiteral("saved_id"))==m_aiRegion.value(QStringLiteral("history_id"))) {
                m_aiRegion.insert(QStringLiteral("knowledge_note"),m_regionHistory.value(QStringLiteral("saved_note")));
                emit aiRegionChanged();if(!alive || generation!=m_generation)return;
            }
        }
        emit aiStateChanged();return;
    }
    if(operation==QStringLiteral("ai_reading_note_update") && id==m_readingNoteSaveId) {
        m_readingNoteSaveId=0;
        if(error.isEmpty()) {
            if(m_readingNoteDraft==m_readingNoteSaveSnapshot)m_readingNoteDraft.clear();
            else m_readingNoteDraft.insert(QStringLiteral("expected_modified"),result.toMap().value(QStringLiteral("modified")));
        }
        m_readingNoteSaveSnapshot.clear();
        emit regionNoteDraftChanged();
        return;
    }
    if(operation.startsWith(QStringLiteral("knowledge_"))){handleDocumentReadingCommand(id,operation,result,error);return;}
    if(operation==QStringLiteral("region_reopen")) {
        if(id!=m_aiRegionRestoreId)return;m_aiRegionRestoreId=0;
        if(!error.isEmpty() || m_aiRegionRestoreEpoch!=m_aiRegionEpoch)return;
        auto capture=result.toMap();
        // Reopening the same active card must not replace newer local typing with its cache.
        if(m_aiRegion.value(QStringLiteral("history_id"))==capture.value(QStringLiteral("history_id")) && m_aiRegion.contains(QStringLiteral("image_png")))return;
        const auto latest=capture.take(QStringLiteral("latest_turn")).toMap();const auto image=capture.take(QStringLiteral("image_url")).toUrl();resetAiRegion();
        capture.insert(QStringLiteral("restored"),true);m_aiRegion=capture;
        m_aiRegionImage=image;
        if(!latest.isEmpty()) {
            auto response=latest;response.insert(QStringLiteral("restored"),true);response.insert(QStringLiteral("generation"),m_generation);
            response.insert(QStringLiteral("responsePlan"),QVariantMap{{QStringLiteral("action"),QStringLiteral("RegionQuestion")},{QStringLiteral("source_pages"),latest.value(QStringLiteral("source_pages"))}});
            auto results=m_aiState.value(QStringLiteral("results")).toMap();results.insert(QStringLiteral("region"),response);m_aiState.insert(QStringLiteral("results"),results);
        }
        m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("region"));m_aiState.insert(QStringLiteral("status"),tr("Saved conversation reopened. Preview a question to continue."));
        emit aiRegionImageChanged();emit aiRegionChanged();emit aiStateChanged();return;
    }
    // Exports report their own outcome; they do not replace the loaded history or drafts.
    if(operation==QStringLiteral("region_export_markdown") || operation==QStringLiteral("region_thumbnail"))return;
    if(operation.startsWith(QStringLiteral("region_")) && operation!=QStringLiteral("region_get")) {
        if(error.isEmpty())m_regionHistory=result.toMap();else m_regionHistory.insert(QStringLiteral("error"),error);
        emit regionHistoryChanged();
        if(id==m_regionNoteSaveId) {
            m_regionNoteSaveId=0;
            if(error.isEmpty() && m_regionNoteDraft==m_regionNoteSaveSnapshot)discardRegionNoteDraft();
        }
        if(id==m_aiRegionSaveId)finishAiRegionSave(result.toMap(),error);
        return;
    }
    if(operation==QStringLiteral("ai_chat_draft") && id==m_chatDraftSaveId) {
        finishChatDraftSave(result.toMap(),error);return;
    }
    if(operation==QStringLiteral("ai_chat_session") && id==m_aiChatLoadId) {
        m_aiChatLoadId=0;
        if(m_aiChatLoadEpoch!=m_aiPreviewEpoch)return;
        m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("chat"));
        if(!error.isEmpty()) {
            m_aiState.insert(QStringLiteral("status"),error);emit aiStateChanged();return;
        }
        resetAiChat();
        const auto session=result.toMap();
        QVariantList turns;
        for(const auto &entry:session.value(QStringLiteral("turns")).toList()) {
            auto turn=entry.toMap();turn.insert(QStringLiteral("generation"),m_generation);turns.append(turn);
        }
        const bool readOnly=session.value(QStringLiteral("read_only")).toBool();
        m_aiState.insert(QStringLiteral("chatTurns"),turns);
        m_aiState.insert(QStringLiteral("conversationLimited"),session.value(QStringLiteral("limited")));
        m_aiState.insert(QStringLiteral("chatSession"),session.value(QStringLiteral("id")));
        m_aiState.insert(QStringLiteral("chatModified"),session.value(QStringLiteral("modified")));
        m_aiState.insert(QStringLiteral("chatReadOnly"),readOnly);
        m_savedChatDraft=session.value(QStringLiteral("draft")).toString();
        setChatDraft(m_savedChatDraft);
        m_aiState.insert(QStringLiteral("status"),readOnly?tr("Earlier PDF revision. Start a new chat for the current document."):tr("Conversation reopened."));
        emit aiStateChanged();return;
    }
    if((operation==QStringLiteral("ai_preview") || operation==QStringLiteral("ai_summary_prepare")) && id==m_aiPreviewId) {
        m_aiPreviewId=0;auto failure=error;
        if(failure.isEmpty() && operation==QStringLiteral("ai_summary_prepare")) {
            const auto preview=result.toMap();
            if(m_aiSummaryPreviewUnitId.isEmpty() || preview.value(QStringLiteral("id")).toString()!=m_aiSummaryPreviewUnitId
                || m_summaryUnitContext.value(QStringLiteral("id")).toString()!=m_aiSummaryPreviewUnitId || preview.value(QStringLiteral("plan")).toMap().isEmpty())
                failure=tr("This summary preview no longer matches the selected unit. Preview it again.");
            else {
                m_aiState.insert(QStringLiteral("plan"),preview.value(QStringLiteral("plan")));
                for(const auto *key:{"title","page_span","note"})m_summaryUnitContext.insert(QLatin1String(key),preview.value(QLatin1String(key)));
                QPointer<ReaderController> alive(this);const auto epoch=m_aiPreviewEpoch;
                emit summaryCatalogChanged();if(!alive || epoch!=m_aiPreviewEpoch)return;
            }
        }else if(failure.isEmpty()) {
            const auto plan=result.toMap();
            const auto cached=plan.value(QStringLiteral("saved_summary")).toMap();
            if(!cached.isEmpty()) {
                for(const auto *key:{"plan","reasoning","usage","unitTitle","unitLanguage","synthesisParts"})
                    m_aiState.remove(QLatin1String(key));
                m_aiState.insert(QStringLiteral("cachedWholeSummary"),true);
                m_aiState.insert(QStringLiteral("summaryNoteSource"),cached.value(QStringLiteral("id")));
                m_aiState.insert(QStringLiteral("responseView"),QStringLiteral("summary"));
                m_aiState.insert(QStringLiteral("output"),cached.value(QStringLiteral("output")));
                m_aiState.insert(QStringLiteral("responsePlan"),QVariantMap{
                    {QStringLiteral("action"),QStringLiteral("SummarizeDocument")},
                    {QStringLiteral("source_pages"),cached.value(QStringLiteral("source_pages"))}});
                m_aiState.insert(QStringLiteral("status"),tr("Opened a matching saved summary locally."));
                retainAiResult(QStringLiteral("finished"));emit aiStateChanged();return;
            }
            m_aiState.insert(QStringLiteral("plan"),result);
            if(plan.contains(QStringLiteral("cache_warning")))m_aiState.insert(QStringLiteral("cacheWarning"),plan.value(QStringLiteral("cache_warning")));
            if(plan.value(QStringLiteral("kind"))==QStringLiteral("reading_translation"))
                m_aiState.insert(QStringLiteral("previewSelection"),plan.value(QStringLiteral("reading_scope")).toMap().value(QStringLiteral("selection")));
        }
        m_aiState.insert(QStringLiteral("status"),failure.isEmpty()?tr("Request ready. Nothing sent yet."):failure);emit aiStateChanged();return;
    }
    if(operation==QStringLiteral("ai_start") && id==m_aiStartId) {
        m_aiStartId=0;
        if(error.isEmpty()){m_aiState.insert(QStringLiteral("status"),tr("Receiving response…"));m_aiTimer.start();}
        else {m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("status"),error);finishAiChat(QStringLiteral("failed"));retainAiResult(QStringLiteral("failed"));if(m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("region"))markRegionDirty();}
        emit aiStateChanged();return;
    }
    if(operation!=QStringLiteral("ai_poll") || id!=m_aiPollId)return;
    m_aiPollId=0;
    if(!error.isEmpty()) {
        m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("status"),error);finishAiChat(QStringLiteral("failed"));retainAiResult(QStringLiteral("failed"));m_aiTimer.stop();if(m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("region"))markRegionDirty();emit aiStateChanged();return;
    }
    const auto batch=result.toMap();
    auto understanding=batch.value(QStringLiteral("understanding")).toMap();
    const bool updatedUnderstanding=!understanding.isEmpty();
    if(batch.contains(QStringLiteral("summary_note_source")))
        m_aiState.insert(QStringLiteral("summaryNoteSource"),batch.value(QStringLiteral("summary_note_source")));
    if(updatedUnderstanding) {
        if(understanding.value(QStringLiteral("phase"))!=QStringLiteral("ready"))
            understanding.insert(QStringLiteral("plan"),m_documentReading.value(QStringLiteral("plan")));
        m_documentReading=understanding;
        m_readingChoiceShown=true;m_readingChoicePending=false;
    }
    const auto chatCheckpoint=batch.value(QStringLiteral("chat_checkpoint")).toMap();
    if(!chatCheckpoint.isEmpty()) {
        m_aiState.insert(QStringLiteral("chatModified"),chatCheckpoint.value(QStringLiteral("modified")));
        m_savedChatDraft=m_aiState.value(QStringLiteral("activeChatDraft")).toString();
        m_aiState.remove(QStringLiteral("chatDraftWarning"));
    }
    if(batch.contains(QStringLiteral("chat_history_warning")))m_aiState.insert(QStringLiteral("chatHistoryWarning"),batch.value(QStringLiteral("chat_history_warning")));
    const auto responseKind=m_aiState.value(QStringLiteral("responsePlan")).toMap().value(QStringLiteral("kind")).toString();
    const bool readingTranslation=responseKind==QStringLiteral("reading_translation");
    if(!batch.value(QStringLiteral("cache_warning")).toString().isEmpty())m_aiState.insert(QStringLiteral("cacheWarning"),batch.value(QStringLiteral("cache_warning")));
    const auto priorOutput=m_aiState.value(QStringLiteral("output")).toString();
    auto output=m_aiState.value(QStringLiteral("output")).toString(),reasoning=m_aiState.value(QStringLiteral("reasoning")).toString();
    for(const auto &value:batch.value(QStringLiteral("events")).toList()) {
        const auto event=value.toMap();
        if(value.toString()==QStringLiteral("Done"))m_aiState.insert(QStringLiteral("terminalReceived"),true);
        if(event.contains(QStringLiteral("Delta")))output+=event.value(QStringLiteral("Delta")).toMap().value(QStringLiteral("text")).toString();
        if(event.contains(QStringLiteral("ReasoningDelta")))reasoning+=event.value(QStringLiteral("ReasoningDelta")).toMap().value(QStringLiteral("text")).toString();
        // A unit already has a captured UI title; ordinary multipart responses retain their headings.
        if(event.contains(QStringLiteral("PartStarted"))) {
            if(readingTranslation) {
                if(!output.isEmpty())output+=QStringLiteral("\n\n");
            } else if(m_aiState.value(QStringLiteral("unitTitle")).toString().isEmpty())output+=(output.isEmpty()?QString{}:QStringLiteral("\n\n"))+QStringLiteral("### ")+event.value(QStringLiteral("PartStarted")).toMap().value(QStringLiteral("label")).toString()+QStringLiteral("\n\n");
        }
        if(event.contains(QStringLiteral("Usage")))m_aiState.insert(QStringLiteral("usage"),event.value(QStringLiteral("Usage")));
        if(event.contains(QStringLiteral("Diagnostics")))m_aiState.insert(QStringLiteral("diagnostics"),event.value(QStringLiteral("Diagnostics")).toMap().value(QStringLiteral("diagnostics")));
        if(event.contains(QStringLiteral("Error"))) {
            const auto failure=event.value(QStringLiteral("Error")).toMap();
            m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("status"),failure.value(QStringLiteral("message")));
            m_aiState.insert(QStringLiteral("chatOutcome"),failure.value(QStringLiteral("cancelled")).toBool()?QStringLiteral("cancelled"):QStringLiteral("failed"));
        }
    }
    // Eight MiB of UTF-16 response text per tab, separate from the PDF raster LRU.
    constexpr qsizetype maximumCharacters=maximumAiCharacters;
    if(output.size()+reasoning.size()>maximumCharacters) {
        output=output.left(maximumCharacters);reasoning=reasoning.left(qMax<qsizetype>(0,maximumCharacters-output.size()));
        if(!m_aiState.value(QStringLiteral("limited")).toBool()){m_aiState.insert(QStringLiteral("limited"),true);cancelAi();}
    }
    m_aiState.insert(QStringLiteral("output"),output);m_aiState.insert(QStringLiteral("reasoning"),reasoning);
    if(batch.value(QStringLiteral("finished")).toBool()) {
        if(m_aiState.value(QStringLiteral("running")).toBool()) {
            const bool complete=m_aiState.value(QStringLiteral("terminalReceived")).toBool();
            m_aiState.insert(QStringLiteral("chatOutcome"),complete?QStringLiteral("finished"):QStringLiteral("failed"));
            m_aiState.insert(QStringLiteral("status"),complete?tr("Response complete."):tr("The response ended without a completion event."));
        }
        m_aiState.insert(QStringLiteral("running"),false);
        if(responseKind==QStringLiteral("reading_note_suggestion") || responseKind==QStringLiteral("region_knowledge_note")) {
            const auto synthesis=batch.value(QStringLiteral("note_synthesis_plan")).toMap();
            if(!synthesis.isEmpty() && m_aiActivePreviewEpoch==m_aiPreviewEpoch && m_aiPlanGeneration==m_generation
                && !m_aiState.value(QStringLiteral("limited")).toBool() && !m_aiState.value(QStringLiteral("cancelRequested")).toBool()) {
                m_aiState.insert(QStringLiteral("plan"),synthesis);
                m_aiState.insert(QStringLiteral("planSent"),false);
                m_aiState.insert(QStringLiteral("status"),tr("The section notes are ready. Review the synthesis request before sending it."));
            }
            const auto suggested=batch.value(QStringLiteral("note_suggestion")).toMap();
            if(!suggested.isEmpty()) {
                m_aiState.insert(QStringLiteral("noteSuggestion"),suggested);
                m_aiState.insert(QStringLiteral("status"),suggested.value(QStringLiteral("available")).toBool()
                    ? tr("The suggested note is ready to review.") : tr("The discussion did not produce new note text."));
            }
            const auto candidate=batch.value(QStringLiteral("region_note_candidate")).toMap();
            if(!candidate.isEmpty() && candidate.value(QStringLiteral("id"))==m_aiRegion.value(QStringLiteral("history_id"))) {
                m_aiState.insert(QStringLiteral("regionNoteCandidate"),candidate);
                m_aiState.insert(QStringLiteral("status"),tr("Review the generated knowledge note before saving it."));
            }
            const auto warning=batch.value(QStringLiteral("note_warning")).toString();
            if(!warning.isEmpty())m_aiState.insert(QStringLiteral("status"),warning);
        }
        if(readingTranslation && !m_aiState.value(QStringLiteral("limited")).toBool()) {
            m_aiState.insert(QStringLiteral("translationBlocks"),batch.value(QStringLiteral("translation_blocks")));
            m_aiState.insert(QStringLiteral("translationWarning"),batch.value(QStringLiteral("translation_warning")));
            m_aiState.insert(QStringLiteral("translationHistoryWarning"),batch.value(QStringLiteral("translation_history_warning")));
        }
        if(responseKind==QStringLiteral("reading_summary") && m_aiActivePreviewEpoch==m_aiPreviewEpoch
            && m_aiPlanGeneration==m_generation && !m_aiState.value(QStringLiteral("limited")).toBool()
            && !m_aiState.value(QStringLiteral("cancelRequested")).toBool()
            && m_aiState.value(QStringLiteral("chatOutcome"))==QStringLiteral("finished")) {
            const auto synthesis=batch.value(QStringLiteral("synthesis_plan")).toMap();
            const auto warning=batch.value(QStringLiteral("synthesis_warning")).toString();
            if(!synthesis.isEmpty()) {
                m_aiState.insert(QStringLiteral("plan"),synthesis);
                m_aiState.insert(QStringLiteral("planSent"),false);
                m_aiState.insert(QStringLiteral("status"),tr("Part summaries are ready. Review the separate synthesis request before sending."));
            } else if(!warning.isEmpty()) {
                m_aiState.insert(QStringLiteral("status"),tr("%1 Part summaries are kept.").arg(warning));
            }
        }
    }
    if(m_aiState.value(QStringLiteral("limited")).toBool())m_aiState.insert(QStringLiteral("status"),tr("Response exceeded the 8 MiB display budget; request cancelled."));
    if(!m_aiState.value(QStringLiteral("running")).toBool()) {
        const auto outcome=m_aiState.value(QStringLiteral("chatOutcome")).toString();
        const auto savedChatState=chatCheckpoint.value(QStringLiteral("state"),outcome).toString();
        finishAiChat(savedChatState,chatCheckpoint.value(QStringLiteral("note_source")).toString());
        retainAiResult(outcome);m_aiTimer.stop();
    }
    if(m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("region") && (output!=priorOutput || !m_aiState.value(QStringLiteral("running")).toBool()))markRegionDirty();
    QPointer<ReaderController> alive(this);
    const auto generation=m_generation;
    emit aiStateChanged();
    if(alive && generation==m_generation && updatedUnderstanding)emit documentReadingChanged();
}
