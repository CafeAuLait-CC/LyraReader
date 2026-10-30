#pragma once
#include <QObject>
#include <QString>
#include <QList>
#include <functional>
#include <memory>

// QtKeychain selects Secret Service/KWallet on Linux and the native vault on Windows.
// Plaintext fallback is explicitly disabled on every job.
class CredentialStore : public QObject {
    Q_OBJECT
public:
    explicit CredentialStore(QObject *parent=nullptr);
    ~CredentialStore() override;
    Q_INVOKABLE quint64 read(const QString &account);
    Q_INVOKABLE quint64 write(const QString &account,const QString &secret);
    Q_INVOKABLE quint64 remove(const QString &account);
    Q_INVOKABLE void clearSession();
signals:
    void finished(quint64 id,const QString &operation,const QString &secret,const QString &error);
protected:
    enum class VaultOperation { Read, Write, Remove };
    using Completion=std::function<void(QString,QString)>;
    // Platform I/O boundary; completions run on this object's Qt thread.
    virtual void startVault(VaultOperation operation,const QString &key,const QString &secret,Completion completion);
private:
    struct PendingRead { quint64 epoch; QList<quint64> ids; };
    static void invalidateAccount(const QString &key);
    void selectAccount(const QString &key);
    quint64 m_sequence=0;
    quint64 m_epoch=0;
    QString m_account,m_secret;
    std::shared_ptr<PendingRead> m_read;
};
