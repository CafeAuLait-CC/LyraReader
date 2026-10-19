#include "CredentialStore.h"
#include <qt6keychain/keychain.h>
#include <QCryptographicHash>
#include <QUrl>

namespace {
const QString service=QStringLiteral("com.alex.lyrareader.ai");
QString accountKey(const QString &account) {
    const auto url=QUrl(account).adjusted(QUrl::RemoveUserInfo|QUrl::RemoveFragment|QUrl::RemoveQuery);
    return QString::fromLatin1(QCryptographicHash::hash(url.toEncoded(),QCryptographicHash::Sha256).toHex());
}
}
quint64 CredentialStore::read(const QString &account) {
    const auto id=++m_sequence;
    auto *job=new QKeychain::ReadPasswordJob(service,this);
    job->setKey(accountKey(account));job->setInsecureFallback(false);
    connect(job,&QKeychain::Job::finished,this,[this,id,job] {
        const bool absent=job->error()==QKeychain::EntryNotFound;
        emit finished(id,QStringLiteral("read"),job->error()==QKeychain::NoError ? job->textData() : QString{},
            job->error()==QKeychain::NoError || absent ? QString{} : job->errorString());
    });
    job->start();return id;
}
quint64 CredentialStore::write(const QString &account,const QString &secret) {
    const auto id=++m_sequence;
    auto *job=new QKeychain::WritePasswordJob(service,this);
    job->setKey(accountKey(account));job->setInsecureFallback(false);job->setTextData(secret);
    connect(job,&QKeychain::Job::finished,this,[this,id,job] {
        emit finished(id,QStringLiteral("write"),{},job->error()==QKeychain::NoError ? QString{} : job->errorString());
    });
    job->start();return id;
}
quint64 CredentialStore::remove(const QString &account) {
    const auto id=++m_sequence;
    auto *job=new QKeychain::DeletePasswordJob(service,this);
    job->setKey(accountKey(account));job->setInsecureFallback(false);
    connect(job,&QKeychain::Job::finished,this,[this,id,job] {
        emit finished(id,QStringLiteral("remove"),{},job->error()==QKeychain::NoError || job->error()==QKeychain::EntryNotFound ? QString{} : job->errorString());
    });
    job->start();return id;
}
