#include "AuditController.h"
#include "lyra_reader_desktop.h"
#include <QDateTime>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QtConcurrentRun>

void AuditController::reload(){if(!m_busy)request(QStringLiteral("audit_records"));}
bool AuditController::clear(const QString &fingerprint) {
    if(m_busy)return false;
    if(fingerprint.isEmpty() || fingerprint!=m_state.value(QStringLiteral("fingerprint")).toString()) {
        m_error=tr("Refresh and review the current audit snapshot before clearing it.");emit changed();return false;
    }
    request(QStringLiteral("audit_clear"),fingerprint);return true;
}
void AuditController::request(const QString &operation,const QString &fingerprint) {
    struct Result {QVariantMap state;QString metadata,error;};
    const QJsonObject input=fingerprint.isEmpty() ? QJsonObject{{"op",operation}} : QJsonObject{{"op",operation},{"fingerprint",fingerprint}};
    const auto bytes=QJsonDocument(input).toJson(QJsonDocument::Compact);
    m_busy=true;m_error.clear();emit changed();
    auto *watcher=new QFutureWatcher<Result>(this);
    connect(watcher,&QFutureWatcher<Result>::finished,this,[this,watcher]{
        const auto result=watcher->result();watcher->deleteLater();m_busy=false;m_error=result.error;
        if(m_error.isEmpty()){m_state=result.state;m_metadata=result.metadata;}
        emit changed();
    });
    watcher->setFuture(QtConcurrent::run([bytes]{
        Result result;LyraReaderBuffer output{},error{};
        const auto take=[](LyraReaderBuffer buffer){const auto text=QString::fromUtf8(reinterpret_cast<const char *>(buffer.data),qsizetype(buffer.len));lyra_reader_desktop_buffer_free(buffer);return text;};
        // The documented global audit operations accept a null document. The request only
        // contains a fixed operation and the reviewed metadata fingerprint, never credentials.
        if(!lyra_reader_desktop_command(nullptr,reinterpret_cast<const std::uint8_t *>(bytes.constData()),bytes.size(),&output,&error)){result.error=take(error);return result;}
        const auto encoded=QByteArray(reinterpret_cast<const char *>(output.data),qsizetype(output.len));
        lyra_reader_desktop_buffer_free(output);
        QJsonParseError parse{};const auto response=QJsonDocument::fromJson(encoded,&parse);
        const auto state=response.object().value(QStringLiteral("result")).toObject();
        if(parse.error!=QJsonParseError::NoError || state.value(QStringLiteral("version")).toInt()!=1 || !state.value(QStringLiteral("records")).isArray() || state.value(QStringLiteral("fingerprint")).toString().size()!=64) {
            result.error=tr("The local audit service returned an invalid snapshot.");return result;
        }
        // Copy the validated transport bytes, preserving integers outside JavaScript's exact
        // number range. The native list is a presentation view, not a cache re-encoder.
        result.metadata=QString::fromUtf8(encoded);result.state=state.toVariantMap();
        auto rows=result.state.value(QStringLiteral("records")).toList();
        for(auto &value:rows){auto row=value.toMap();const auto date=QDateTime::fromMSecsSinceEpoch(row.value(QStringLiteral("at_unix_ms")).toLongLong()).toUTC();row.insert(QStringLiteral("time_label"),date.isValid()?date.toString(Qt::ISODateWithMs):tr("Timestamp unavailable"));value=row;}
        result.state.insert(QStringLiteral("records"),rows);return result;
    }));
}
