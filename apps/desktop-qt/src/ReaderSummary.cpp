#include "ReaderController.h"
#include <QPointer>

void ReaderController::initSummaryCatalog() {
    connect(this,&ReaderController::commandFinished,this,&ReaderController::handleSummaryCatalogCommand);
}

void ReaderController::resetSummaryCatalog() {
    ++m_summaryActionEpoch;m_summaryCatalogId=0;m_summaryInspectId=0;m_summaryExpectedId.clear();
    m_summaryCatalog.clear();m_summaryUnitContext.clear();emit summaryCatalogChanged();
}

void ReaderController::setSummaryExpanded(bool expanded) {
    if(m_summaryCatalog.value(QStringLiteral("expanded")).toBool()==expanded)return;
    const auto document=m_document;const auto generation=m_generation,epoch=m_summaryActionEpoch;QPointer<ReaderController> alive(this);
    m_summaryCatalog.insert(QStringLiteral("expanded"),expanded);emit summaryCatalogChanged();
    if(!alive || document!=m_document || generation!=m_generation || epoch!=m_summaryActionEpoch || !m_summaryCatalog.value(QStringLiteral("expanded")).toBool())return;
    if(expanded && !m_summaryCatalog.value(QStringLiteral("loaded")).toBool() && !m_summaryCatalogId)
        loadSummaryCatalog(m_summaryCatalog.value(QStringLiteral("layer"),QStringLiteral("Abstract")).toString());
}

void ReaderController::loadSummaryCatalog(const QString &layer,int offset) {
    if(!m_document || m_loading || m_snapshotMode)return;
    if((layer!=QStringLiteral("Abstract") && layer!=QStringLiteral("Section") && layer!=QStringLiteral("Page")) || offset<0) {
        m_summaryCatalog.insert(QStringLiteral("error"),tr("The requested summary layer is unavailable."));
        emit summaryCatalogChanged();return;
    }
    const auto document=m_document;const auto generation=m_generation,epoch=++m_summaryActionEpoch;QPointer<ReaderController> alive(this);
    m_summaryInspectId=0;m_summaryExpectedId.clear();
    m_summaryCatalog={{QStringLiteral("expanded"),true},{QStringLiteral("layer"),layer},
        {QStringLiteral("offset"),offset},{QStringLiteral("generation"),m_generation},
        {QStringLiteral("loading"),true}};
    emit summaryCatalogChanged();
    if(!alive || document!=m_document || generation!=m_generation || epoch!=m_summaryActionEpoch)return;
    m_summaryCatalogId=submit(QStringLiteral("ai_summary_catalog"),{
        {QStringLiteral("request"),QVariantMap{{QStringLiteral("layer"),layer},{QStringLiteral("offset"),offset}}}});
}

void ReaderController::inspectSummaryUnit(const QString &id) {
    if(!m_document || m_loading || m_snapshotMode || m_summaryCatalogId || m_summaryInspectId)return;
    const auto rows=m_summaryCatalog.value(QStringLiteral("rows")).toList();
    for(const auto &value:rows) {
        const auto row=value.toMap();if(row.value(QStringLiteral("id")).toString()!=id)continue;
        const auto unit=row.value(QStringLiteral("unit")).toMap();
        const auto document=m_document;const auto generation=m_generation,epoch=++m_summaryActionEpoch;QPointer<ReaderController> alive(this);
        m_summaryCatalog.remove(QStringLiteral("error"));
        m_summaryExpectedId=id;m_summaryCatalog.insert(QStringLiteral("inspecting"),id);
        emit summaryCatalogChanged();
        if(!alive || document!=m_document || generation!=m_generation || epoch!=m_summaryActionEpoch)return;
        m_summaryInspectId=submit(QStringLiteral("ai_summary_inspect"),{
            {QStringLiteral("request"),QVariantMap{{QStringLiteral("layer"),unit.value(QStringLiteral("kind"))},
                                                  {QStringLiteral("index"),unit.value(QStringLiteral("index"))}}}});
        return;
    }
    m_summaryCatalog.insert(QStringLiteral("error"),tr("This summary row is no longer available. Refresh the layer."));
    emit summaryCatalogChanged();
}

