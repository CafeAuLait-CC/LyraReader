#include "ReaderController.h"

void ReaderController::initDocumentReading() {
    m_readingTimer.setInterval(150);
    connect(&m_readingTimer,&QTimer::timeout,this,[this]{
        if(m_documentReading.value(QStringLiteral("phase")).toString()!=QStringLiteral("reading")){m_readingTimer.stop();return;}
        if(!m_readingPollId)m_readingPollId=submit(QStringLiteral("knowledge_poll"));
    });
    connect(this,&ReaderController::openFinished,this,[this](bool success){
        if(success && !m_snapshotMode)m_readingPreviewId=submit(QStringLiteral("knowledge_load"));
    });
}
void ReaderController::resetDocumentReading() {
    const bool pending=m_readingPreviewId || m_readingStartId || m_readingTimer.isActive();
    m_readingTimer.stop();m_readingPreviewId=0;m_readingStartId=0;m_readingPollId=0;m_readingCancelId=0;
    if(pending && m_document && !m_snapshotMode)submit(QStringLiteral("knowledge_cancel"));
    m_readingChoiceShown=false;m_readingChoicePending=false;
    m_documentReading.clear();emit documentReadingChanged();
}
void ReaderController::dismissDocumentReadingChoice() {
    m_readingChoiceShown=true;m_readingChoicePending=false;emit documentReadingChanged();
}
void ReaderController::prepareDocumentReading(const QVariantMap &request) {
    if(!m_document || m_snapshotMode || m_loading || m_pendingCommands || m_documentReading.value(QStringLiteral("phase")).toString()==QStringLiteral("reading"))return;
    m_readingChoiceShown=true;m_readingChoicePending=false;
    m_documentReading={{QStringLiteral("phase"),QStringLiteral("preparing")}};emit documentReadingChanged();
    m_readingPreviewId=submit(QStringLiteral("knowledge_prepare"),{{QStringLiteral("request"),request}});
}
bool ReaderController::startDocumentReading(const QString &key,const QVariantMap &plan,const QString &token) {
    if(!m_document || m_snapshotMode || m_loading || m_pendingCommands || m_documentReading.value(QStringLiteral("phase")).toString()!=QStringLiteral("preview") || m_documentReading.value(QStringLiteral("plan")).toMap()!=plan || m_documentReading.value(QStringLiteral("token")).toString()!=token)return false;
    m_documentReading.insert(QStringLiteral("phase"),QStringLiteral("starting"));emit documentReadingChanged();
    m_readingStartId=submit(QStringLiteral("knowledge_start"),{{QStringLiteral("api_key"),key},{QStringLiteral("plan"),plan},{QStringLiteral("token"),token}});return true;
}
void ReaderController::stopDocumentReading() {
    m_readingChoiceShown=true;m_readingChoicePending=false;
    m_readingTimer.stop();m_readingPreviewId=0;m_readingStartId=0;m_readingPollId=0;
    m_documentReading={{QStringLiteral("phase"),QStringLiteral("stopping")}};emit documentReadingChanged();
    if(m_document && !m_snapshotMode)m_readingCancelId=submit(QStringLiteral("knowledge_cancel"));
}
void ReaderController::invalidateDocumentReadingPreview() {
    const auto phase=m_documentReading.value(QStringLiteral("phase")).toString();
    if(phase==QStringLiteral("preview") || phase==QStringLiteral("preparing"))stopDocumentReading();
}
void ReaderController::handleDocumentReadingCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error) {
    quint64 *expected=nullptr;
    if(operation==QStringLiteral("knowledge_load") || operation==QStringLiteral("knowledge_prepare"))expected=&m_readingPreviewId;
    else if(operation==QStringLiteral("knowledge_start"))expected=&m_readingStartId;
    else if(operation==QStringLiteral("knowledge_poll"))expected=&m_readingPollId;
    else if(operation==QStringLiteral("knowledge_cancel"))expected=&m_readingCancelId;
    if(!expected || !*expected || *expected!=id)return;
    *expected=0;
    if(error.isEmpty()) {
        auto next=result.toMap();
        // Status polls never copy the complete document-text preview across the FFI again.
        if(operation==QStringLiteral("knowledge_poll"))next.insert(QStringLiteral("plan"),m_documentReading.value(QStringLiteral("plan")));
        m_documentReading=next;
    }
    else {m_documentReading.insert(QStringLiteral("phase"),QStringLiteral("failed"));m_documentReading.insert(QStringLiteral("message"),error);}
    if(m_documentReading.value(QStringLiteral("phase")).toString()==QStringLiteral("reading"))m_readingTimer.start();else m_readingTimer.stop();
    if(m_documentReading.value(QStringLiteral("ready")).toBool()){m_readingChoiceShown=true;m_readingChoicePending=false;}
    emit documentReadingChanged();
}
