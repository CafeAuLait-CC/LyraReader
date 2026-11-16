#include "ReaderController.h"
#include <QPointer>

void ReaderController::initSummaryBatch(){
    connect(this,&ReaderController::commandFinished,this,&ReaderController::handleSummaryBatchCommand);
}
void ReaderController::resetSummaryBatch(){
    abandonSummaryBatch();m_summaryBatchState.clear();m_summaryBatchPreparedToken.clear();m_summaryBatchActiveToken.clear();m_summaryBatchActive=false;m_summaryBatchCancelId=0;
}

bool ReaderController::prepareSummaryBatch(const QString &layer,int offset,const QVariantMap &settings,qulonglong expectedGeneration,int index){
    if(!m_document || m_loading || m_snapshotMode || expectedGeneration!=m_generation || m_aiState.value(QStringLiteral("running")).toBool() || offset<0 || index< -1)return false;
    if(!m_summaryBatchPreparedToken.isEmpty())lyra_reader_desktop_cancel_summary_batch(m_document.get());
    m_summaryBatchPreparedToken.clear();m_regionContinuationPending=false;m_regionContinuationSettings.clear();
    const auto document=m_document;const auto generation=m_generation,epoch=++m_aiPreviewEpoch;QPointer<ReaderController> alive(this);
    const auto current=[&]{return alive && document==m_document && generation==m_generation && epoch==m_aiPreviewEpoch;};
    m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));m_summaryUnitContext.clear();
    m_summaryBatchState.insert(QStringLiteral("generation"),generation);m_summaryBatchState.insert(QStringLiteral("layer"),layer);m_summaryBatchState.insert(QStringLiteral("offset"),offset);m_summaryBatchState.insert(QStringLiteral("phase"),QStringLiteral("preparing"));
    auto input=m_aiState.value(QStringLiteral("input")).toMap();input.insert(QStringLiteral("view"),QStringLiteral("summary"));input.insert(QStringLiteral("summaryBatch"),true);m_aiState.insert(QStringLiteral("input"),input);
    m_aiState.insert(QStringLiteral("previewView"),QStringLiteral("summary"));m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("summary"));m_aiState.insert(QStringLiteral("planSent"),false);m_aiState.insert(QStringLiteral("status"),tr("Preparing the summary batch locally…"));m_aiPlanGeneration=generation;
    emit summaryCatalogChanged();if(!current())return false;emit aiStateChanged();if(!current())return false;
    auto request=settings;request.insert(QStringLiteral("action"),QStringLiteral("SummarizeDocument"));request.insert(QStringLiteral("language"),input.value(QStringLiteral("summaryLanguage")));
    QVariantMap batch{{QStringLiteral("layer"),layer},{QStringLiteral("offset"),offset}};if(index>=0)batch.insert(QStringLiteral("index"),index);
    const auto id=submit(QStringLiteral("ai_summary_batch_prepare"),{{QStringLiteral("batch"),batch},{QStringLiteral("request"),request}});
    if(!current())return false;m_aiPreviewId=id;return true;
}

void ReaderController::clearSummaryBatchView(){
    if(m_aiState.value(QStringLiteral("running")).toBool())return;
    if(m_document)lyra_reader_desktop_cancel_summary_batch(m_document.get());
    m_summaryBatchPreparedToken.clear();++m_aiPreviewEpoch;m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));
    auto input=m_aiState.value(QStringLiteral("input")).toMap();input.remove(QStringLiteral("summaryBatch"));m_aiState.insert(QStringLiteral("input"),input);emit aiStateChanged();
}

bool ReaderController::startSummaryBatch(const QString &key,const QVariantMap &plan){
    const auto token=plan.value(QStringLiteral("token")).toString();
    if(token.isEmpty() || token!=m_summaryBatchPreparedToken || m_summaryBatchState.value(QStringLiteral("generation")).toULongLong()!=m_generation)return false;
    const auto document=m_document;const auto generation=m_generation,epoch=m_aiPreviewEpoch;QPointer<ReaderController> alive(this);
    m_summaryBatchActiveToken=token;m_summaryBatchActive=true;m_summaryBatchCancelId=0;
    m_aiState.insert(QStringLiteral("running"),true);m_aiState.insert(QStringLiteral("planSent"),true);m_aiState.insert(QStringLiteral("responseView"),QStringLiteral("summary_batch"));m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("summary"));m_aiState.insert(QStringLiteral("status"),tr("Starting the summary batch…"));
    m_aiState.insert(QStringLiteral("activeModel"),plan.value(QStringLiteral("model")));m_aiState.insert(QStringLiteral("activeHost"),plan.value(QStringLiteral("host")));
    emit aiStateChanged();
    if(!alive || document!=m_document || generation!=m_generation || epoch!=m_aiPreviewEpoch || !m_summaryBatchActive || !m_aiState.value(QStringLiteral("running")).toBool())return false;
    const auto id=submit(QStringLiteral("ai_summary_batch_start"),{{QStringLiteral("token"),token},{QStringLiteral("api_key"),key}});
    if(!alive || document!=m_document || generation!=m_generation || epoch!=m_aiPreviewEpoch)return false;m_aiStartId=id;return true;
}

