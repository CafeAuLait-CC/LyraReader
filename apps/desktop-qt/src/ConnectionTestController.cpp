#include "ConnectionTestController.h"
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QScopeGuard>
#include <QStringList>
#include <QtConcurrentRun>

ConnectionTestController::Outcome ConnectionTestController::command(const Handle &handle,const QVariantMap &input) {
    Outcome result;result.handle=handle;
    const auto bytes=QJsonDocument(QJsonObject::fromVariantMap(input)).toJson(QJsonDocument::Compact);
    LyraReaderBuffer output{},error{};
    const auto cleanup=qScopeGuard([&]{lyra_reader_desktop_buffer_free(output);lyra_reader_desktop_buffer_free(error);});
    if(!lyra_reader_desktop_connection_test_command(handle.get(),reinterpret_cast<const std::uint8_t *>(bytes.constData()),std::size_t(bytes.size()),&output,&error)) {
        result.error=error.data ? QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len)) : tr("The connection test could not continue.");return result;
    }
    QJsonParseError parse;
    const auto response=QJsonDocument::fromJson(QByteArray::fromRawData(reinterpret_cast<const char *>(output.data),qsizetype(output.len)),&parse);
    const auto state=response.object().toVariantMap();
    const QStringList phases{"idle","preview","running","success","failed"};
    if(parse.error!=QJsonParseError::NoError || !response.isObject() || !phases.contains(state.value("phase").toString()))result.error=tr("The connection test returned an invalid state.");
    else result.state=state;
    return result;
}
ConnectionTestController::ConnectionTestController(CredentialStore *credentials,QObject *parent):QObject(parent),m_credentials(credentials) {
    m_poll.setInterval(30);
    connect(&m_poll,&QTimer::timeout,this,&ConnectionTestController::poll);
    if(credentials)connect(credentials,&CredentialStore::finished,this,[this](quint64 id,const QString &operation,const QString &key,const QString &error){
        if(operation!="read" || id!=m_pendingLookup || !m_busy || !m_handle)return;
        m_pendingLookup=0;
        if(!error.isEmpty())fail(error);else startRequest(key);
    },Qt::QueuedConnection);
}
ConnectionTestController::~ConnectionTestController(){cancel();}
void ConnectionTestController::update(QVariantMap state,bool busy) {
    if(m_state==state && m_busy==busy)return;
    m_state=std::move(state);m_busy=busy;emit changed();
}
void ConnectionTestController::cancel() {
    ++m_epoch;m_pendingLookup=0;m_pollPending=false;m_poll.stop();
    if(m_handle)lyra_reader_desktop_connection_test_cancel(m_handle.get());
    m_handle.reset();m_account.clear();update({{"phase","idle"}},false);
}
void ConnectionTestController::fail(const QString &message,const QString &code) {
    if(m_handle)lyra_reader_desktop_connection_test_cancel(m_handle.get());
    m_handle.reset();m_poll.stop();m_pendingLookup=0;m_pollPending=false;
    update({{"phase","failed"},{"message",message},{"code",code}},false);
}
void ConnectionTestController::run(const QVariantMap &input,std::function<void(Outcome)> then) {
    const auto epoch=m_epoch;const auto handle=m_handle;
    auto *watcher=new QFutureWatcher<Outcome>(this);
    connect(watcher,&QFutureWatcher<Outcome>::finished,this,[this,watcher,epoch,then=std::move(then)]{
        auto result=watcher->result();watcher->deleteLater();
        if(epoch!=m_epoch)return;
        if(!result.error.isEmpty()){fail(result.error);return;}
        then(std::move(result));
    });
    watcher->setFuture(QtConcurrent::run([handle,input]{return command(handle,input);}));
}
void ConnectionTestController::start(const QString &baseUrl,const QString &model,const QString &typedKey) {
    cancel();
    // UTF-16 units can expand to six JSON escape bytes each. Reserve an eighth
    // of the native frame cap before allocating JSON, leaving room for its keys.
    // Short-circuit the individual bounds before adding their lengths.
    constexpr auto maxCharacters=qsizetype(LYRA_READER_CONNECTION_TEST_MAX_COMMAND_BYTES/8);
    if(baseUrl.size()>maxCharacters || model.size()>maxCharacters || typedKey.size()>maxCharacters
            || baseUrl.size()+model.size()+typedKey.size()>maxCharacters) {
        fail(tr("The connection test settings are too long."),QStringLiteral("InvalidSettings"));return;
    }
    LyraReaderBuffer error{};auto *raw=lyra_reader_desktop_connection_test_new(&error);
    const auto message=error.data ? QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len)) : tr("The connection test could not start.");
    lyra_reader_desktop_buffer_free(error);
    if(!raw){fail(message);return;}
    m_handle=Handle(raw,lyra_reader_desktop_connection_test_free);m_account=baseUrl;
    const auto handle=m_handle;
    update({{"phase","preparing"}},true);
    if(m_handle!=handle || !m_busy)return;
    // Only the fixed plan is prepared first. An invalid address/model must not
    // prompt the vault, and a cancelled prepare must never consume a late key.
    run({{"op","prepare"},{"base_url",baseUrl},{"model",model}},[this,key=typedKey.trimmed()](Outcome result){
        if(result.state.value("phase").toString()!="preview"){update(result.state,false);if(m_handle==result.handle)m_handle.reset();return;}
        update(result.state,true);
        if(m_handle!=result.handle || !m_busy)return;
        if(!key.isEmpty())startRequest(key);
        else if(!m_credentials)fail(tr("The system credential store is unavailable."));
        else {m_pendingLookup=m_credentials->read(m_account);auto state=m_state;state.insert("phase","credential");update(state,true);}
    });
}
void ConnectionTestController::startRequest(QString key) {
    if(!m_handle || !m_busy)return;
    run({{"op","start"},{"api_key",std::move(key)}},[this](Outcome result){
        const bool running=result.state.value("phase").toString()=="running";
        update(result.state,running);
        if(m_handle!=result.handle)return;
        if(running)m_poll.start();else m_handle.reset();
    });
}
void ConnectionTestController::poll() {
    if(m_pollPending || !m_handle || m_state.value("phase").toString()!="running")return;
    m_pollPending=true;
    run({{"op","poll"}},[this](Outcome result){
        m_pollPending=false;const bool running=result.state.value("phase").toString()=="running";
        update(result.state,running);
        if(m_handle!=result.handle)return;
        if(!running){m_poll.stop();m_handle.reset();}
    });
}
