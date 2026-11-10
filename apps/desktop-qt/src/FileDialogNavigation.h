#pragma once
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>

// Repairs only the optional Qt Quick fallback; native system panels remain untouched.
class FileDialogNavigation : public QObject {
    Q_OBJECT
public:
    explicit FileDialogNavigation(QObject *parent=nullptr);
    Q_INVOKABLE void track(QObject *dialog,QQuickWindow *owner);
private slots:
    void refresh();
private:
    QPointer<QObject> m_dialog;
    QPointer<QQuickWindow> m_owner;
    QPointer<QQuickItem> m_list;
    QPointer<QObject> m_model;
    bool m_initializeMissing=false;
};
