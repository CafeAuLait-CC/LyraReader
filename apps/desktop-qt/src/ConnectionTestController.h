#pragma once
#include "CredentialStore.h"
#include "lyra_reader_desktop.h"
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantMap>
#include <functional>
#include <memory>

// One document-free Settings probe per reader window. Credentials stay in the
// platform vault or the short-lived worker closure, never in its public state.
class ConnectionTestController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
public:
    explicit ConnectionTestController(CredentialStore *credentials,QObject *parent=nullptr);
    ~ConnectionTestController() override;
    QVariantMap state() const {return m_state;}
    bool busy() const {return m_busy;}
    Q_INVOKABLE void start(const QString &baseUrl,const QString &model,const QString &typedKey);
    Q_INVOKABLE void cancel();
signals:
    void changed();
private:
    using Handle=std::shared_ptr<LyraReaderConnectionTest>;
    struct Outcome {Handle handle;QVariantMap state;QString error;};
    void run(const QVariantMap &input,std::function<void(Outcome)> then);
    void startRequest(QString key);
    void poll();
    void update(QVariantMap state,bool busy);
    void fail(const QString &message,const QString &code=QStringLiteral("Other"));
    static Outcome command(const Handle &handle,const QVariantMap &input);
    Handle m_handle;
    QPointer<CredentialStore> m_credentials;
    QTimer m_poll;
    QVariantMap m_state{{"phase","idle"}};
    QString m_account;
    quint64 m_epoch=0,m_pendingLookup=0;
    bool m_busy=false,m_pollPending=false;
};