void ReaderController::cancelSummaryBatch(){
    if(!m_summaryBatchActive || !m_document)return;
    lyra_reader_desktop_cancel_summary_batch(m_document.get());
    const auto document=m_document;const auto generation=m_generation;const auto token=m_summaryBatchActiveToken;QPointer<ReaderController> alive(this);
    if(!m_summaryBatchState.value(QStringLiteral("limited")).toBool())m_aiState.insert(QStringLiteral("status"),tr("Stopping the summary batch…"));
    emit aiStateChanged();if(!alive || document!=m_document || generation!=m_generation || token!=m_summaryBatchActiveToken)return;
    const auto id=submit(QStringLiteral("ai_summary_batch_cancel"),{{QStringLiteral("token"),token}});
    if(alive && document==m_document && generation==m_generation && token==m_summaryBatchActiveToken)m_summaryBatchCancelId=id;
}

bool ReaderController::applySummaryBatchFrame(const QVariantMap &frame,bool fresh){
    if(frame.value(QStringLiteral("token")).toString()!=m_summaryBatchActiveToken)return false;
    const auto old=m_summaryBatchState.value(QStringLiteral("rows")).toMap();QVariantMap rows;QStringList ids;
    for(const auto &value:frame.value(QStringLiteral("rows")).toList()){
        auto row=value.toMap();const auto id=row.value(QStringLiteral("id")).toString();if(id.isEmpty())continue;
        auto result=old.value(id).toMap().value(QStringLiteral("result")).toMap();
        if(fresh && row.value(QStringLiteral("requested")).toBool())result={{QStringLiteral("output"),QString{}},{QStringLiteral("reasoning"),QString{}}};
        result.insert(QStringLiteral("unitTitle"),row.value(QStringLiteral("title")));result.insert(QStringLiteral("unitLanguage"),row.value(QStringLiteral("unit_language")));result.insert(QStringLiteral("generation"),m_generation);
        auto proof=row.value(QStringLiteral("response_plan")).toMap();proof.insert(QStringLiteral("generation"),m_generation);result.insert(QStringLiteral("responsePlan"),proof);
        row.insert(QStringLiteral("generation"),m_generation);row.insert(QStringLiteral("result"),result);rows.insert(id,row);ids.append(id);
    }
    qsizetype characters=0;
    for(const auto &value:rows){const auto result=value.toMap().value(QStringLiteral("result")).toMap();characters+=result.value(QStringLiteral("output")).toString().size()+result.value(QStringLiteral("reasoning")).toString().size();}
    bool limited=false;
    for(const auto &delivery:frame.value(QStringLiteral("deliveries")).toList()){
        const auto update=delivery.toMap();const auto id=update.value(QStringLiteral("id")).toString();if(!rows.contains(id))continue;
        auto row=rows.value(id).toMap(),result=row.value(QStringLiteral("result")).toMap();
        for(const auto &value:update.value(QStringLiteral("events")).toList()){
            const auto event=value.toMap();
            for(const auto &pair:{qMakePair(QStringLiteral("Delta"),QStringLiteral("output")),qMakePair(QStringLiteral("ReasoningDelta"),QStringLiteral("reasoning"))}){
                if(!event.contains(pair.first))continue;const auto delta=event.value(pair.first).toMap().value(QStringLiteral("text")).toString();
                const auto remaining=maximumAiCharacters-characters;
                if(remaining<0){limited=true;continue;}
                const auto kept=delta.left(remaining);result.insert(pair.second,result.value(pair.second).toString()+kept);characters+=kept.size();if(kept.size()!=delta.size())limited=true;
            }
            if(event.contains(QStringLiteral("Usage")))result.insert(QStringLiteral("usage"),event.value(QStringLiteral("Usage")));
            if(event.contains(QStringLiteral("Diagnostics")))result.insert(QStringLiteral("diagnostics"),event.value(QStringLiteral("Diagnostics")));
            if(event.contains(QStringLiteral("Error")))result.insert(QStringLiteral("failure"),event.value(QStringLiteral("Error")));
        }
        row.insert(QStringLiteral("result"),result);rows.insert(id,row);
    }
    if(fresh)m_summaryBatchState.insert(QStringLiteral("limited"),false);
    if(limited)m_summaryBatchState.insert(QStringLiteral("limited"),true);
    m_summaryBatchState.insert(QStringLiteral("rows"),rows);m_summaryBatchState.insert(QStringLiteral("ids"),ids);
    if(fresh)m_summaryBatchState.insert(QStringLiteral("committedIds"),ids);
    for(const auto *key:{"phase","total","finished","active","ready","failed","cancelled","rejected"})m_summaryBatchState.insert(QLatin1String(key),frame.value(QLatin1String(key)));
    const bool running=frame.value(QStringLiteral("running")).toBool();m_summaryBatchActive=running;m_aiState.insert(QStringLiteral("running"),running);
    QString status;
    if(m_summaryBatchState.value(QStringLiteral("limited")).toBool())status=tr("Batch results reached the 8 MiB display budget. Copy them before starting another batch.");
    else if(running)status=tr("%1 of %2 requests finished · %3 in flight").arg(frame.value(QStringLiteral("finished")).toInt()).arg(frame.value(QStringLiteral("total")).toInt()).arg(frame.value(QStringLiteral("active")).toInt());
    else status=tr("%1 complete · %2 failed · %3 cancelled · %4 without a request").arg(frame.value(QStringLiteral("ready")).toInt()).arg(frame.value(QStringLiteral("failed")).toInt()).arg(frame.value(QStringLiteral("cancelled")).toInt()).arg(frame.value(QStringLiteral("rejected")).toInt());
    m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("summary"));m_aiState.insert(QStringLiteral("status"),status);
    if(!running)m_aiTimer.stop();return limited && running;
}

