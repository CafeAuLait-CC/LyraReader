#include "ReaderController.h"
#include "NativeRaster.h"
#include <QFutureWatcher>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QPointer>
#include <QtConcurrentRun>

namespace {
struct PassageResult {QVariantMap frame;QString error;};constexpr qint64 maximumPassageText=2*1024*1024;
struct PassageInput {QByteArray signature;QString error;};
PassageInput passageInput(const QVariantList &entries) {
    const auto error=[](const char *message){return PassageInput{{},QCoreApplication::translate("ReaderController",message)};};
    if(entries.size()>512)return error("This page has too many annotation contexts.");
    qsizetype regions=0;
    for(const auto &value:entries){const auto entry=value.toMap();const auto count=entry.value(QStringLiteral("regions")).toList().size();if(entry.value(QStringLiteral("id")).toString().size()>256 || count>8192-regions)return error("The annotation context geometry exceeds its input limits.");regions+=count;}
    const auto encoded=QJsonDocument::fromVariant(entries).toJson(QJsonDocument::Compact);
    if(encoded.size()>1024*1024)return error("This page exceeds the annotation context input budget.");
    return {QCryptographicHash::hash(encoded,QCryptographicHash::Sha256),{}};
}
}
QString ReaderController::annotationPassageInputKey(const QVariantList &entries)const{return QString::fromLatin1(passageInput(entries).signature.toHex());}
QVariantMap ReaderController::annotationPassages()const {
    QVariantMap result;for(auto i=m_passageFrames.cbegin();i!=m_passageFrames.cend();++i)result.insert(QString::number(i.key()),i.value());return result;
}
void ReaderController::initPassages() {
    connect(this,&ReaderController::documentReset,this,[this]{m_passageInputs.clear();m_passageQueued.clear();m_passageQueueOrder.clear();m_passageFrames.clear();m_passageFrameOrder.clear();m_passageFrameBytes.clear();m_passageBytes=0;m_passageRunning=0;const auto generation=m_generation;QPointer<ReaderController> alive(this);QMetaObject::invokeMethod(this,[alive,generation]{if(alive && generation==alive->m_generation)emit alive->annotationPassagesChanged();},Qt::QueuedConnection);});
}
void ReaderController::requestAnnotationPassages(int page,const QVariantList &entries) {
    if(!m_source || m_loading || page<0 || page>=m_pages.size() )return;
    const auto source=m_source;const auto generation=m_generation;
    const auto input=passageInput(entries);
    if(!input.error.isEmpty()){m_passageInputs.remove(page);cachePassageFrame(page,{{QStringLiteral("error"),input.error}});emit annotationPassagesChanged();return;}
    const auto signature=input.signature;
    if(m_passageInputs.value(page)==signature){if(m_passageFrames.contains(page)){m_passageFrameOrder.removeAll(page);m_passageFrameOrder.append(page);}return;}
    m_passageInputs.insert(page,signature);
    if(m_passageFrames.remove(page)){m_passageBytes-=m_passageFrameBytes.take(page);m_passageFrameOrder.removeAll(page);QPointer<ReaderController> alive(this);emit annotationPassagesChanged();if(!alive || source!=m_source || generation!=m_generation)return;}
    if(m_passageRunning>=2){m_passageQueued.insert(page,entries);m_passageQueueOrder.removeAll(page);m_passageQueueOrder.append(page);while(m_passageQueueOrder.size()>16){const auto drop=m_passageQueueOrder.takeFirst();m_passageQueued.remove(drop);m_passageInputs.remove(drop);}return;}
    startPassageQuery(page,entries,signature);
}
void ReaderController::cachePassageFrame(int page,QVariantMap frame) {
    m_passageBytes-=m_passageFrameBytes.take(page);m_passageFrameOrder.removeAll(page);
    QString error=frame.value(QStringLiteral("error")).toString();
    QVariantMap byId;QVariantList order;qint64 bytes=0;
    if(error.isEmpty())for(const auto &value:frame.value(QStringLiteral("entries")).toList()){
        const auto row=value.toMap();const auto id=row.value(QStringLiteral("id")).toString();if(id.isEmpty())continue;
        bytes+=(row.value(QStringLiteral("quote")).toString().size()+row.value(QStringLiteral("context")).toString().size()+id.size())*2;
        if(bytes>maximumPassageText){error=tr("This page exceeds the annotation context display budget.");byId.clear();order.clear();bytes=0;break;}
        byId.insert(id,row);order.append(id);
    }
    QVariantList groups;
    if(error.isEmpty())for(const auto &value:frame.value(QStringLiteral("groups")).toList()) {
        const auto group=value.toMap();
        bytes+=(group.value(QStringLiteral("text")).toString().size()+group.value(QStringLiteral("id")).toString().size())*2;
        for(const auto &member:group.value(QStringLiteral("members")).toList())bytes+=member.toMap().value(QStringLiteral("id")).toString().size()*2;
        if(bytes>maximumPassageText){error=tr("This page exceeds the annotation context display budget.");byId.clear();order.clear();groups.clear();bytes=0;break;}
        groups.append(group);
    }
    frame.insert(QStringLiteral("groups"),groups);
    frame.insert(QStringLiteral("entries"),byId);frame.insert(QStringLiteral("order"),order);frame.insert(QStringLiteral("error"),error);
    while(!m_passageFrameOrder.isEmpty() && (m_passageFrameOrder.size()>=32 || m_passageBytes+bytes>maximumPassageText)){
        const auto oldest=m_passageFrameOrder.takeFirst();m_passageFrames.remove(oldest);m_passageBytes-=m_passageFrameBytes.take(oldest);m_passageInputs.remove(oldest);
    }
    m_passageFrames.insert(page,frame);m_passageFrameBytes.insert(page,bytes);m_passageFrameOrder.append(page);m_passageBytes+=bytes;
}
void ReaderController::startPassageQuery(int page,const QVariantList &entries,const QByteArray &signature) {
    const auto source=m_source;const auto generation=m_generation;++m_passageRunning;
    auto *watcher=new QFutureWatcher<PassageResult>(this);
    connect(watcher,&QFutureWatcher<PassageResult>::finished,this,[this,watcher,source,generation,page,signature]{
        auto result=watcher->result();watcher->deleteLater();
        if(source!=m_source || generation!=m_generation)return;
        --m_passageRunning;
        if(m_passageInputs.value(page)==signature) {
            result.frame.insert(QStringLiteral("error"),result.error);result.frame.insert(QStringLiteral("input_key"),QString::fromLatin1(signature.toHex()));cachePassageFrame(page,result.frame);
            QPointer<ReaderController> alive(this);emit annotationPassagesChanged();if(!alive || source!=m_source || generation!=m_generation)return;
        }
        while(m_passageRunning<2 && !m_passageQueueOrder.isEmpty()){
            const auto next=m_passageQueueOrder.takeFirst();const auto entries=m_passageQueued.take(next);const auto key=m_passageInputs.value(next);if(!key.isEmpty())startPassageQuery(next,entries,key);
        }
    });
    watcher->setFuture(QtConcurrent::run([source,page,entries]{PassageResult result;result.frame=source->query({{QStringLiteral("op"),QStringLiteral("annotation_passages")},{QStringLiteral("page"),page},{QStringLiteral("entries"),entries}},&result.error).toMap();return result;}));
}
