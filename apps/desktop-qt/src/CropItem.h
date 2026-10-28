#pragma once
#include "RenderBudget.h"
#include "RasterJobs.h"
#include <QQuickItem>
#include <QTimer>
#include <QUrl>

// Preview regions use the same accounting and render pool as the PDF canvas.
class CropItem:public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(int status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString error READ error NOTIFY statusChanged)
    Q_PROPERTY(QSize pixelSize READ pixelSize NOTIFY statusChanged)
    Q_PROPERTY(QString paperAppearance READ paperAppearance WRITE setPaperAppearance NOTIFY paperAppearanceChanged)
    Q_PROPERTY(bool resourceActive READ resourceActive WRITE setResourceActive NOTIFY resourceActiveChanged)
public:
    explicit CropItem(QQuickItem *parent=nullptr);
    ~CropItem()override;
    QUrl source()const{return m_source;}
    int status()const{return m_status;}
    QString error()const{return m_error;}
    QSize pixelSize()const{return m_image.pixels.size();}
    QString paperAppearance()const{return m_paper;}
    bool resourceActive()const{return m_resourceActive;}
    void setSource(const QUrl &source);
    void setPaperAppearance(const QString &paper);
    void setResourceActive(bool active);
signals:
    void sourceChanged();void statusChanged();void paperAppearanceChanged();void resourceActiveChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *,UpdatePaintNodeData *)override;
    void itemChange(ItemChange,const ItemChangeData &)override;
private:
    void request();void invalidate();void setStatus(int status);void syncBudget();
    bool active()const;
    void visibilityUpdated();
    QUrl m_source;QString m_paper=QStringLiteral("original");
    QString m_error;
    ResidentImage m_image;
    QTimer m_timer;
    RasterJobs::Handle m_job;
    quint64 m_epoch=0;
    qint64 m_target=0;
    int m_status=0;
    bool m_resourceActive=true;
    QMetaObject::Connection m_visibilityConnection;
};
