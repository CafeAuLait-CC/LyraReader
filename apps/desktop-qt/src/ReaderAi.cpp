#include "ReaderController.h"
#include "NativeRaster.h"
#include "RenderBudget.h"
#include <QFutureWatcher>
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

void ReaderController::initAi() {
    initDocumentReading();
    m_aiTimer.setInterval(60);
    connect(&m_aiTimer,&QTimer::timeout,this,[this]{
        if(!m_aiState.value(QStringLiteral("running")).toBool()){m_aiTimer.stop();return;}
        if(!m_aiPollId)m_aiPollId=submit(QStringLiteral("ai_poll"));
    });
    connect(this,&ReaderController::commandFinished,this,&ReaderController::handleAiCommand);
}
void ReaderController::resetAi() {
    clearAiRegionPaper();
    resetDocumentReading();
    ++m_aiRegionEpoch;RasterJobs::cancel(m_aiRegionJob);m_aiRegionJob.reset();m_aiRegion.clear();emit aiRegionChanged();
    m_aiRegionImage=QUrl{};emit aiRegionImageChanged();
    m_regionHistory.clear();m_aiRegionSaveId=0;emit regionHistoryChanged();
    m_aiTimer.stop();m_aiPreviewId=0;m_aiStartId=0;m_aiPollId=0;m_aiState.clear();emit aiStateChanged();
}
void ReaderController::cancelAiRegionCapture() {
    clearAiRegionPaper();
    ++m_aiRegionEpoch;RasterJobs::cancel(m_aiRegionJob);m_aiRegionJob.reset();
    if(m_aiRegion.value(QStringLiteral("loading")).toBool()){m_aiRegion.clear();emit aiRegionChanged();}
}
void ReaderController::clearAiRegion() {
    m_regionSaveError.clear();emit regionNoteDraftChanged();
    cancelAiRegionCapture();m_aiRegion.clear();
    m_aiRegionImage=QUrl{};emit aiRegionImageChanged();
    if(m_aiState.value(QStringLiteral("running")).toBool() && m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("region"))cancelAi();
    if(m_aiState.value(QStringLiteral("previewView")).toString()==QStringLiteral("region"))invalidateAiPlan();
    auto results=m_aiState.value(QStringLiteral("results")).toMap();results.remove(QStringLiteral("region"));m_aiState.insert(QStringLiteral("results"),results);
    if(!m_aiState.value(QStringLiteral("running")).toBool() && m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("region")) {
        for(const auto *key:{"output","reasoning","responsePlan","responseView","usage"})m_aiState.remove(QLatin1String(key));
    }
    if(!m_aiState.value(QStringLiteral("running")).toBool() && m_aiState.value(QStringLiteral("statusView")).toString()==QStringLiteral("region")) {
        m_aiState.remove(QStringLiteral("statusView"));m_aiState.remove(QStringLiteral("status"));
    }
    emit aiStateChanged();
    emit aiRegionChanged();
}
bool ReaderController::captureAiRegion(int page,const QVariantMap &rect,double zoom) {
    if(!m_document || !m_source || m_loading || m_pendingCommands || m_aiState.value(QStringLiteral("running")).toBool())return false;
    clearAiRegion();
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
    m_aiRegion.insert(QStringLiteral("question"),text);m_aiRegion.insert(QStringLiteral("saved"),false);
    if(m_aiState.value(QStringLiteral("previewView")).toString()==QStringLiteral("region"))invalidateAiPlan();
    emit aiRegionChanged();
}
void ReaderController::prepareAiRegion(const QVariantMap &settings) {
    if(!m_aiRegion.contains(QStringLiteral("image_png")) || m_aiRegion.value(QStringLiteral("loading")).toBool())return;
    QVariantMap region;
    for(const auto *key:{"page","x_pt","y_pt","width_pt","height_pt","text","image_png","image_width_px","image_height_px"})region.insert(QLatin1String(key),m_aiRegion.value(QLatin1String(key)));
    region.insert(QStringLiteral("send_image"),settings.value(QStringLiteral("imageInput"),false));
    region.insert(QStringLiteral("include_document_context"),false);
    prepareAi({{QStringLiteral("action"),QStringLiteral("RegionQuestion")},{QStringLiteral("current_page"),region.value(QStringLiteral("page"))},
        {QStringLiteral("selection"),QVariant{}},{QStringLiteral("question"),m_aiRegion.value(QStringLiteral("question"))},
        {QStringLiteral("language"),QVariant{}},{QStringLiteral("history"),QVariantList{}},{QStringLiteral("region"),region},
        {QStringLiteral("document_knowledge"),false},{QStringLiteral("document_knowledge_text"),QVariant{}},{QStringLiteral("document_knowledge_pages"),QVariantList{}},
        {QStringLiteral("base_url"),settings.value(QStringLiteral("baseUrl"),QStringLiteral("http://localhost:11434/v1"))},{QStringLiteral("model"),settings.value(QStringLiteral("model"),QString{})},
        {QStringLiteral("temperature"),QVariant{}},{QStringLiteral("max_tokens"),QVariant{}},
        {QStringLiteral("reasoning_mode"),settings.value(QStringLiteral("reasoningMode"),QStringLiteral("default"))},{QStringLiteral("reasoning_encoding"),settings.value(QStringLiteral("reasoningEncoding"),QStringLiteral("none"))}});
}
void ReaderController::setAiInput(const QString &key,const QVariant &value) {
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
    if(key!=QStringLiteral("action") && key!=QStringLiteral("question") && key!=QStringLiteral("language"))return;
    if(input.value(key)==value)return;
    if(key==QStringLiteral("action")) {
        bool valid=false;const auto action=value.toInt(&valid);
        if(!valid || action<0 || action>5)return;
        const auto view=action==4?QStringLiteral("chat"):action==3?QStringLiteral("translation"):QStringLiteral("summary");
        input.insert(QStringLiteral("view"),view);
        if(view==QStringLiteral("summary"))input.insert(QStringLiteral("summaryAction"),action);
        input.insert(QStringLiteral("question"),input.value(view==QStringLiteral("chat")?QStringLiteral("chatQuestion"):QStringLiteral("selectionQuestion")));
    }
    if(key==QStringLiteral("question"))input.insert(input.value(QStringLiteral("view")).toString()==QStringLiteral("chat")?QStringLiteral("chatQuestion"):QStringLiteral("selectionQuestion"),value);
    input.insert(key,value);m_aiState.insert(QStringLiteral("input"),input);
    m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));
    if(!m_aiState.value(QStringLiteral("running")).toBool()) {
        m_aiState.insert(QStringLiteral("statusView"),input.value(QStringLiteral("view"),QStringLiteral("summary")));
        m_aiState.insert(QStringLiteral("status"),tr("Preview the updated request before sending."));
    }
    emit aiStateChanged();
}
void ReaderController::invalidateAiPlan() {
    const bool hadPreview=m_aiPreviewId || m_aiState.contains(QStringLiteral("plan"));
    m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));
    if(hadPreview){
        if(!m_aiState.value(QStringLiteral("running")).toBool())m_aiState.insert(QStringLiteral("status"),tr("Preview the updated request before sending."));
        emit aiStateChanged();
    }
}
void ReaderController::clearAiChat() {
    if(m_aiState.value(QStringLiteral("running")).toBool())return;
    m_aiState.remove(QStringLiteral("chatTurns"));m_aiState.remove(QStringLiteral("conversationLimited"));
    auto results=m_aiState.value(QStringLiteral("results")).toMap();results.remove(QStringLiteral("chat"));m_aiState.insert(QStringLiteral("results"),results);
    if(m_aiState.value(QStringLiteral("previewView")).toString()==QStringLiteral("chat")){m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));}
    if(m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("chat")) {
        for(const auto *key:{"output","reasoning","responsePlan","usage","responseView"})m_aiState.remove(QLatin1String(key));
    }
    m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("chat"));m_aiState.insert(QStringLiteral("status"),tr("Conversation cleared locally."));emit aiStateChanged();
}
void ReaderController::prepareAi(const QVariantMap &request) {
    if(!m_document || m_aiState.value(QStringLiteral("running")).toBool())return;
    if(request.value(QStringLiteral("action")).toString()!=QStringLiteral("TranslateSelection") && !m_readingChoiceShown && !m_documentReading.value(QStringLiteral("ready")).toBool()) {
        m_readingChoiceShown=true;m_readingChoicePending=true;emit documentReadingChanged();
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
    m_aiState.insert(QStringLiteral("previewQuestion"),input.value(QStringLiteral("question")));
    m_aiState.insert(QStringLiteral("planSent"),false);
    m_aiState.insert(QStringLiteral("previewView"),aiView(input.value(QStringLiteral("action")).toString()));
    m_aiState.insert(QStringLiteral("statusView"),m_aiState.value(QStringLiteral("previewView")));
    m_aiState.remove(QStringLiteral("plan"));m_aiState.insert(QStringLiteral("status"),tr("Preparing request locally…"));
    m_aiPlanGeneration=m_generation;emit aiStateChanged();
    m_aiPreviewId=submit(QStringLiteral("ai_preview"),{{QStringLiteral("request"),input}});
}
bool ReaderController::startAi(const QString &key,const QVariantMap &expectedPlan) {
    const auto plan=m_aiState.value(QStringLiteral("plan")).toMap();
    if(!m_document || m_pendingCommands>0 || m_loading || plan.isEmpty() || plan!=expectedPlan || m_aiPlanGeneration!=m_generation || m_aiState.value(QStringLiteral("running")).toBool())return false;
    m_aiState.insert(QStringLiteral("responsePlan"),plan);
    m_aiState.insert(QStringLiteral("planSent"),true);
    m_aiState.insert(QStringLiteral("responseView"),aiView(plan.value(QStringLiteral("action")).toString()));
    m_aiState.insert(QStringLiteral("statusView"),m_aiState.value(QStringLiteral("responseView")));
    m_aiState.insert(QStringLiteral("activeChat"),plan.value(QStringLiteral("action")).toString()==QStringLiteral("DocumentChat"));
    m_aiState.insert(QStringLiteral("activeQuestion"),m_aiState.value(QStringLiteral("previewQuestion")));
    m_aiState.insert(QStringLiteral("terminalReceived"),false);
    m_aiState.insert(QStringLiteral("output"),QString{});m_aiState.insert(QStringLiteral("reasoning"),QString{});
    m_aiState.insert(QStringLiteral("usage"),QVariantMap{});m_aiState.insert(QStringLiteral("diagnostics"),QVariantMap{});
    m_aiState.insert(QStringLiteral("limited"),false);m_aiState.insert(QStringLiteral("running"),true);
    m_aiState.insert(QStringLiteral("status"),tr("Starting request…"));
    m_aiState.insert(QStringLiteral("activeHost"),plan.value(QStringLiteral("host")));
    m_aiState.insert(QStringLiteral("activeModel"),plan.value(QStringLiteral("model")));
    emit aiStateChanged();
    QVariantMap args{{QStringLiteral("plan"),plan},{QStringLiteral("api_key"),key}};
    m_aiState.insert(QStringLiteral("chatOutcome"),QStringLiteral("failed"));
    if(plan.value(QStringLiteral("action")).toString()==QStringLiteral("RegionQuestion")) {
        const auto turn=QUuid::createUuid().toString(QUuid::WithoutBraces).toUpper();
        m_aiState.insert(QStringLiteral("regionTurn"),turn);args.insert(QStringLiteral("region_id"),m_aiRegion.value(QStringLiteral("history_id")));args.insert(QStringLiteral("turn_id"),turn);
        m_aiRegion.insert(QStringLiteral("saved"),false);emit aiRegionChanged();
    }
    m_aiStartId=submit(QStringLiteral("ai_start"),args);
    return true;
}
void ReaderController::retainAiResult(const QString &state) {
    const auto view=m_aiState.value(QStringLiteral("responseView")).toString();
    if(view.isEmpty())return;
    QVariantMap result{{QStringLiteral("state"),state},{QStringLiteral("generation"),m_generation}};
    if(view==QStringLiteral("region")){result.insert(QStringLiteral("turn_id"),m_aiState.value(QStringLiteral("regionTurn")));result.insert(QStringLiteral("question"),m_aiState.value(QStringLiteral("activeQuestion")));}
    for(const auto *key:{"output","reasoning","usage","status","responsePlan"})result.insert(QLatin1String(key),m_aiState.value(QLatin1String(key)));
    auto results=m_aiState.value(QStringLiteral("results")).toMap();results.insert(view,result);m_aiState.insert(QStringLiteral("results"),results);
}
void ReaderController::cancelAi() {
    if(!m_aiState.value(QStringLiteral("running")).toBool())return;
    m_aiState.insert(QStringLiteral("status"),tr("Cancelling…"));emit aiStateChanged();submit(QStringLiteral("ai_cancel"));
}
void ReaderController::finishAiChat(const QString &state) {
    if(!m_aiState.value(QStringLiteral("activeChat")).toBool())return;
    m_aiState.insert(QStringLiteral("activeChat"),false);
    auto turns=m_aiState.value(QStringLiteral("chatTurns")).toList();const auto plan=m_aiState.value(QStringLiteral("responsePlan")).toMap();
    turns.append(QVariantMap{{QStringLiteral("question"),m_aiState.value(QStringLiteral("activeQuestion"))},{QStringLiteral("answer"),m_aiState.value(QStringLiteral("output"))},{QStringLiteral("reasoning"),m_aiState.value(QStringLiteral("reasoning"))},{QStringLiteral("state"),state},{QStringLiteral("sources"),plan.value(QStringLiteral("sources"))},{QStringLiteral("source_pages"),plan.value(QStringLiteral("source_pages"))},{QStringLiteral("generation"),m_generation}});
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
quint64 ReaderController::saveAiRegionNote() {
    if(!m_document || m_pendingCommands || m_aiState.value(QStringLiteral("running")).toBool() || !m_aiRegion.contains(QStringLiteral("image_png")))return 0;
    QVariantMap args{{QStringLiteral("id"),m_aiRegion.value(QStringLiteral("history_id"))},{QStringLiteral("draft"),m_aiRegion.value(QStringLiteral("question"),QString{})}};
    const auto result=m_aiState.value(QStringLiteral("results")).toMap().value(QStringLiteral("region")).toMap();
    if(!result.value(QStringLiteral("turn_id")).toString().isEmpty()) {
        QVariantMap turn{{QStringLiteral("id"),result.value(QStringLiteral("turn_id"))},{QStringLiteral("question"),result.value(QStringLiteral("question"))},{QStringLiteral("answer"),result.value(QStringLiteral("output"),QString{})},{QStringLiteral("state"),result.value(QStringLiteral("state"))}};
        if(result.value(QStringLiteral("state")).toString()==QStringLiteral("failed"))turn.insert(QStringLiteral("error"),result.value(QStringLiteral("status")));
        args.insert(QStringLiteral("turn"),turn);
    }
    const bool exists=m_aiRegion.value(QStringLiteral("persisted")).toBool();
    if(!exists)args.insert(QStringLiteral("attachment"),m_aiRegion);
    m_aiRegionSaveDraft=m_aiRegion.value(QStringLiteral("question")).toString();m_aiRegionSaveTurn=result.value(QStringLiteral("turn_id")).toString();
    m_aiRegionSaveId=submit(exists ? QStringLiteral("region_snapshot"):QStringLiteral("region_create"),args);return m_aiRegionSaveId;
}
void ReaderController::handleAiCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error) {
    if(operation.startsWith(QStringLiteral("knowledge_"))){handleDocumentReadingCommand(id,operation,result,error);return;}
    // Exports report their own outcome; they do not replace the loaded history or drafts.
    if(operation==QStringLiteral("region_export_markdown"))return;
    if(operation.startsWith(QStringLiteral("region_")) && operation!=QStringLiteral("region_get")) {
        if(error.isEmpty())m_regionHistory=result.toMap();else m_regionHistory.insert(QStringLiteral("error"),error);
        emit regionHistoryChanged();
        if(id==m_regionNoteSaveId) {
            m_regionNoteSaveId=0;
            if(error.isEmpty() && m_regionNoteDraft==m_regionNoteSaveSnapshot)discardRegionNoteDraft();
        }
        if(id==m_aiRegionSaveId) {
            m_aiRegionSaveId=0;m_regionSaveError=error;emit regionNoteDraftChanged();
            if(error.isEmpty() && result.toMap().value(QStringLiteral("saved_id"))==m_aiRegion.value(QStringLiteral("history_id"))) {
                m_aiRegion.insert(QStringLiteral("persisted"),true);m_aiRegion.insert(QStringLiteral("saved"),m_aiRegion.value(QStringLiteral("question")).toString()==m_aiRegionSaveDraft && m_aiState.value(QStringLiteral("results")).toMap().value(QStringLiteral("region")).toMap().value(QStringLiteral("turn_id")).toString()==m_aiRegionSaveTurn);
            }
            emit aiRegionChanged();
        }
        return;
    }
    if(operation==QStringLiteral("ai_preview") && id==m_aiPreviewId) {
        if(error.isEmpty())m_aiState.insert(QStringLiteral("plan"),result);
        m_aiState.insert(QStringLiteral("status"),error.isEmpty()?tr("Request ready. Nothing sent yet."):error);emit aiStateChanged();return;
    }
    if(operation==QStringLiteral("ai_start") && id==m_aiStartId) {
        m_aiStartId=0;
        if(error.isEmpty()){m_aiState.insert(QStringLiteral("status"),tr("Receiving response…"));m_aiTimer.start();}
        else {m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("status"),error);finishAiChat(QStringLiteral("failed"));retainAiResult(QStringLiteral("failed"));}
        emit aiStateChanged();return;
    }
    if(operation!=QStringLiteral("ai_poll") || id!=m_aiPollId)return;
    m_aiPollId=0;
    if(!error.isEmpty()) {
        m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("status"),error);finishAiChat(QStringLiteral("failed"));retainAiResult(QStringLiteral("failed"));m_aiTimer.stop();emit aiStateChanged();return;
    }
    const auto batch=result.toMap();
    auto output=m_aiState.value(QStringLiteral("output")).toString(),reasoning=m_aiState.value(QStringLiteral("reasoning")).toString();
    for(const auto &value:batch.value(QStringLiteral("events")).toList()) {
        const auto event=value.toMap();
        if(value.toString()==QStringLiteral("Done"))m_aiState.insert(QStringLiteral("terminalReceived"),true);
        if(event.contains(QStringLiteral("Delta")))output+=event.value(QStringLiteral("Delta")).toMap().value(QStringLiteral("text")).toString();
        if(event.contains(QStringLiteral("ReasoningDelta")))reasoning+=event.value(QStringLiteral("ReasoningDelta")).toMap().value(QStringLiteral("text")).toString();
        if(event.contains(QStringLiteral("PartStarted")))output+=(output.isEmpty()?QString{}:QStringLiteral("\n\n"))+QStringLiteral("### ")+event.value(QStringLiteral("PartStarted")).toMap().value(QStringLiteral("label")).toString()+QStringLiteral("\n\n");
        if(event.contains(QStringLiteral("Usage")))m_aiState.insert(QStringLiteral("usage"),event.value(QStringLiteral("Usage")));
        if(event.contains(QStringLiteral("Diagnostics")))m_aiState.insert(QStringLiteral("diagnostics"),event.value(QStringLiteral("Diagnostics")).toMap().value(QStringLiteral("diagnostics")));
        if(event.contains(QStringLiteral("Error"))) {
            const auto failure=event.value(QStringLiteral("Error")).toMap();
            m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("status"),failure.value(QStringLiteral("message")));
            m_aiState.insert(QStringLiteral("chatOutcome"),failure.value(QStringLiteral("cancelled")).toBool()?QStringLiteral("cancelled"):QStringLiteral("failed"));
        }
    }
    // Eight MiB of UTF-16 response text per tab, separate from the PDF raster LRU.
    constexpr qsizetype maximumCharacters=4*1024*1024;
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
    }
    if(m_aiState.value(QStringLiteral("limited")).toBool())m_aiState.insert(QStringLiteral("status"),tr("Response exceeded the 8 MiB display budget; request cancelled."));
    if(!m_aiState.value(QStringLiteral("running")).toBool()){finishAiChat(m_aiState.value(QStringLiteral("chatOutcome")).toString());retainAiResult(m_aiState.value(QStringLiteral("chatOutcome")).toString());m_aiTimer.stop();}
    emit aiStateChanged();
}
