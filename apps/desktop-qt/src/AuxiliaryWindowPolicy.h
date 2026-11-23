#pragma once
#include <QObject>
#include <QPointer>
#include <QVariantMap>
#include <QWindow>

// Native secondary-window policy. The compositor retains the final layout decision.
class AuxiliaryWindowPolicy : public QObject {
    Q_OBJECT
public:
    explicit AuxiliaryWindowPolicy(QObject *parent=nullptr):QObject(parent){}
    Q_INVOKABLE bool prepare(QWindow *window,QWindow *owner,const QVariantMap &saved,int width,int height);
    Q_INVOKABLE void present();
    Q_INVOKABLE void cancelPresentation();
    Q_INVOKABLE QVariantMap geometry() const;
    Q_INVOKABLE void returnFocus();
    static QSize boundedSize(const QSizeF &requested,const QRect &available);
private:
    void showPreparedWindow();
    QPointer<QWindow> m_window,m_owner;
    QMetaObject::Connection m_ownerVisibility,m_ownerDestroyed,m_ownerFrame;
    quint64 m_presentation=0;
};