void ReaderController::handleSummaryCatalogCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error) {
    if(operation==QStringLiteral("ai_summary_catalog") && id==m_summaryCatalogId) {
        m_summaryCatalogId=0;
        const bool expanded=m_summaryCatalog.value(QStringLiteral("expanded")).toBool();
        if(error.isEmpty()) {
            m_summaryCatalog=result.toMap();
            m_summaryCatalog.insert(QStringLiteral("loaded"),true);
            m_summaryCatalog.insert(QStringLiteral("generation"),m_generation);
        }else m_summaryCatalog.insert(QStringLiteral("error"),error);
        m_summaryCatalog.insert(QStringLiteral("expanded"),expanded);
        m_summaryCatalog.insert(QStringLiteral("loading"),false);
        emit summaryCatalogChanged();
    }else if(operation==QStringLiteral("ai_summary_inspect") && id==m_summaryInspectId) {
        m_summaryInspectId=0;m_summaryCatalog.remove(QStringLiteral("inspecting"));
        auto coverage=m_summaryCatalog.value(QStringLiteral("coverage")).toMap();
        const auto value=result.toMap();
        if(!error.isEmpty())coverage.insert(m_summaryExpectedId,QVariantMap{{QStringLiteral("error"),error}});
        else if(value.value(QStringLiteral("id")).toString()==m_summaryExpectedId)
            coverage.insert(m_summaryExpectedId,value);
        else coverage.insert(m_summaryExpectedId,QVariantMap{{QStringLiteral("error"),tr("The summary coverage belongs to another row. Check it again.")}});
        m_summaryExpectedId.clear();m_summaryCatalog.insert(QStringLiteral("coverage"),coverage);
        emit summaryCatalogChanged();
    }
}


void ReaderController::clearSummaryUnit() {
    if(m_aiState.value(QStringLiteral("running")).toBool() || m_summaryUnitContext.isEmpty())return;
    m_summaryUnitContext.clear();QPointer<ReaderController> alive(this);invalidateAiPlan();if(alive)emit summaryCatalogChanged();
}

void ReaderController::prepareSummaryUnit(const QString &id,const QVariantMap &settings) {
    if(!m_document || m_loading || m_snapshotMode || m_aiState.value(QStringLiteral("running")).toBool())return;
    QVariantMap row;
    for(const auto &value:m_summaryCatalog.value(QStringLiteral("rows")).toList())
        if(value.toMap().value(QStringLiteral("id")).toString()==id){row=value.toMap();break;}
    if(row.isEmpty() && m_summaryUnitContext.value(QStringLiteral("id")).toString()==id
        && m_summaryUnitContext.value(QStringLiteral("generation")).toULongLong()==m_generation)row=m_summaryUnitContext;
    if(row.isEmpty()) {
        QPointer<ReaderController> alive(this);const auto epoch=m_aiPreviewEpoch+1;const auto generation=m_generation;
        invalidateAiPlan();if(!alive || epoch!=m_aiPreviewEpoch || generation!=m_generation)return;
        m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("summary"));
        m_aiState.insert(QStringLiteral("status"),tr("This summary row is no longer available. Refresh the layer."));emit aiStateChanged();return;
    }
    const auto document=m_document;const auto generation=m_generation;QPointer<ReaderController> alive(this);
    const auto epoch=++m_aiPreviewEpoch;m_aiPreviewId=0;m_aiState.remove(QStringLiteral("plan"));
    row.insert(QStringLiteral("generation"),generation);m_summaryUnitContext=row;
    auto input=m_aiState.value(QStringLiteral("input")).toMap();input.insert(QStringLiteral("view"),QStringLiteral("summary"));
    m_aiState.insert(QStringLiteral("input"),input);emit summaryCatalogChanged();
    if(!alive || document!=m_document || generation!=m_generation || epoch!=m_aiPreviewEpoch)return;
    emit aiStateChanged();
    if(!alive || document!=m_document || generation!=m_generation || epoch!=m_aiPreviewEpoch)return;
    auto request=settings;request.insert(QStringLiteral("action"),QStringLiteral("SummarizeDocument"));
    const auto unit=row.value(QStringLiteral("unit")).toMap();
    prepareAi(request,{{QStringLiteral("layer"),unit.value(QStringLiteral("kind"))},{QStringLiteral("index"),unit.value(QStringLiteral("index"))}});
}
