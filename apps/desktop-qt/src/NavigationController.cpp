#include "NavigationController.h"
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>

namespace {
QByteArray take(LyraReaderBuffer buffer){const QByteArray data(reinterpret_cast<const char *>(buffer.data),qsizetype(buffer.len));lyra_reader_desktop_buffer_free(buffer);return data;}
}
NavigationController::NavigationController(QObject *parent):QObject(parent) {
    LyraReaderBuffer error{};m_history=lyra_reader_desktop_history_new(&error);
    m_error=QString::fromUtf8(take(error));
    if(m_history)command(QStringLiteral("snapshot"));
    if(auto *application=qobject_cast<QGuiApplication *>(QCoreApplication::instance()))
        connect(application,&QGuiApplication::focusWindowChanged,this,[this]{emit focusChanged();});
}
NavigationController::~NavigationController(){lyra_reader_desktop_history_free(m_history);}
bool NavigationController::keyboardFocus()const {
    const auto *application=qobject_cast<QGuiApplication *>(QCoreApplication::instance());
    return application && m_window && application->focusWindow()==m_window;
}
bool NavigationController::record(const QVariantMap &location){command(QStringLiteral("record"),location);return m_error.isEmpty();}
QVariantMap NavigationController::back(const QVariantMap &current){return command(QStringLiteral("back"),current);}
QVariantMap NavigationController::forward(const QVariantMap &current){return command(QStringLiteral("forward"),current);}
void NavigationController::clear(){command(QStringLiteral("clear"));}
QVariantMap NavigationController::command(const QString &operation,const QVariantMap &location) {
    QJsonObject request{{"op",operation}};if(!location.isEmpty())request.insert("location",QJsonObject::fromVariantMap(location));
    const auto bytes=QJsonDocument(request).toJson(QJsonDocument::Compact);LyraReaderBuffer output{},error{};
    if(!lyra_reader_desktop_history_command(m_history,reinterpret_cast<const std::uint8_t *>(bytes.constData()),bytes.size(),&output,&error)) {
        m_error=QString::fromUtf8(take(error));lyra_reader_desktop_buffer_free(output);emit changed();return {};
    }
    QJsonParseError parse{};const auto result=QJsonDocument::fromJson(take(output),&parse).object();
    lyra_reader_desktop_buffer_free(error);const auto state=result.value("state").toObject();
    if(parse.error!=QJsonParseError::NoError || !state.value("back").isArray() || !state.value("forward").isArray() || state.value("limit").toInt()<=0) {
        m_error=tr("The navigation service returned an invalid history snapshot.");emit changed();return {};
    }
    m_error.clear();m_state=state.toVariantMap();emit changed();return result.value("target").toObject().toVariantMap();
}
