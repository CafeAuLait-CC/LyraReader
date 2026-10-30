#include "CredentialStore.h"
#include <qt6keychain/keychain.h>
#include <QCryptographicHash>
#include <QPointer>
#include <QTimer>
#include <QUrl>

namespace {
const QString service=QStringLiteral("com.alex.lyrareader.ai");
QList<CredentialStore *> &stores() {static QList<CredentialStore *> value;return value;}
QString accountKey(const QString &account) {
    const auto url=QUrl(account).adjusted(QUrl::RemoveUserInfo|QUrl::RemoveFragment|QUrl::RemoveQuery);
    return QString::fromLatin1(QCryptographicHash::hash(url.toEncoded(),QCryptographicHash::Sha256).toHex());
}
}
CredentialStore::CredentialStore(QObject *parent):QObject(parent){stores().append(this);}
CredentialStore::~CredentialStore(){stores().removeAll(this);}
void CredentialStore::clearSession() {
    ++m_epoch;m_account.clear();m_secret.clear();m_read.reset();
}
void CredentialStore::selectAccount(const QString &key) {
    if(m_account!=key){clearSession();m_account=key;}
}
void CredentialStore::invalidateAccount(const QString &key) {
    // Separate reader windows must not retain a credential changed in Settings.
    for(auto *store:stores())if(store->m_account==key)store->clearSession();
}
quint64 CredentialStore::read(const QString &account) {
    const auto id=++m_sequence;
    const auto key=accountKey(account);selectAccount(key);
    const auto epoch=m_epoch;
    if(!m_secret.isEmpty()) {
        // Keep the same asynchronous contract as a real vault job. QML must get
        // the returned request id before its completion signal can arrive.
        QTimer::singleShot(0,this,[this,id,epoch] {
            const bool current=epoch==m_epoch;
            emit finished(id,QStringLiteral("read"),current ? m_secret : QString{},current ? QString{} : tr("The credential session changed. Preview and Send again."));
        });return id;
    }
    if(m_read){m_read->ids.append(id);return id;}
    auto pending=std::make_shared<PendingRead>(PendingRead{epoch,{id}});m_read=pending;
    const QPointer<CredentialStore> guard(this);
    startVault(VaultOperation::Read,key,{},[guard,pending](QString secret,QString error) {
        if(!guard)return;
        const bool current=pending->epoch==guard->m_epoch;
        if(!error.isEmpty())secret.clear();
        if(current){guard->m_read.reset();if(error.isEmpty() && !secret.isEmpty())guard->m_secret=secret;}
        for(const auto request:pending->ids) {
            if(!guard)return;
            const bool stillCurrent=pending->epoch==guard->m_epoch;
            emit guard->finished(request,QStringLiteral("read"),stillCurrent ? secret : QString{},
                stillCurrent ? error : tr("The credential session changed. Preview and Send again."));
        }
    });
    return id;
}
quint64 CredentialStore::write(const QString &account,const QString &secret) {
    const auto id=++m_sequence;const auto key=accountKey(account);invalidateAccount(key);selectAccount(key);
    const auto epoch=m_epoch;const QPointer<CredentialStore> guard(this);
    startVault(VaultOperation::Write,key,secret,[guard,id,key,epoch,secret](QString,QString error) {
        if(!guard)return;
        const bool current=guard->m_epoch==epoch && guard->m_account==key;
        invalidateAccount(key);
        if(current && error.isEmpty()){guard->m_account=key;guard->m_secret=secret;}
        emit guard->finished(id,QStringLiteral("write"),{},error);
    });
    return id;
}
quint64 CredentialStore::remove(const QString &account) {
    const auto id=++m_sequence;const auto key=accountKey(account);invalidateAccount(key);
    const QPointer<CredentialStore> guard(this);
    startVault(VaultOperation::Remove,key,{},[guard,id,key](QString,QString error) {
        if(!guard)return;
        invalidateAccount(key);emit guard->finished(id,QStringLiteral("remove"),{},error);
    });
    return id;
}
void CredentialStore::startVault(VaultOperation operation,const QString &key,const QString &secret,Completion completion) {
    QKeychain::Job *job=nullptr;
    if(operation==VaultOperation::Read)job=new QKeychain::ReadPasswordJob(service,this);
    else if(operation==VaultOperation::Write){auto *write=new QKeychain::WritePasswordJob(service,this);write->setTextData(secret);job=write;}
    else job=new QKeychain::DeletePasswordJob(service,this);
    job->setKey(key);job->setInsecureFallback(false);
    connect(job,&QKeychain::Job::finished,this,[job,operation,completion=std::move(completion)] {
        const bool ok=job->error()==QKeychain::NoError;
        const bool absent=job->error()==QKeychain::EntryNotFound && operation!=VaultOperation::Write;
        const auto secret=ok && operation==VaultOperation::Read ? static_cast<QKeychain::ReadPasswordJob *>(job)->textData() : QString{};
        completion(secret,ok || absent ? QString{} : job->errorString());
    });job->start();
}
