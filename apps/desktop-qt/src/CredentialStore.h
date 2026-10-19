#pragma once
#include <QObject>

// QtKeychain selects Secret Service/KWallet on Linux and the native vault on Windows.
// Plaintext fallback is explicitly disabled on every job.
class CredentialStore : public QObject {
    Q_OBJECT
public:
    explicit CredentialStore(QObject *parent=nullptr):QObject(parent){}
    Q_INVOKABLE quint64 read(const QString &account);
    Q_INVOKABLE quint64 write(const QString &account,const QString &secret);
    Q_INVOKABLE quint64 remove(const QString &account);
signals:
    void finished(quint64 id,const QString &operation,const QString &secret,const QString &error);
private:
    quint64 m_sequence=0;
};
