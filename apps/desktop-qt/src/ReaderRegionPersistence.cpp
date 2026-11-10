#include "ReaderController.h"

bool ReaderController::regionNeedsSave()const {
    return m_aiRegion.contains(QStringLiteral("image_png")) && !m_aiRegion.value(QStringLiteral("saved")).toBool();
}
bool ReaderController::regionRequestRunning()const {
    return m_aiState.value(QStringLiteral("running")).toBool() && m_aiState.value(QStringLiteral("responseView")).toString()==QStringLiteral("region");
}
bool ReaderController::regionPersistencePending()const {
    return m_aiRegionSaveId || (m_regionSaveError.isEmpty() && (m_regionSaveTimer.isActive() || m_regionFlushRequested));
}
void ReaderController::initRegionPersistence() {
    m_regionSaveTimer.setSingleShot(true);m_regionSaveTimer.setInterval(750);
    connect(&m_regionSaveTimer,&QTimer::timeout,this,[this]{
        if(!m_regionSaveError.isEmpty())return;
        if(regionNeedsSave() && !m_aiRegionSaveId)saveAiRegionNote();
        else if(!m_aiRegionSaveId && !regionRequestRunning()){m_regionFlushRequested=false;finishDeferredRegionAction();}
        emit regionNoteDraftChanged();
    });
}
void ReaderController::resetRegionPersistence() {
    m_regionSaveTimer.stop();m_regionRevision=0;m_regionSnapshotRevision=0;
    m_regionFlushRequested=false;m_regionCancelRequested=false;m_regionClearPending=false;
    m_pendingRegionCapture.clear();m_aiRegionSaveId=0;m_regionSaveError.clear();
}
void ReaderController::scheduleRegionPersistence() {
    if(!regionNeedsSave() || m_aiRegionSaveId || !m_regionSaveError.isEmpty())return;
    // Throttle the latest snapshot, rather than restarting a debounce on every stream delta.
    if(m_regionFlushRequested && !regionRequestRunning())m_regionSaveTimer.start(0);
    else if(!m_regionSaveTimer.isActive())m_regionSaveTimer.start(750);
}
void ReaderController::markRegionDirty(bool localInput) {
    if(!m_aiRegion.contains(QStringLiteral("image_png")))return;
    ++m_regionRevision;m_aiRegion.insert(QStringLiteral("saved"),false);
    if(localInput){m_pendingRegionCapture.clear();m_regionClearPending=false;}
    scheduleRegionPersistence();emit aiRegionChanged();emit regionNoteDraftChanged();
}
QVariantMap ReaderController::regionSnapshotResult()const {
    if(regionRequestRunning())return {{QStringLiteral("turn_id"),m_aiState.value(QStringLiteral("regionTurn"))},
        {QStringLiteral("question"),m_aiState.value(QStringLiteral("activeQuestion"))},
        {QStringLiteral("output"),m_aiState.value(QStringLiteral("output"),QString{})},
        {QStringLiteral("state"),QStringLiteral("empty")}};
    return m_aiState.value(QStringLiteral("results")).toMap().value(QStringLiteral("region")).toMap();
}
quint64 ReaderController::saveAiRegionNote() {
    if(!m_document || m_loading || m_aiRegionSaveId || !m_aiRegion.contains(QStringLiteral("image_png")))return 0;
    m_regionSaveTimer.stop();m_regionSaveError.clear();
    QVariantMap args{{QStringLiteral("id"),m_aiRegion.value(QStringLiteral("history_id"))},{QStringLiteral("draft"),m_aiRegion.value(QStringLiteral("question"),QString{})}};
    const auto result=regionSnapshotResult();
    if(!result.value(QStringLiteral("turn_id")).toString().isEmpty()) {
        QVariantMap turn{{QStringLiteral("id"),result.value(QStringLiteral("turn_id"))},{QStringLiteral("question"),result.value(QStringLiteral("question"))},{QStringLiteral("answer"),result.value(QStringLiteral("output"),QString{})},{QStringLiteral("state"),result.value(QStringLiteral("state"))}};
        if(result.value(QStringLiteral("state")).toString()==QStringLiteral("failed") && (!result.value(QStringLiteral("restored")).toBool() || !result.value(QStringLiteral("status")).isNull()))turn.insert(QStringLiteral("error"),result.value(QStringLiteral("status")));
        args.insert(QStringLiteral("turn"),turn);
    }
    const bool exists=m_aiRegion.value(QStringLiteral("persisted")).toBool();
    if(!exists)args.insert(QStringLiteral("attachment"),m_aiRegion);
    m_regionSnapshotRevision=m_regionRevision;
    m_aiRegionSaveId=submit(exists ? QStringLiteral("region_snapshot"):QStringLiteral("region_create"),args);
    emit regionNoteDraftChanged();return m_aiRegionSaveId;
}
void ReaderController::flushAiRegionNote(bool stopResponse) {
    if(!m_aiRegion.contains(QStringLiteral("image_png")))return;
    if(stopResponse){m_regionContinuationPending=false;m_regionContinuationSettings.clear();}
    m_regionSaveTimer.stop();m_regionFlushRequested=true;
    if(stopResponse && regionRequestRunning()) {
        if(!m_regionCancelRequested){m_regionCancelRequested=true;cancelAi();}
    } else if(!m_aiRegionSaveId) {
        if(!m_regionSaveError.isEmpty())m_regionFlushRequested=false;
        else if(regionNeedsSave())saveAiRegionNote();
        else {m_regionFlushRequested=false;finishDeferredRegionAction();}
    }
    emit regionNoteDraftChanged();
}
QVariantMap ReaderController::regionDiscardContext()const {
    if(!m_document || m_loading || m_aiRegionSaveId || regionRequestRunning() || m_regionSaveError.isEmpty() || !m_aiRegion.contains(QStringLiteral("image_png")))return {};
    return {{QStringLiteral("id"),m_aiRegion.value(QStringLiteral("history_id"))},{QStringLiteral("generation"),m_generation},{QStringLiteral("revision"),m_regionRevision}};
}
bool ReaderController::discardAiRegionChanges(const QVariantMap &expected) {
    if(expected.isEmpty() || expected!=regionDiscardContext())return false;
    // Explicitly reviewed local abandonment never writes/deletes a saved history record.
    resetAiRegion();return true;
}
void ReaderController::clearAiRegion() {
    if(!m_regionSaveError.isEmpty()){setError(m_regionSaveError);return;}
    if(regionNeedsSave() || m_aiRegionSaveId || regionRequestRunning()) {
        m_regionClearPending=true;flushAiRegionNote();return;
    }
    resetAiRegion();
}
void ReaderController::finishDeferredRegionAction() {
    if(regionNeedsSave() || m_aiRegionSaveId || regionRequestRunning() || !m_regionSaveError.isEmpty())return;
    m_regionFlushRequested=false;m_regionCancelRequested=false;
    const auto pending=m_pendingRegionCapture;const bool clear=m_regionClearPending;
    m_pendingRegionCapture.clear();m_regionClearPending=false;
    if(pending.isEmpty() && !clear)return;
    const auto version=m_regionRevision,generation=m_generation;const auto id=m_aiRegion.value(QStringLiteral("history_id"));
    QTimer::singleShot(0,this,[this,pending,clear,version,generation,id]{
        if(version!=m_regionRevision || generation!=m_generation || id!=m_aiRegion.value(QStringLiteral("history_id")))return;
        if(!pending.isEmpty())captureAiRegion(pending.value(QStringLiteral("page")).toInt(),pending.value(QStringLiteral("rect")).toMap(),pending.value(QStringLiteral("zoom")).toDouble());
        else if(clear)resetAiRegion();
    });
}
void ReaderController::finishAiRegionSave(const QVariantMap &result,const QString &error) {
    m_aiRegionSaveId=0;m_regionSaveError=error;
    if(error.isEmpty() && result.value(QStringLiteral("saved_id"))==m_aiRegion.value(QStringLiteral("history_id"))) {
        m_aiRegion.insert(QStringLiteral("persisted"),true);m_aiRegion.insert(QStringLiteral("saved"),m_regionRevision==m_regionSnapshotRevision);
        m_aiRegion.insert(QStringLiteral("completed_turn_count"),result.value(QStringLiteral("saved_completed_turn_count")));
    }
    if(!error.isEmpty()){m_regionSaveTimer.stop();m_regionFlushRequested=false;m_pendingRegionCapture.clear();m_regionClearPending=false;}
    if(m_regionContinuationPending) {
        const auto settings=m_regionContinuationSettings;const bool current=m_regionContinuationEpoch==m_aiRegionEpoch && m_regionContinuationQuestion==m_aiRegion.value(QStringLiteral("question")).toString();
        m_regionContinuationPending=false;m_regionContinuationSettings.clear();
        if(error.isEmpty() && current && m_aiRegion.value(QStringLiteral("saved")).toBool())prepareAiRegion(settings);
        else {m_aiState.insert(QStringLiteral("status"),error.isEmpty()?tr("The question changed. Preview it again before sending."):error);emit aiStateChanged();}
    }
    if(error.isEmpty()) {
        scheduleRegionPersistence();
        if(!regionNeedsSave())finishDeferredRegionAction();
    }
    emit aiRegionChanged();emit regionNoteDraftChanged();
}
