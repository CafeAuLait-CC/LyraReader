#include "ReadingTermController.h"
#include "ReaderController.h"
#include <QDebug>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QScopeGuard>
#include <QtConcurrentRun>

namespace {
using Handle=std::shared_ptr<LyraReaderDesktopTerm>;
struct Outcome {Handle handle;QVariantMap value;QString error;};
Outcome command(const Handle &handle,const QVariantMap &arguments) {
    Outcome result;result.handle=handle;
    const auto bytes=QJsonDocument(QJsonObject::fromVariantMap(arguments)).toJson(QJsonDocument::Compact);
    LyraReaderBuffer output{},error{};
    const auto cleanup=qScopeGuard([&]{lyra_reader_desktop_buffer_free(output);lyra_reader_desktop_buffer_free(error);});
    if(!lyra_reader_desktop_term_command(handle.get(),reinterpret_cast<const std::uint8_t *>(bytes.constData()),std::size_t(bytes.size()),&output,&error)) {
        result.error=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));
        if(result.error.isEmpty())result.error=QStringLiteral("The term operation failed without a diagnostic.");
        return result;
    }
    QJsonParseError parse;
    const auto json=QJsonDocument::fromJson(QByteArray::fromRawData(reinterpret_cast<const char *>(output.data),qsizetype(output.len)),&parse);
    // Start/cancel return a JSON boolean. Only prepare/poll expose a map.
    if(arguments.value(QStringLiteral("op"))==QStringLiteral("prepare") || arguments.value(QStringLiteral("op"))==QStringLiteral("poll")) {
        if(parse.error!=QJsonParseError::NoError || !json.isObject())result.error=QStringLiteral("Invalid term response.");
        else result.value=json.object().toVariantMap();
    }
    return result;
}
void retire(const Handle &handle) {
    if(handle)(void)QtConcurrent::run([handle]{
        const auto result=command(handle,{{QStringLiteral("op"),QStringLiteral("cancel")}});
        if(!result.error.isEmpty())qWarning()<<"lyra-reader-term: cancellation failed:"<<result.error;
    });
}
}
ReadingTermController::ReadingTermController(ReaderController *owner):QObject(owner),m_owner(owner) {
    m_poll.setInterval(60);connect(&m_poll,&QTimer::timeout,this,&ReadingTermController::poll);
    connect(owner,&ReaderController::documentReset,this,&ReadingTermController::cancel);
    connect(owner,&ReaderController::documentChanged,this,[this]{
        if(!m_state.isEmpty() && m_owner && m_generation!=m_owner->documentGeneration())cancel();
    });
}
ReadingTermController::~ReadingTermController(){m_poll.stop();retire(m_handle);}
bool ReadingTermController::current(quint64 epoch)const {
    return epoch==m_epoch && m_owner && m_generation==m_owner->documentGeneration()
        && m_owner->documentHandle()==m_document.lock();
}
void ReadingTermController::dismiss() {
    ++m_epoch;m_poll.stop();m_polling=false;retire(m_handle);m_handle.reset();m_document.reset();
}
void ReadingTermController::cancel() {
    dismiss();
    if(!m_state.isEmpty()){m_state.clear();emit changed();}
}
bool ReadingTermController::prepare(const QVariantMap &request) {
    if(!m_owner || m_owner->loading() || m_owner->snapshotReadOnly() || m_owner->documentRevisionPending())return false;
    const auto document=m_owner->documentHandle();if(!document)return false;
    QPointer<ReadingTermController> alive(this);const auto owner=m_owner;const auto generation=m_owner->documentGeneration();
    cancel();
    if(!alive || !m_owner || m_owner!=owner || m_owner->documentGeneration()!=generation || m_owner->documentHandle()!=document)return false;
    m_document=document;m_generation=generation;const auto epoch=m_epoch;
    m_part=-1;m_terminal=false;
    m_state={{QStringLiteral("phase"),QStringLiteral("preparing")},{QStringLiteral("term"),request.value(QStringLiteral("question"))},
        {QStringLiteral("request_id"),QString::number(epoch)},
        {QStringLiteral("generation"),m_generation},{QStringLiteral("output"),QString{}},{QStringLiteral("reasoning"),QString{}},
        {QStringLiteral("sent_pages"),QVariantList{}},{QStringLiteral("status"),tr("Preparing the term explanation locally. Nothing has been sent.")}};
    emit changed();if(!alive || !current(epoch))return false;
    auto *watcher=new QFutureWatcher<Outcome>(this);
    connect(watcher,&QFutureWatcher<Outcome>::finished,this,[this,watcher,epoch]{
        const auto result=watcher->result();watcher->deleteLater();if(!current(epoch))return;
        if(!result.error.isEmpty()){fail(result.error);return;}
        m_handle=result.handle;m_state.insert(QStringLiteral("plan"),result.value);
        m_state.insert(QStringLiteral("phase"),QStringLiteral("preview"));
        m_state.insert(QStringLiteral("status"),tr("Review this request before sending."));emit changed();
    });
    watcher->setFuture(QtConcurrent::run([document,request]{
        LyraReaderBuffer error{};auto *raw=lyra_reader_desktop_term_new(document.get(),&error);
        if(!raw){const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));lyra_reader_desktop_buffer_free(error);return Outcome{{},{},message};}
        lyra_reader_desktop_buffer_free(error);
        Handle handle(raw,[](auto *value){(void)QtConcurrent::run([value]{lyra_reader_desktop_term_free(value);});});
        return command(handle,{{QStringLiteral("op"),QStringLiteral("prepare")},{QStringLiteral("request"),request}});
    }));return true;
}
bool ReadingTermController::canStart(const QVariantMap &expectedPlan)const {
    const auto plan=m_state.value(QStringLiteral("plan")).toMap();
    return current(m_epoch) && m_handle && !plan.isEmpty() && plan==expectedPlan
        && m_state.value(QStringLiteral("phase"))==QStringLiteral("preview");
}
bool ReadingTermController::start(const QString &credential,const QVariantMap &expectedPlan) {
    const auto plan=m_state.value(QStringLiteral("plan")).toMap();const auto epoch=m_epoch;
    if(!canStart(expectedPlan))return false;
    QVariantMap request{{QStringLiteral("op"),QStringLiteral("start")},{QStringLiteral("plan"),plan}};
    const auto account=plan.value(QStringLiteral("chatgpt_account")).toString();
    if(account.isEmpty())request.insert(QStringLiteral("api_key"),credential);
    else {request.insert(QStringLiteral("chatgpt_account"),account);request.insert(QStringLiteral("chatgpt_access_token"),credential);}
    m_state.insert(QStringLiteral("phase"),QStringLiteral("starting"));
    m_state.insert(QStringLiteral("status"),tr("Starting the reviewed term request…"));
    QPointer<ReadingTermController> alive(this);emit changed();if(!alive || !current(epoch))return false;
    auto *watcher=new QFutureWatcher<Outcome>(this);
    connect(watcher,&QFutureWatcher<Outcome>::finished,this,[this,watcher,epoch]{
        const auto result=watcher->result();watcher->deleteLater();if(!current(epoch))return;
        if(!result.error.isEmpty()){fail(result.error);return;}
        m_state.insert(QStringLiteral("phase"),QStringLiteral("running"));
        m_state.insert(QStringLiteral("status"),tr("Receiving term explanation…"));
        QPointer<ReadingTermController> alive(this);emit changed();if(alive && current(epoch))m_poll.start();
    });
    const auto handle=m_handle;watcher->setFuture(QtConcurrent::run([handle,request]{return command(handle,request);}));return true;
}
void ReadingTermController::fail(const QString &message) {
    m_poll.stop();retire(m_handle);
    m_state.insert(QStringLiteral("phase"),QStringLiteral("failed"));m_state.insert(QStringLiteral("status"),message);emit changed();
}
void ReadingTermController::poll() {
    const auto epoch=m_epoch;
    if(m_polling || !current(epoch) || !m_handle || m_state.value(QStringLiteral("phase"))!=QStringLiteral("running"))return;
    m_polling=true;auto *watcher=new QFutureWatcher<Outcome>(this);
    connect(watcher,&QFutureWatcher<Outcome>::finished,this,[this,watcher,epoch]{
        const auto result=watcher->result();watcher->deleteLater();if(!current(epoch))return;
        m_polling=false;if(!result.error.isEmpty()){fail(result.error);return;}observe(result.value);
    });
    const auto handle=m_handle;watcher->setFuture(QtConcurrent::run([handle]{return command(handle,{{QStringLiteral("op"),QStringLiteral("poll")}});}));
}
void ReadingTermController::observe(const QVariantMap &result) {
    constexpr qsizetype maximumCharacters=4*1024*1024;
    const auto parts=m_state.value(QStringLiteral("plan")).toMap().value(QStringLiteral("parts")).toList();
    for(const auto &value:result.value(QStringLiteral("events")).toList()) {
        if(value.toString()==QStringLiteral("Done")){m_terminal=true;continue;}
        const auto event=value.toMap();
        if(event.contains(QStringLiteral("PartStarted"))) {
            const auto part=event.value(QStringLiteral("PartStarted")).toMap();
            bool valid=false;const auto index=part.value(QStringLiteral("index")).toInt(&valid);
            if(!valid || index<0 || index>=parts.size() || part.value(QStringLiteral("total")).toInt()!=parts.size()) {
                fail(tr("The term response does not match its reviewed parts."));return;
            }
            auto output=m_state.value(QStringLiteral("output")).toString();
            if(index!=m_part && !output.isEmpty()) {
                if(output.size()>maximumCharacters-2){fail(tr("The term response exceeds its supported size. The partial answer was kept."));return;}
                m_state.insert(QStringLiteral("output"),output+QStringLiteral("\n\n"));
            }
            m_part=index;
        } else if(event.contains(QStringLiteral("Delta")) || event.contains(QStringLiteral("ReasoningDelta"))) {
            const bool answer=event.contains(QStringLiteral("Delta"));
            const auto text=event.value(answer?QStringLiteral("Delta"):QStringLiteral("ReasoningDelta")).toMap().value(QStringLiteral("text")).toString();
            const auto key=answer?QStringLiteral("output"):QStringLiteral("reasoning");const auto previous=m_state.value(key).toString();
            if(text.size()>maximumCharacters-previous.size()){fail(tr("The term response exceeds its supported size. The partial answer was kept."));return;}
            m_state.insert(key,previous+text);
            if(answer && !text.isEmpty() && m_part>=0) {
                auto pages=m_state.value(QStringLiteral("sent_pages")).toList();
                for(const auto &page:parts[m_part].toMap().value(QStringLiteral("pages")).toList())if(!pages.contains(page))pages.append(page);
                m_state.insert(QStringLiteral("sent_pages"),pages);
            }
        } else if(event.contains(QStringLiteral("Usage")))m_state.insert(QStringLiteral("usage"),event.value(QStringLiteral("Usage")));
        else if(event.contains(QStringLiteral("Error"))) {
            fail(event.value(QStringLiteral("Error")).toMap().value(QStringLiteral("message")).toString());return;
        }
    }
    if(result.value(QStringLiteral("finished")).toBool()) {
        m_poll.stop();m_state.insert(QStringLiteral("phase"),m_terminal?QStringLiteral("done"):QStringLiteral("failed"));
        m_state.insert(QStringLiteral("status"),m_terminal?tr("Term explanation complete."):tr("The term stream stopped before completion. The partial answer was kept."));
    }
    emit changed();
}
