#pragma once
#include "lyra_reader_desktop.h"
#include <QObject>
#include <QVariantMap>
#include <QPointer>
#include <QWindow>

// A published mirror of shared Rust history; this shell never pushes/pops/trims stacks.
class NavigationController:public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QWindow *window READ window WRITE setWindow NOTIFY focusChanged)
    Q_PROPERTY(bool keyboardFocus READ keyboardFocus NOTIFY focusChanged)
public:
    explicit NavigationController(QObject *parent=nullptr);
    ~NavigationController()override;
    QVariantMap state()const{return m_state;}
    QString error()const{return m_error;}
    QWindow *window()const{return m_window;}
    void setWindow(QWindow *window){m_window=window;emit focusChanged();}
    bool keyboardFocus()const;
    Q_INVOKABLE bool record(const QVariantMap &location);
    Q_INVOKABLE QVariantMap back(const QVariantMap &current);
    Q_INVOKABLE QVariantMap forward(const QVariantMap &current);
    Q_INVOKABLE void clear();
signals:
    void changed();
    void focusChanged();
private:
    QVariantMap command(const QString &operation,const QVariantMap &location={});
    LyraReaderDesktopHistory *m_history=nullptr;
    QVariantMap m_state;
    QString m_error;
    QPointer<QWindow> m_window;
};
