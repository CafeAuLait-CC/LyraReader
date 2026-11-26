#pragma once

#include "CredentialStore.h"
#include "lyra_reader_desktop.h"

#include <QPointer>
#include <QLockFile>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include <memory>

class ReaderController;
class QSettings;
class QJsonObject;

// One native account coordinator for every reader window. QML only sees metadata.
class ChatGptAccounts : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList accounts READ accounts NOTIFY changed)
    Q_PROPERTY(QVariantList models READ models NOTIFY changed)
    Q_PROPERTY(QString accountId READ accountId NOTIFY profileChanged)
    Q_PROPERTY(QString model READ model NOTIFY profileChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY profileChanged)
    Q_PROPERTY(QString connectionMode READ connectionMode NOTIFY connectionModeChanged)
    Q_PROPERTY(QString connectionModeNote READ connectionModeNote NOTIFY connectionModeChanged)
    Q_PROPERTY(bool connectionReady READ connectionReady NOTIFY connectionModeChanged)
    Q_PROPERTY(quint64 profileRevision READ profileRevision NOTIFY profileChanged)
    Q_PROPERTY(bool useForChat READ useForChat WRITE setUseForChat NOTIFY profileChanged)
    Q_PROPERTY(bool useForSelection READ useForSelection WRITE setUseForSelection NOTIFY profileChanged)
    Q_PROPERTY(bool useForLayeredSummaries READ useForLayeredSummaries WRITE setUseForLayeredSummaries NOTIFY profileChanged)
    Q_PROPERTY(bool useForWholeDocument READ useForWholeDocument WRITE setUseForWholeDocument NOTIFY profileChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool signingIn READ signingIn NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)
public:
    static ChatGptAccounts *instance();

    QVariantList accounts() const { return m_accounts; }
    QVariantList models() const;
    QString accountId() const { return m_selected; }
    QString model() const;
    bool connected() const;
    QString connectionMode() const;
    QString connectionModeNote() const;
    bool connectionReady() const { return m_connectionMode!=ConnectionMode::Invalid; }
    quint64 profileRevision() const { return m_profileRevision; }
    bool useForChat() const { return effectiveGrant(m_useForChat); }
    bool useForSelection() const { return effectiveGrant(m_useForSelection); }
    bool useForLayeredSummaries() const { return effectiveGrant(m_useForLayeredSummaries); }
    bool useForWholeDocument() const { return effectiveGrant(m_useForWholeDocument); }
    bool busy() const;
    bool signingIn() const { return m_auth && m_worker==WorkerIntent::SignIn; }
    QString status() const { return m_status; }

    Q_INVOKABLE void selectAccount(const QString &id);
    Q_INVOKABLE void selectModel(const QString &id);
    Q_INVOKABLE void beginSignIn(bool addAccount);
    Q_INVOKABLE void cancelSignIn();
    Q_INVOKABLE void reloadModels();
    Q_INVOKABLE void signOut();
    Q_INVOKABLE bool send(ReaderController *reader,const QVariantMap &plan,const QString &readingToken);
    Q_INVOKABLE bool selectConnectionMode(const QString &mode);
    Q_INVOKABLE bool refreshConnection() { return reloadPreferences(); }

    void setUseForChat(bool value);
    void setUseForSelection(bool value);
    void setUseForLayeredSummaries(bool value);
    void setUseForWholeDocument(bool value);

signals:
    void changed();
    void profileChanged();
    void connectionModeChanged();
    void chatRequestFailed(ReaderController *reader,const QString &message);

private:
    explicit ChatGptAccounts(QObject *parent);
    enum class VaultIntent { None, Save, LoadForChat, SaveRefresh, LoadForRevoke, Remove, LoadForModels, SaveModels };
    enum class WorkerIntent { SignIn, Refresh, Revoke, Models };
    enum class ConnectionMode { ApiKey, ChatGpt, Legacy, Invalid };
    bool effectiveGrant(bool legacy) const { return m_connectionMode==ConnectionMode::ChatGpt
        || (m_connectionMode==ConnectionMode::Legacy && legacy); }

    QVariantMap selected() const;
    void poll();
    void vaultFinished(quint64 id,const QString &secret,const QString &error);
    void setStatus(const QString &message);
    bool readPreferences(QSettings &settings);
    bool reloadPreferences();
    bool writePreference(const QString &key,const QVariant &value);
    bool writeAccount(const QVariantMap &fields,bool enrolling);
    void setUsagePreference(const QString &key,bool &current,bool value);
    bool allowsPlan(const QVariantMap &plan,const QString &readingToken) const;
    bool lockAccount(const QString &id);
    bool startSessionWork(WorkerIntent intent,const QJsonObject &credential);
    void removeFromVault(bool revoked);
    void finishChat(const QString &token,const QString &error={});

    CredentialStore m_vault;
    QTimer m_pollTimer;
    std::unique_ptr<LyraReaderDesktopChatGptAuth, decltype(&lyra_reader_desktop_chatgpt_auth_free)> m_auth{
        nullptr,lyra_reader_desktop_chatgpt_auth_free};
    QVariantList m_accounts;
    QString m_selected,m_status,m_signInSubject,m_registration;
    bool m_useForChat=false;
    bool m_useForSelection=false;
    bool m_useForLayeredSummaries=false;
    bool m_useForWholeDocument=false;
    ConnectionMode m_connectionMode=ConnectionMode::ApiKey;
    bool m_hasConnectionChoice=false;
    quint64 m_profileRevision=0;
    VaultIntent m_intent=VaultIntent::None;
    WorkerIntent m_worker=WorkerIntent::SignIn;
    quint64 m_vaultId=0;
    std::unique_ptr<QLockFile> m_accountLock;
    QString m_refreshedToken;
    bool m_revoked=false;
    QVariantMap m_candidate,m_pendingPlan;
    QString m_pendingReadingToken,m_pendingConnectionMode;
    QPointer<ReaderController> m_pendingReader;
};
