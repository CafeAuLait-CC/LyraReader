#pragma once
#include "RenderBudget.h"
#include "RasterJobs.h"
#include <QQuickItem>
#include <QPointer>
#include <QTimer>
#include <QUrl>
class PageItem;
Q_MOC_INCLUDE("PageItem.h")

// Preview regions use the same accounting and render pool as the PDF canvas.
class CropItem:public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(QUrl source READ source WRITE setSource NOTIFY sourceChanged)
    Q_PROPERTY(int status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString error READ error NOTIFY statusChanged)
    Q_PROPERTY(QSize pixelSize READ pixelSize NOTIFY statusChanged)
    Q_PROPERTY(QString paperAppearance READ paperAppearance WRITE setPaperAppearance NOTIFY paperAppearanceChanged)
    Q_PROPERTY(bool resourceActive READ resourceActive WRITE setResourceActive NOTIFY resourceActiveChanged)
    Q_PROPERTY(bool rasterDemandPaused READ rasterDemandPaused WRITE setRasterDemandPaused NOTIFY rasterDemandPausedChanged)
    Q_PROPERTY(PageItem *paperMap READ paperMap WRITE setPaperMap NOTIFY paperGeometryChanged)
    Q_PROPERTY(QRectF paperRect READ paperRect WRITE setPaperRect NOTIFY paperGeometryChanged)
    Q_PROPERTY(double paperZoom READ paperZoom WRITE setPaperZoom NOTIFY paperGeometryChanged)
    Q_PROPERTY(QPointF paperOrigin READ paperOrigin WRITE setPaperOrigin NOTIFY paperGeometryChanged)
    Q_PROPERTY(QString paperGeometryError READ paperGeometryError NOTIFY paperGeometryChanged)
public:
    explicit CropItem(QQuickItem *parent=nullptr);
    ~CropItem()override;
    QUrl source()const{return m_source;}
    int status()const{return m_status;}
    QString error()const{return m_error;}
    QSize pixelSize()const{return m_image.pixels.size();}
    QString paperAppearance()const{return m_paper;}
    bool resourceActive()const{return m_resourceActive;}
    bool rasterDemandPaused()const{return m_rasterDemandPaused;}
    void setSource(const QUrl &source);
    void setPaperAppearance(const QString &paper);
    void setResourceActive(bool active);
    void setRasterDemandPaused(bool paused);
    // Page-owned artwork: source bounds and displayed parent origin are points, before zoom.
    // The page is borrowed only during scene sync; geometry changes never invalidate pixels.
    PageItem *paperMap()const;
    QRectF paperRect()const{return m_paperRect;}
    double paperZoom()const{return m_paperZoom;}
    QPointF paperOrigin()const{return m_paperOrigin;}
    QString paperGeometryError()const{return m_geometryError;}
    void setPaperMap(PageItem *page);
    void setPaperRect(const QRectF &rect);
    void setPaperZoom(double zoom);
    void setPaperOrigin(const QPointF &origin);
signals:
    void sourceChanged();void statusChanged();void paperAppearanceChanged();void resourceActiveChanged();
    void paperGeometryChanged();
    void rasterDemandPausedChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *,UpdatePaintNodeData *)override;
    void itemChange(ItemChange,const ItemChangeData &)override;
private:
    void request();void invalidate();void setStatus(int status);void syncBudget();
    bool active()const;
    void visibilityUpdated();void scheduleVisibilityUpdate();
    void geometryUpdated();void reportGeometryError(const QString &error);
    QUrl m_source;QString m_paper=QStringLiteral("original");
    QString m_error;
    ResidentImage m_image;
    QTimer m_timer;
    RasterJobs::Handle m_job;
    quint64 m_epoch=0;
    qint64 m_target=0;
    int m_status=0;
    bool m_resourceActive=true;
    bool m_rasterDemandPaused=false,m_deferredRequest=false;
    bool m_visibilityPending=false,m_lastActive=false;
    QMetaObject::Connection m_visibilityConnection;
    QPointer<PageItem> m_paperMap;
    QVector<QMetaObject::Connection> m_paperConnections;
    QRectF m_paperRect;
    QPointF m_paperOrigin;
    double m_paperZoom=1;
    quint64 m_geometryEpoch=0;
    QString m_geometryError;
};
