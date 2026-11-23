#include "ReaderController.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QPointer>
#include <QScopeGuard>
#include <QtConcurrentRun>
#include <algorithm>

void ReaderController::initTranslations() {
    connect(this,&ReaderController::commandFinished,this,&ReaderController::handleTranslationCommand);
}
QVariantList ReaderController::translationOverlays()const {
    QVariantList result;for(const auto &entry:m_translationOverlays)result.append(entry);return result;
}
void ReaderController::abandonTranslations() {
    const auto document=m_document;
    if(!document)return;
    lyra_reader_desktop_cancel_translation(document.get());
    const auto token=m_translationActiveToken.isEmpty()?m_translationPreparedToken:m_translationActiveToken;
    if(token.isEmpty())return;
    const auto bytes=QJsonDocument(QJsonObject{{QStringLiteral("op"),QStringLiteral("translation_cancel")},{QStringLiteral("token"),token}}).toJson(QJsonDocument::Compact);
    (void)QtConcurrent::run([document,bytes]{
        LyraReaderBuffer output{},error{};
        const auto cleanup=qScopeGuard([&]{lyra_reader_desktop_buffer_free(output);lyra_reader_desktop_buffer_free(error);});
        if(!lyra_reader_desktop_command(document.get(),reinterpret_cast<const std::uint8_t *>(bytes.constData()),std::size_t(bytes.size()),&output,&error))
            qWarning()<<"lyra-reader-translation: cleanup cancellation failed:"<<QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));
    });
}
void ReaderController::rememberTranslationView(const QString &operation,const QVariantMap &report) {
    const auto key=m_data.value(QStringLiteral("document_revision")).toString();
    auto modes=m_translationViews.value(key,m_translationCarryModes);
    for(const auto &entry:m_translationOverlays){const TranslationViewMode mode{entry.value(QStringLiteral("view_key")).toString(),entry.value(QStringLiteral("target")).toMap().value(QStringLiteral("page")).toInt()};if(entry.value(QStringLiteral("original")).toBool())modes.insert(mode);else modes.remove(mode);}
    if(!key.isEmpty()){m_translationViews.insert(key,modes);m_translationViewOrder.removeAll(key);m_translationViewOrder.append(key);}
    while(m_translationViewOrder.size()>64)m_translationViews.remove(m_translationViewOrder.takeFirst());
    m_translationCarryModes.clear();
    const auto map=report.value(QStringLiteral("page_map")).toList();
    for(const auto &mode:modes){if(!map.isEmpty()){if(mode.second<0 || mode.second>=map.size() || map[mode.second].isNull())continue;m_translationCarryModes.insert({mode.first,map[mode.second].toInt()});}else m_translationCarryModes.insert(mode);}
    m_translationRestoreHistory=operation==QStringLiteral("page_undo") || operation==QStringLiteral("page_redo") || operation==QStringLiteral("page_discard") || operation==QStringLiteral("document_discard");
    if(operation==QStringLiteral("document_save") || operation==QStringLiteral("page_apply")){m_translationViews.clear();m_translationViewOrder.clear();}
}
void ReaderController::resetTranslations(bool preserveViews) {
    if(!preserveViews){m_translationViews.clear();m_translationCarryModes.clear();m_translationViewOrder.clear();m_translationRestoreHistory=false;}
    abandonTranslations();m_translationState.clear();m_translationOverlays.clear();m_translationInspections.clear();m_translationInspectedPages.clear();
    m_translationPreparedToken.clear();m_translationActiveToken.clear();m_translationActive=false;m_translationCancelId=0;
    // resetAi is part of publishing a document revision. Defer these new notifications
    // until that enclosing publication has returned; a direct listener may delete the reader.
    QPointer<ReaderController> alive(this);const auto generation=m_generation;
    QMetaObject::invokeMethod(this,[alive,generation]{
        if(!alive || generation!=alive->m_generation)return;
        emit alive->translationOverlaysChanged();
        if(alive && generation==alive->m_generation)emit alive->translationsChanged();
    },Qt::QueuedConnection);
}
void ReaderController::inspectTranslations(int page) {
    if(!m_document || m_loading || m_snapshotMode || page<0 || page>=m_pages.size() || m_translationInspectedPages.contains(page))return;
    m_translationInspectedPages.insert(page);
    const auto document=m_document;const auto generation=m_generation;QPointer<ReaderController> alive(this);
    const auto id=submit(QStringLiteral("translation_inspect"),{{QStringLiteral("page"),page}});
    if(alive && document==m_document && generation==m_generation && id)m_translationInspections.insert(id,page);
}
bool ReaderController::prepareInplaceTranslation(const QVariantMap &request) {
    if(!m_document || m_loading || m_snapshotMode || m_pendingCommands || m_aiState.value(QStringLiteral("running")).toBool())return false;
    if(!m_translationPreparedToken.isEmpty())lyra_reader_desktop_cancel_translation(m_document.get());
    m_translationPreparedToken.clear();m_aiPreviewId=0;
    const auto document=m_document;const auto generation=m_generation,epoch=++m_aiPreviewEpoch;QPointer<ReaderController> alive(this);
    const auto current=[&]{return alive && document==m_document && generation==m_generation && epoch==m_aiPreviewEpoch;};
    m_aiState.remove(QStringLiteral("plan"));m_aiState.insert(QStringLiteral("previewView"),QStringLiteral("translation"));m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("translation"));
    m_aiState.insert(QStringLiteral("previewChatGptAccount"),request.value(QStringLiteral("chatgpt_account")));
    m_aiState.insert(QStringLiteral("previewSelection"),request.value(QStringLiteral("selection")));
    m_aiState.insert(QStringLiteral("planSent"),false);m_aiState.insert(QStringLiteral("status"),tr("Preparing in-place translations locally…"));m_aiPlanGeneration=generation;
    emit aiStateChanged();if(!current())return false;
    const auto id=submit(QStringLiteral("translation_prepare"),{{QStringLiteral("request"),request}});
    if(!current())return false;m_aiPreviewId=id;return id!=0;
}
bool ReaderController::startInplaceTranslation(const QString &key,const QVariantMap &plan) {
    const auto token=plan.value(QStringLiteral("token")).toString();
    if(token.isEmpty() || token!=m_translationPreparedToken)return false;
    const auto document=m_document;const auto generation=m_generation,epoch=m_aiPreviewEpoch;QPointer<ReaderController> alive(this);
    const auto current=[&]{return alive && document==m_document && generation==m_generation && epoch==m_aiPreviewEpoch;};
    const auto retire=[&]{
        if(!alive || document!=m_document || generation!=m_generation || m_translationActiveToken!=token)return;
        abandonTranslations();m_translationActive=false;m_translationActiveToken.clear();m_aiStartId=0;m_aiTimer.stop();
        m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("planSent"),false);
        m_aiState.insert(QStringLiteral("status"),tr("The request changed before sending. Preview it again."));emit aiStateChanged();
    };
    m_translationActive=true;m_translationActiveToken=token;m_aiState.insert(QStringLiteral("running"),true);m_aiState.insert(QStringLiteral("planSent"),true);
    m_aiState.insert(QStringLiteral("responseView"),QStringLiteral("translation"));m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("translation"));m_aiState.insert(QStringLiteral("output"),QString{});m_aiState.insert(QStringLiteral("reasoning"),QString{});
    m_aiState.insert(QStringLiteral("responsePlan"),plan);m_aiState.insert(QStringLiteral("status"),tr("Starting in-place translations…"));
    emit aiStateChanged();if(!current()){retire();return false;}
    QVariantMap request{{QStringLiteral("token"),token}};
    if(plan.contains(QStringLiteral("chatgpt_account"))) {
        request.insert(QStringLiteral("chatgpt_account"),plan.value(QStringLiteral("chatgpt_account")));
        request.insert(QStringLiteral("chatgpt_access_token"),key);
    } else {
        request.insert(QStringLiteral("api_key"),key);
    }
    const auto id=submit(QStringLiteral("translation_start"),request);
    if(!current()){retire();return false;}m_aiStartId=id;return id!=0;
}
void ReaderController::cancelInplaceTranslation() {
    if(!m_document)return;
    lyra_reader_desktop_cancel_translation(m_document.get());
    const auto token=m_translationActiveToken.isEmpty()?m_translationPreparedToken:m_translationActiveToken;
    if(token.isEmpty())return;
    const auto document=m_document;const auto generation=m_generation;QPointer<ReaderController> alive(this);
    const auto id=submit(QStringLiteral("translation_cancel"),{{QStringLiteral("token"),token}});
    if(alive && document==m_document && generation==m_generation)m_translationCancelId=id;
}
void ReaderController::toggleTranslation(const QString &id) {
    auto found=m_translationOverlays.find(id);if(found==m_translationOverlays.end())return;
    auto entry=found.value();entry.insert(QStringLiteral("original"),!entry.value(QStringLiteral("original")).toBool());found.value()=entry;emit translationOverlaysChanged();
}
void ReaderController::acceptTranslationOverlay(const QVariantMap &target,const QString &id,const QString &text,const QString &language,const QString &model,const QString &viewKey,bool restoreView) {
    if(id.isEmpty() || text.trimmed().isEmpty())return;
    const auto rect=target.value(QStringLiteral("rect")).toMap();
    const auto bounds=[](const QVariantMap &r){return QRectF(r.value(QStringLiteral("x_pt")).toDouble(),r.value(QStringLiteral("y_pt")).toDouble(),r.value(QStringLiteral("width_pt")).toDouble(),r.value(QStringLiteral("height_pt")).toDouble());};
    for(auto it=m_translationOverlays.begin();it!=m_translationOverlays.end();) {
        const auto oldTarget=it->value(QStringLiteral("target")).toMap();
        if(it.key()!=id && oldTarget.value(QStringLiteral("page"))==target.value(QStringLiteral("page")) && bounds(oldTarget.value(QStringLiteral("rect")).toMap()).intersects(bounds(rect)))it=m_translationOverlays.erase(it);else ++it;
    }
    auto entry=m_translationOverlays.value(id);entry.insert(QStringLiteral("view_key"),viewKey);entry.insert(QStringLiteral("language"),language);entry.insert(QStringLiteral("model"),model);entry.insert(QStringLiteral("id"),id);entry.insert(QStringLiteral("target"),target);entry.insert(QStringLiteral("text"),text);
    if(!entry.contains(QStringLiteral("original"))){
        const auto revision=m_data.value(QStringLiteral("document_revision")).toString();
        const auto &modes=m_translationRestoreHistory && m_translationViews.contains(revision)?m_translationViews[revision]:m_translationCarryModes;
        entry.insert(QStringLiteral("original"),restoreView && modes.contains({viewKey,target.value(QStringLiteral("page")).toInt()}));
    }
    m_translationOverlays.insert(id,entry);
}
void ReaderController::applyTranslationFrame(const QVariantMap &frame) {
    for(const auto *key:{"unitTitle","unitLanguage","usage","diagnostics"})m_aiState.remove(QLatin1String(key));
    m_translationState=frame;m_translationActive=frame.value(QStringLiteral("running")).toBool();m_aiState.insert(QStringLiteral("running"),m_translationActive);
    QStringList outputs;QString warning,failure;qsizetype remaining=maximumAiCharacters;bool shortened=false;int ready=0,failed=0,cancelled=0;
    for(const auto &value:frame.value(QStringLiteral("rows")).toList()) {
        const auto row=value.toMap();const auto state=row.value(QStringLiteral("state")).toString();
        if(state==QStringLiteral("ready")){++ready;acceptTranslationOverlay(row.value(QStringLiteral("target")).toMap(),row.value(QStringLiteral("id")).toString(),row.value(QStringLiteral("translated_text")).toString(),row.value(QStringLiteral("language")).toString(),row.value(QStringLiteral("model")).toString(),row.value(QStringLiteral("view_key")).toString(),false);}
        if(state==QStringLiteral("failed"))++failed;if(state==QStringLiteral("cancelled"))++cancelled;
        if(warning.isEmpty())warning=row.value(QStringLiteral("cache_warning")).toString();
        if(failure.isEmpty())failure=row.value(QStringLiteral("error")).toString();
        auto text=row.value(QStringLiteral("translated_text")).toString();
        if(text.isEmpty() && state==QStringLiteral("ready"))text=m_translationOverlays.value(row.value(QStringLiteral("id")).toString()).value(QStringLiteral("text")).toString();
        if(!text.isEmpty()){const auto count=std::min(remaining,text.size());if(count)outputs.append(text.left(count));remaining-=count;shortened=shortened || count<text.size();}
    }
    m_aiState.insert(QStringLiteral("output"),outputs.join(QStringLiteral("\n\n")));m_aiState.insert(QStringLiteral("responseView"),QStringLiteral("translation"));m_aiState.insert(QStringLiteral("statusView"),QStringLiteral("translation"));
    m_aiState.insert(QStringLiteral("status"),m_translationActive?(frame.value(QStringLiteral("max_concurrent")).toInt()>0?tr("Translating · %1 complete · up to %2 in flight").arg(ready).arg(frame.value(QStringLiteral("max_concurrent")).toInt()):tr("Translating · %1 complete").arg(ready)):tr("%1 translated · %2 failed · %3 cancelled").arg(ready).arg(failed).arg(cancelled));
    if(shortened)warning+=(warning.isEmpty()?QString{}:QStringLiteral(" "))+tr("The side panel preview is shortened. Each passage menu retains its full translation.");
    if(!warning.isEmpty())m_translationState.insert(QStringLiteral("cache_warning"),warning);
    if(!m_translationActive && !failure.isEmpty())m_aiState.insert(QStringLiteral("status"),m_aiState.value(QStringLiteral("status")).toString()+QStringLiteral(" · ")+failure);
    if(!m_translationActive){m_aiTimer.stop();retainAiResult(failed?QStringLiteral("failed"):cancelled?QStringLiteral("cancelled"):QStringLiteral("finished"));}
}
void ReaderController::handleTranslationCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error) {
    if(!operation.startsWith(QStringLiteral("translation_")))return;
    const auto frame=result.toMap();const auto previousOverlays=m_translationOverlays;
    if(operation==QStringLiteral("translation_inspect")) {
        if(!m_translationInspections.contains(id))return;
        const auto page=m_translationInspections.take(id);
        if(!error.isEmpty()){m_translationState.insert(QStringLiteral("cache_warning"),error);emit translationsChanged();return;}
        auto entries=frame.value(QStringLiteral("entries")).toList();

        for(const auto &value:entries){const auto row=value.toMap(),entry=row.value(QStringLiteral("entry")).toMap();acceptTranslationOverlay(row.value(QStringLiteral("target")).toMap(),entry.value(QStringLiteral("key")).toString(),entry.value(QStringLiteral("translatedText")).toString(),entry.value(QStringLiteral("language")).toString(),entry.value(QStringLiteral("model")).toString(),row.value(QStringLiteral("view_key")).toString(),true);}
        m_translationState.insert(QStringLiteral("cache_warning"),frame.value(QStringLiteral("cache_warning")));
        if(frame.value(QStringLiteral("stale")).toInt()>0)m_translationState.insert(QStringLiteral("cache_warning"),tr("Some saved translations no longer match page %1. They are hidden; nothing was requested.").arg(page+1));
        QPointer<ReaderController> alive(this);const auto generation=m_generation;if(previousOverlays!=m_translationOverlays)emit translationOverlaysChanged();if(alive && generation==m_generation)emit translationsChanged();return;
    }
    QPointer<ReaderController> alive(this);const auto generation=m_generation;const auto epoch=m_aiPreviewEpoch;
    const auto current=[&]{return alive && generation==m_generation && epoch==m_aiPreviewEpoch;};
    if(operation==QStringLiteral("translation_prepare")) {
        if(id!=m_aiPreviewId)return;m_aiPreviewId=0;
        if(error.isEmpty()) {
            const auto plan=frame.value(QStringLiteral("plan")).toMap();m_translationPreparedToken=plan.value(QStringLiteral("token")).toString();
            if(!plan.isEmpty())m_aiState.insert(QStringLiteral("plan"),plan);
            m_aiState.insert(QStringLiteral("responsePlan"),QVariantMap{{QStringLiteral("action"),QStringLiteral("TranslateSelection")},{QStringLiteral("source_pages"),QVariantList{}},{QStringLiteral("sources"),QVariantList{}},{QStringLiteral("generation"),m_generation}});
            const auto preparedFrame=frame.value(QStringLiteral("translation")).toMap();
            for(const auto &value:preparedFrame.value(QStringLiteral("rows")).toList()){auto found=m_translationOverlays.find(value.toMap().value(QStringLiteral("id")).toString());if(found!=m_translationOverlays.end())found->insert(QStringLiteral("original"),false);}
            applyTranslationFrame(preparedFrame);
            m_aiState.insert(QStringLiteral("status"),plan.isEmpty()?tr("Saved translations shown locally. Nothing sent."):tr("Translation previews ready. Nothing sent yet."));
        }else m_aiState.insert(QStringLiteral("status"),error);
    }else {
        const bool start=operation==QStringLiteral("translation_start") && id==m_aiStartId;
        const bool poll=operation==QStringLiteral("translation_poll") && id==m_aiPollId;
        const bool cancel=operation==QStringLiteral("translation_cancel") && id==m_translationCancelId;
        if(!start && !poll && !cancel)return;
        if(start)m_aiStartId=0;if(poll)m_aiPollId=0;if(cancel)m_translationCancelId=0;
        if(error.isEmpty()){applyTranslationFrame(frame);if(m_translationActive)m_aiTimer.start();}
        else {m_translationActive=false;m_aiTimer.stop();m_aiState.insert(QStringLiteral("running"),false);m_aiState.insert(QStringLiteral("status"),error);if(m_document)lyra_reader_desktop_cancel_translation(m_document.get());}
    }
    if(previousOverlays!=m_translationOverlays)emit translationOverlaysChanged();if(!current())return;emit translationsChanged();if(!current())return;emit aiStateChanged();
}
