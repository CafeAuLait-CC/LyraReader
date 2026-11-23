#include "ChatGptAccounts.h"

#include "ReaderController.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSettings>
#include <QStandardPaths>
#include <QUuid>
#include <QUrl>

#include <algorithm>
#include <utility>

namespace {
const QString settingsGroup=QStringLiteral("chatGptPlan");
const QString pendingRegistrationKey=settingsGroup+QStringLiteral("/pendingRegistration");

QByteArray takeBuffer(LyraReaderBuffer buffer) {
    const QByteArray bytes(reinterpret_cast<const char *>(buffer.data),qsizetype(buffer.len));
    lyra_reader_desktop_buffer_free(buffer);
    return bytes;
}

QString vaultKey(const QString &id) {
    return QStringLiteral("lyra://chatgpt/account/")+id;
}

QString newId() {
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

QString accountId(const QVariant &entry) {
    return entry.toMap().value(QStringLiteral("id")).toString();
}
}

ChatGptAccounts *ChatGptAccounts::instance() {
    static QPointer<ChatGptAccounts> accounts;
    if(!accounts)accounts=new ChatGptAccounts(QCoreApplication::instance());
    return accounts;
}

ChatGptAccounts::ChatGptAccounts(QObject *parent):QObject(parent) {
    QSettings settings;
    readPreferences(settings);
    m_pollTimer.setInterval(75);
    connect(&m_pollTimer,&QTimer::timeout,this,&ChatGptAccounts::poll);
    connect(&m_vault,&CredentialStore::finished,this,
            [this](quint64 id,const QString &,const QString &secret,const QString &error) {
        vaultFinished(id,secret,error);
    },Qt::QueuedConnection);
}

QVariantMap ChatGptAccounts::selected() const {
    for(const auto &entry:m_accounts) {
        if(::accountId(entry)==m_selected)return entry.toMap();
    }
    return {};
}

QVariantList ChatGptAccounts::models() const {
    return selected().value(QStringLiteral("models")).toList();
}

QString ChatGptAccounts::model() const {
    return selected().value(QStringLiteral("model")).toString();
}

bool ChatGptAccounts::connected() const {
    return selected().value(QStringLiteral("connected")).toBool();
}

bool ChatGptAccounts::busy() const {
    return bool(m_auth) || m_intent!=VaultIntent::None;
}

void ChatGptAccounts::setStatus(const QString &message) {
    m_status=message;
    emit changed();
}

bool ChatGptAccounts::readPreferences(QSettings &settings) {
    settings.beginGroup(settingsGroup);
    const auto accounts=settings.value(QStringLiteral("accounts")).toList();
    const auto selected=settings.value(QStringLiteral("selected")).toString();
    const bool useForChat=settings.value(QStringLiteral("useForChat"),false).toBool();
    const bool useForSelection=settings.value(QStringLiteral("useForSelection"),false).toBool();
    const bool useForLayers=settings.value(QStringLiteral("useForLayeredSummaries"),false).toBool();
    const bool useForDocument=settings.value(QStringLiteral("useForWholeDocument"),false).toBool();
    settings.endGroup();
    const bool changed=accounts!=m_accounts || selected!=m_selected || useForChat!=m_useForChat
        || useForSelection!=m_useForSelection || useForLayers!=m_useForLayeredSummaries
        || useForDocument!=m_useForWholeDocument;
    m_accounts=accounts;
    m_selected=selected;
    m_useForChat=useForChat;
    m_useForSelection=useForSelection;
    m_useForLayeredSummaries=useForLayers;
    m_useForWholeDocument=useForDocument;
    return changed;
}

bool ChatGptAccounts::reloadPreferences() {
    QSettings settings;
    settings.sync();
    if(settings.status()!=QSettings::NoError) {
        setStatus(tr("Could not load the ChatGPT account preferences."));
        return false;
    }
    if(readPreferences(settings)) {
        m_vault.clearSession();
        emit profileChanged();
        emit changed();
    }
    return true;
}

bool ChatGptAccounts::writePreference(const QString &key,const QVariant &value) {
    QSettings settings;
    settings.setValue(settingsGroup+QLatin1Char('/')+key,value);
    settings.sync();
    if(settings.status()!=QSettings::NoError)return false;
    return reloadPreferences();
}

void ChatGptAccounts::selectAccount(const QString &id) {
    if(busy() || !reloadPreferences() || id==m_selected)return;
    const auto exists=std::any_of(m_accounts.cbegin(),m_accounts.cend(),
                                  [&](const auto &entry){return ::accountId(entry)==id;});
    if(!exists)return;
    const bool saved=writePreference(QStringLiteral("selected"),id);
    setStatus(saved?QString{}:tr("Could not save the selected ChatGPT account."));
}

void ChatGptAccounts::selectModel(const QString &id) {
    if(busy() || id.isEmpty() || !reloadPreferences() || id==model())return;
    const auto available=models();
    const auto exists=std::any_of(available.cbegin(),available.cend(),[&](const auto &entry) {
        return entry.toMap().value(QStringLiteral("id")).toString()==id;
    });
    if(!exists)return;
    const bool saved=writeAccount({{QStringLiteral("id"),m_selected},{QStringLiteral("model"),id}},false);
    setStatus(saved?QString{}:tr("Could not save the selected ChatGPT model."));
}

void ChatGptAccounts::setUseForChat(bool value) {
    setUsagePreference(QStringLiteral("useForChat"),m_useForChat,value);
}

void ChatGptAccounts::setUseForSelection(bool value) {
    setUsagePreference(QStringLiteral("useForSelection"),m_useForSelection,value);
}
void ChatGptAccounts::setUseForLayeredSummaries(bool value) {
    setUsagePreference(QStringLiteral("useForLayeredSummaries"),m_useForLayeredSummaries,value);
}

void ChatGptAccounts::setUseForWholeDocument(bool value) {
    setUsagePreference(QStringLiteral("useForWholeDocument"),m_useForWholeDocument,value);
}

void ChatGptAccounts::setUsagePreference(const QString &key,bool &current,bool value) {
    if(busy() || !reloadPreferences() || current==value || (value && (!connected() || model().isEmpty())))return;
    const bool saved=writePreference(key,value);
    if(!saved)emit profileChanged();
    setStatus(saved?QString{}:tr("Could not save the ChatGPT usage preference."));
}

void ChatGptAccounts::beginSignIn(bool addAccount) {
    if(busy() || !reloadPreferences())return;
    QSettings settings;
    const auto key=settingsGroup+QStringLiteral("/hostId");
    auto host=settings.value(key).toString();
    if(host.isEmpty()) {
        host=QStringLiteral("urn:uuid:")+newId();
        settings.setValue(key,host);
        settings.sync();
        if(settings.status()!=QSettings::NoError) {
            setStatus(tr("Could not save the sign-in host identifier."));
            return;
        }
    }
    const auto expected=addAccount?QVariantMap{}:selected();
    m_signInSubject=expected.value(QStringLiteral("subject")).toString();
    m_registration=expected.value(QStringLiteral("clientId")).toString();
    if(m_registration.isEmpty())m_registration=settings.value(pendingRegistrationKey).toString();
    QJsonObject body{{QStringLiteral("host_id"),host}};
    if(!m_registration.isEmpty()) {
        body.insert(QStringLiteral("client_id"),m_registration);
        if(!m_signInSubject.isEmpty()) {
            body.insert(QStringLiteral("expected_subject"),m_signInSubject);
            body.insert(QStringLiteral("email_hint"),expected.value(QStringLiteral("email")).toString());
        }
    }
    const auto request=QJsonDocument(body).toJson(QJsonDocument::Compact);
    LyraReaderBuffer url{},error{};
    m_worker=WorkerIntent::SignIn;
    m_auth.reset(lyra_reader_desktop_chatgpt_auth_begin(
        reinterpret_cast<const std::uint8_t *>(request.constData()),std::size_t(request.size()),&url,&error));
    const auto target=QUrl::fromEncoded(takeBuffer(url),QUrl::StrictMode);
    const auto failure=QString::fromUtf8(takeBuffer(error));
    if(!m_auth) {
        setStatus(failure.isEmpty()?tr("Could not start ChatGPT sign-in."):failure);
        return;
    }
    if(!target.isValid() || target.scheme()!=QStringLiteral("https")
       || target.host()!=QStringLiteral("auth.openai.com")
       || target.path()!=QStringLiteral("/api/accounts/authorize")
       || !QDesktopServices::openUrl(target)) {
        m_auth.reset();
        setStatus(tr("Could not open the browser for ChatGPT sign-in."));
        return;
    }
    m_pollTimer.start();
    setStatus(tr("Finish signing in to ChatGPT in your browser."));
}

void ChatGptAccounts::cancelSignIn() {
    if(!signingIn())return;
    m_pollTimer.stop();
    m_auth.reset();
    setStatus(tr("Sign-in cancelled."));
}

void ChatGptAccounts::poll() {
    if(!m_auth)return;
    LyraReaderBuffer result{},error{};
    const auto state=lyra_reader_desktop_chatgpt_auth_poll(m_auth.get(),&result,&error);
    const auto bytes=takeBuffer(result);
    const auto failure=QString::fromUtf8(takeBuffer(error));
    if(!state)return;
    m_pollTimer.stop();
    m_auth.reset();
    if(m_worker==WorkerIntent::Revoke) {
        const auto result=QJsonDocument::fromJson(bytes).object();
        removeFromVault(state==1 && result.value(QStringLiteral("revoked")).toBool());
        return;
    }
    if(m_worker==WorkerIntent::Refresh) {
        const auto updated=QJsonDocument::fromJson(bytes).object();
        const auto token=updated.value(QStringLiteral("access_token")).toString();
        if(state!=1 || token.isEmpty()) {
            finishChat({},failure.isEmpty()?tr("Could not renew the saved ChatGPT session."):failure);
            return;
        }
        m_refreshedToken=token;
        m_intent=VaultIntent::SaveRefresh;
        m_vaultId=m_vault.write(vaultKey(m_selected),QString::fromUtf8(bytes));
        emit changed();
        return;
    }
    if(state!=1) {
        if(m_signInSubject.isEmpty() && !bytes.isEmpty())
            QSettings().setValue(pendingRegistrationKey,QString::fromUtf8(bytes));
        setStatus(failure.isEmpty()?tr("Could not finish ChatGPT sign-in."):failure);
        return;
    }
    const auto reply=QJsonDocument::fromJson(bytes).object();
    const auto client=reply.value(QStringLiteral("client_id")).toString();
    const auto subject=reply.value(QStringLiteral("subject")).toString();
    const auto secret=reply.value(QStringLiteral("credential")).toObject();
    if(client.isEmpty() || subject.isEmpty() || secret.isEmpty()
       || (!m_registration.isEmpty() && client!=m_registration)
       || (!m_signInSubject.isEmpty() && subject!=m_signInSubject)) {
        setStatus(tr("The signed-in account does not match the selected connection."));
        return;
    }
    if(m_signInSubject.isEmpty())QSettings().setValue(pendingRegistrationKey,client);
    QVariantMap candidate;
    for(const auto &entry:m_accounts) {
        const auto account=entry.toMap();
        if(account.value(QStringLiteral("clientId")).toString()==client
           && account.value(QStringLiteral("subject")).toString()==subject) {
            candidate=account;
            break;
        }
    }
    if(candidate.isEmpty()) {
        candidate.insert(QStringLiteral("id"),newId());
        candidate.insert(QStringLiteral("label"),tr("Connection %1").arg(m_accounts.size()+1));
    }
    candidate.insert(QStringLiteral("clientId"),client);
    candidate.insert(QStringLiteral("subject"),subject);
    candidate.insert(QStringLiteral("email"),reply.value(QStringLiteral("email")).toString());
    candidate.insert(QStringLiteral("connected"),true);
    const auto catalog=reply.value(QStringLiteral("models")).toArray().toVariantList();
    candidate.insert(QStringLiteral("models"),catalog);
    const auto preferred=candidate.value(QStringLiteral("model")).toString();
    const bool hasPreferred=std::any_of(catalog.cbegin(),catalog.cend(),[&](const auto &entry) {
        return !preferred.isEmpty() && entry.toMap().value(QStringLiteral("id")).toString()==preferred;
    });
    if(!hasPreferred)candidate.insert(QStringLiteral("model"),catalog.isEmpty()?QString{}:
                                     catalog.first().toMap().value(QStringLiteral("id")).toString());
    if(!lockAccount(::accountId(candidate)))return;
    m_candidate=candidate;
    const auto key=vaultKey(::accountId(m_candidate));
    m_intent=VaultIntent::Save;
    m_vaultId=m_vault.write(key,QString::fromUtf8(QJsonDocument(secret).toJson(QJsonDocument::Compact)));
    m_status=reply.value(QStringLiteral("warning")).toString();
    emit changed();
}

bool ChatGptAccounts::writeAccount(const QVariantMap &fields,bool enrolling) {
    QSettings settings;
    const auto id=::accountId(fields);
    const auto config=QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    const QDir directory(QDir(config).filePath(QStringLiteral("chatgpt-accounts")));
    if(id.isEmpty() || config.isEmpty() || !QDir().mkpath(directory.absolutePath()))return false;
    QLockFile lock(directory.filePath(QStringLiteral("preferences.lock")));
    if(!lock.tryLock(0))return false;
    settings.sync();
    if(settings.status()!=QSettings::NoError)return false;
    const auto roster=settingsGroup+QStringLiteral("/accounts");
    auto accounts=settings.value(roster).toList();
    auto entry=std::find_if(accounts.begin(),accounts.end(),[&](const auto &value){return ::accountId(value)==id;});
    if(entry==accounts.end()) {
        if(!enrolling)return false;
        accounts.append(fields);
    } else {
        auto latest=entry->toMap();
        const auto currentModel=latest.value(QStringLiteral("model")).toString();
        for(auto it=fields.cbegin();it!=fields.cend();++it)latest.insert(it.key(),it.value());
        if(enrolling && !currentModel.isEmpty()) {
            const auto catalog=latest.value(QStringLiteral("models")).toList();
            if(std::any_of(catalog.cbegin(),catalog.cend(),[&](const auto &model) {
                return model.toMap().value(QStringLiteral("id")).toString()==currentModel;
            }))latest.insert(QStringLiteral("model"),currentModel);
        }
        *entry=latest;
    }
    settings.setValue(roster,accounts);
    if(enrolling) {
        settings.setValue(settingsGroup+QStringLiteral("/selected"),id);
        if(settings.value(pendingRegistrationKey)==fields.value(QStringLiteral("clientId")))
            settings.remove(pendingRegistrationKey);
    }
    settings.sync();
    if(settings.status()!=QSettings::NoError)return false;
    lock.unlock();
    return reloadPreferences();
}

void ChatGptAccounts::signOut() {
    if(busy() || !reloadPreferences() || !connected() || !lockAccount(m_selected))return;
    m_vault.clearSession();
    m_intent=VaultIntent::LoadForRevoke;
    m_vaultId=m_vault.read(vaultKey(m_selected));
    emit profileChanged();
    setStatus(tr("Signing out of the selected ChatGPT connection…"));
}

bool ChatGptAccounts::allowsPlan(const QVariantMap &plan,const QString &readingToken) const {
    const auto action=plan.value(QStringLiteral("action")).toString();
    const auto kind=plan.value(QStringLiteral("kind")).toString();
    const auto scope=plan.value(QStringLiteral("reading_scope")).toMap();
    const bool selected=!scope.value(QStringLiteral("selection")).toMap().isEmpty();
    const bool selectionTask=selected && (kind==QStringLiteral("reading_summary_selection") || kind==QStringLiteral("reading_translation"));
    const bool wholeTask=kind==QStringLiteral("reading_summary") || kind==QStringLiteral("summary_synthesis")
        || (kind==QStringLiteral("reading_translation") && !selected);
    const bool layered=action==QStringLiteral("SummarizeAbstract") || action==QStringLiteral("SummarizeSection")
        || action==QStringLiteral("SummarizePageLine");
    const bool allowed=readingToken.isEmpty()
        ? (action==QStringLiteral("DocumentChat") && m_useForChat)
        || (m_useForSelection && (selectionTask || kind==QStringLiteral("inplace_translation")))
        || (wholeTask && m_useForWholeDocument)
        || action==QStringLiteral("RegionQuestion") || (layered && m_useForLayeredSummaries)
        : action==QStringLiteral("SummarizeDocument"); // Reading has its own explicit ChatGPT preview.
    return allowed && connected() && plan.value(QStringLiteral("chatgpt_account")).toString()==m_selected
        && plan.value(QStringLiteral("model")).toString()==model();
}

bool ChatGptAccounts::send(ReaderController *reader,const QVariantMap &plan,const QString &readingToken) {
    const QPointer<ReaderController> alive(reader);
    if(!alive || busy() || !reloadPreferences() || !alive || busy() || !allowsPlan(plan,readingToken))return false;
    const auto prepared=readingToken.isEmpty()?reader->aiState():reader->documentReading();
    if(prepared.value(QStringLiteral("plan")).toMap()!=plan || !lockAccount(m_selected))return false;
    m_vault.clearSession();
    m_pendingReader=alive;
    m_pendingPlan=plan;
    m_pendingReadingToken=readingToken;
    m_intent=VaultIntent::LoadForChat;
    m_vaultId=m_vault.read(vaultKey(m_selected));
    emit changed();
    return true;
}

bool ChatGptAccounts::lockAccount(const QString &id) {
    const auto config=QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    const QDir dir(QDir(config).filePath(QStringLiteral("chatgpt-accounts")));
    if(id.isEmpty() || config.isEmpty() || !QDir().mkpath(dir.absolutePath())) {
        setStatus(tr("Could not prepare the ChatGPT account lock."));
        return false;
    }
    const auto hash=QString::fromLatin1(QCryptographicHash::hash(id.toUtf8(),QCryptographicHash::Sha256).toHex());
    auto lock=std::make_unique<QLockFile>(dir.filePath(QStringLiteral("chatgpt-")+hash+QStringLiteral(".lock")));
    lock->setStaleLockTime(0);
    if(!lock->tryLock(0)) {
        setStatus(tr("This ChatGPT account is being updated. Try again in a moment."));
        return false;
    }
    m_accountLock=std::move(lock);
    return true;
}

bool ChatGptAccounts::startSessionWork(WorkerIntent intent,const QJsonObject &credential) {
    const auto operation=intent==WorkerIntent::Refresh?QStringLiteral("refresh"):QStringLiteral("revoke");
    const QJsonObject data{
        {QStringLiteral("operation"),operation},
        {QStringLiteral("client_id"),selected().value(QStringLiteral("clientId")).toString()},
        {QStringLiteral("credential"),credential},
    };
    const auto request=QJsonDocument(data).toJson(QJsonDocument::Compact);
    LyraReaderBuffer error{};
    m_worker=intent;
    m_auth.reset(lyra_reader_desktop_chatgpt_session_begin(
        reinterpret_cast<const std::uint8_t *>(request.constData()),std::size_t(request.size()),&error));
    const auto failure=QString::fromUtf8(takeBuffer(error));
    if(!m_auth) {
        setStatus(failure.isEmpty()?tr("Could not start the ChatGPT session operation."):failure);
        return false;
    }
    m_pollTimer.start();
    emit changed();
    return true;
}

void ChatGptAccounts::removeFromVault(bool revoked) {
    m_revoked=revoked;
    m_intent=VaultIntent::Remove;
    m_vaultId=m_vault.remove(vaultKey(m_selected));
    emit changed();
}

void ChatGptAccounts::finishChat(const QString &token,const QString &error) {
    // Keep this connection locked until the final preference check and dispatch finish.
    const auto credentialLock=std::move(m_accountLock);
    m_vault.clearSession();
    m_refreshedToken.clear();
    const auto reader=m_pendingReader;
    m_pendingReader.clear();
    const auto plan=std::exchange(m_pendingPlan,{});
    const auto readingToken=std::exchange(m_pendingReadingToken,{});
    if(error.isEmpty() && reader && reloadPreferences() && reader && allowsPlan(plan,readingToken)
       && reader->startChatGptRequest(m_selected,token,plan,readingToken)) {
        setStatus({});
        return;
    }
    setStatus(error.isEmpty()?tr("The request changed or the document is busy. Preview and Send again."):error);
    if(reader)emit chatRequestFailed(reader,m_status);
}

void ChatGptAccounts::vaultFinished(quint64 id,const QString &secret,const QString &error) {
    if(!m_vaultId || id!=m_vaultId)return;
    m_vaultId=0;
    const auto intent=std::exchange(m_intent,VaultIntent::None);
    if(!error.isEmpty()) {
        const auto message=tr("Could not access the ChatGPT session in the system keychain.");
        m_candidate.clear();
        if(intent==VaultIntent::LoadForChat || intent==VaultIntent::SaveRefresh) {
            finishChat({},message);
        } else {
            m_accountLock.reset();
            setStatus(message);
        }
        return;
    }
    if(intent==VaultIntent::Save) {
        m_vault.clearSession();
        if(m_status.isEmpty())m_status=tr("ChatGPT plan usage is enabled for this connection.");
        const bool saved=writeAccount(std::exchange(m_candidate,{}),true);
        m_accountLock.reset();
        setStatus(saved?m_status:tr("Could not save the ChatGPT account preferences."));
    } else if(intent==VaultIntent::Remove) {
        const bool saved=writeAccount({{QStringLiteral("id"),m_selected},{QStringLiteral("connected"),false}},false);
        m_accountLock.reset();
        if(!saved) {
            setStatus(tr("The credential was removed. Could not update the ChatGPT account preferences."));
            return;
        }
        setStatus(m_revoked?tr("Signed out."):
            tr("Signed out locally. Disconnect LyraReader in ChatGPT Settings to end remote access."));
    } else if(intent==VaultIntent::LoadForRevoke) {
        const auto session=QJsonDocument::fromJson(secret.toUtf8()).object();
        if(secret.isEmpty())removeFromVault(true);
        else if(session.isEmpty() || !startSessionWork(WorkerIntent::Revoke,session))removeFromVault(false);
    } else if(intent==VaultIntent::SaveRefresh) {
        finishChat(std::exchange(m_refreshedToken,{}));
    } else if(intent==VaultIntent::LoadForChat) {
        const auto session=QJsonDocument::fromJson(secret.toUtf8()).object();
        const auto token=session.value(QStringLiteral("access_token")).toString();
        const auto expires=session.value(QStringLiteral("expires_at_unix")).toInteger();
        const auto scopes=session.value(QStringLiteral("scopes")).toArray();
        const bool authorized=scopes.contains(QStringLiteral("resource.invoke")) &&
            scopes.contains(QStringLiteral("chatgpt.tokens.use.direct"));
        if(authorized && !token.isEmpty() && expires>QDateTime::currentSecsSinceEpoch()+45) {
            finishChat(token);
        } else if(session.isEmpty() || !startSessionWork(WorkerIntent::Refresh,session)) {
            finishChat({},tr("The saved ChatGPT session expired. Sign in again in Settings."));
        }
    }
}