void ReaderController::handleSummaryBatchCommand(quint64 id,const QString &operation,const QVariant &value,const QString &error){
    if(operation==QStringLiteral("ai_summary_batch_prepare") && id==m_aiPreviewId){
        m_aiPreviewId=0;const auto result=value.toMap();const auto plan=result.value(QStringLiteral("plan")).toMap();
        m_summaryBatchPreparedToken=plan.value(QStringLiteral("token")).toString();
        if(error.isEmpty() && !plan.isEmpty())m_aiState.insert(QStringLiteral("plan"),plan);
        m_summaryBatchState.insert(QStringLiteral("phase"),error.isEmpty()?QStringLiteral("preview"):QStringLiteral("failed"));
        for(const auto *key:{"limits","note","append"})m_summaryBatchState.insert(QLatin1String(key),result.value(QLatin1String(key)));
        if(error.isEmpty()){
            const auto old=m_summaryBatchState.value(QStringLiteral("rows")).toMap();QVariantMap rows;QStringList ids;
            for(const auto &id:m_summaryBatchState.value(QStringLiteral("committedIds")).toStringList())if(old.contains(id)){rows.insert(id,old.value(id));ids.append(id);}
            for(const auto &value:result.value(QStringLiteral("rows")).toList()){
                auto row=value.toMap();const auto unitId=row.value(QStringLiteral("id")).toString();if(unitId.isEmpty())continue;
                const auto prior=old.value(unitId).toMap().value(QStringLiteral("result")).toMap();row.insert(QStringLiteral("result"),prior);row.insert(QStringLiteral("generation"),m_generation);
                rows.insert(unitId,row);if(!ids.contains(unitId))ids.append(unitId);
            }
            m_summaryBatchState.insert(QStringLiteral("rows"),rows);m_summaryBatchState.insert(QStringLiteral("ids"),ids);m_summaryBatchState.insert(QStringLiteral("totalRows"),result.value(QStringLiteral("total")));
        }
        m_aiState.insert(QStringLiteral("status"),!error.isEmpty()?error:plan.isEmpty()?tr("There are no new requests in this batch. Choose another page or preview a row again."):tr("Request previews are ready. Nothing sent yet."));emit aiStateChanged();return;
    }
    const bool start=operation==QStringLiteral("ai_summary_batch_start") && id==m_aiStartId;
    const bool poll=operation==QStringLiteral("ai_summary_batch_poll") && id==m_aiPollId;
    const bool cancel=operation==QStringLiteral("ai_summary_batch_cancel") && id==m_summaryBatchCancelId;
    if(!start && !poll && !cancel)return;
    if(start)m_aiStartId=0;if(poll)m_aiPollId=0;if(cancel)m_summaryBatchCancelId=0;
    bool limited=false;
    if(!error.isEmpty()){
        if(m_document)lyra_reader_desktop_cancel_summary_batch(m_document.get());
        m_aiState.insert(QStringLiteral("running"),false);m_summaryBatchActive=false;m_aiTimer.stop();m_summaryBatchState.insert(QStringLiteral("phase"),QStringLiteral("failed"));m_aiState.insert(QStringLiteral("status"),error);
    }else if(value.toMap().contains(QStringLiteral("token"))){
        if(start)m_summaryBatchPreparedToken.clear();limited=applySummaryBatchFrame(value.toMap(),start);
        if(m_summaryBatchActive)m_aiTimer.start();
    }else if(cancel){m_summaryBatchActive=false;m_aiState.insert(QStringLiteral("running"),false);m_aiTimer.stop();m_summaryBatchState.insert(QStringLiteral("phase"),QStringLiteral("cancelled"));m_aiState.insert(QStringLiteral("status"),tr("Summary batch cancelled before sending."));}
    QPointer<ReaderController> alive(this);const auto generation=m_generation;emit aiStateChanged();
    if(alive && generation==m_generation && limited)cancelSummaryBatch();
}
