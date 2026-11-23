#pragma once
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QVariantMap>
#include <QWindow>

class AuxiliaryWindowOwner : public QObject {
    Q_OBJECT
    Q_PROPERTY(QQuickWindow *window READ window WRITE setWindow NOTIFY windowChanged)
public:
    explicit AuxiliaryWindowOwner(QObject *parent=nullptr):QObject(parent){}
    QQuickWindow *window() const { return m_window.data(); }
    void setWindow(QQuickWindow *window);
    bool hasSubmittedFrame() const { return m_hasSubmittedFrame; }
signals:
    void windowChanged();
    void firstFrameSubmitted();
private:
    void observeFirstFrame();
    QPointer<QQuickWindow> m_window;
    QMetaObject::Connection m_visibility,m_frame;
    quint64 m_observation=0;
    bool m_hasSubmittedFrame=false;
};

// Native secondary-window policy. The compositor retains the final layout decision.
class AuxiliaryWindowPolicy : public QObject {
    Q_OBJECT
public:
    explicit AuxiliaryWindowPolicy(QObject *parent=nullptr):QObject(parent){}
    Q_INVOKABLE bool prepare(QWindow *window,QWindow *owner,const QVariantMap &saved,int width,int height);
    Q_INVOKABLE void present(AuxiliaryWindowOwner *ownerFrames);
    Q_INVOKABLE void cancelPresentation();
    Q_INVOKABLE QVariantMap geometry() const;
    Q_INVOKABLE void returnFocus();
    static QSize boundedSize(const QSizeF &requested,const QRect &available);
private:
    void showPreparedWindow();
    QPointer<QWindow> m_window,m_owner;
    QSize m_preferredSize,m_initialSize;
    QMetaObject::Connection m_ownerVisibility,m_ownerDestroyed,m_ownerFrame;
    quint64 m_presentation=0;
};
