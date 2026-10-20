#pragma once
#include "ReaderController.h"
#include "RenderBudget.h"
#include <QQuickItem>
#include <QPointer>
#include <QTimer>

class PageItem : public QQuickItem {
    Q_OBJECT
    Q_PROPERTY(ReaderController *controller READ controller WRITE setController NOTIFY controllerChanged)
    Q_PROPERTY(int pageIndex READ pageIndex WRITE setPageIndex NOTIFY pageIndexChanged)
    Q_PROPERTY(double rasterScale READ rasterScale WRITE setRasterScale NOTIFY rasterScaleChanged)
    Q_PROPERTY(QString paperAppearance READ paperAppearance WRITE setPaperAppearance NOTIFY paperAppearanceChanged)
    Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
    Q_PROPERTY(bool embeddedAnnotations READ embeddedAnnotations WRITE setEmbeddedAnnotations NOTIFY embeddedAnnotationsChanged)
    Q_PROPERTY(bool tilesEnabled READ tilesEnabled WRITE setTilesEnabled NOTIFY tilesEnabledChanged)
    Q_PROPERTY(QRectF visibleRegion READ visibleRegion WRITE setVisibleRegion NOTIFY visibleRegionChanged)
    Q_PROPERTY(bool refined READ refined NOTIFY refinementChanged)
    Q_PROPERTY(int loadedTileCount READ loadedTileCount NOTIFY refinementChanged)
    Q_PROPERTY(bool resourceActive READ resourceActive WRITE setResourceActive NOTIFY resourceActiveChanged)
    Q_PROPERTY(bool texturesReady READ texturesReady NOTIFY texturesReadyChanged)
public:
    explicit PageItem(QQuickItem *parent=nullptr);
    ~PageItem() override;
    ReaderController *controller() const {return m_controller;}
    int pageIndex() const {return m_page;}
    double rasterScale() const {return m_scale;}
    QString paperAppearance() const {return m_paperAppearance;}
    bool loaded() const {return !m_image.isNull() || !m_tileImages.isEmpty();}
    bool refined() const {return m_refined;}
    int loadedTileCount() const {return int(m_tileImages.size());}
    bool embeddedAnnotations() const {return m_embedded;}
    bool resourceActive()const{return m_resourceActive;}
    bool texturesReady()const{return m_texturesReady;}
    void setResourceActive(bool active);
    bool tilesEnabled() const {return m_tilesEnabled;}
    QRectF visibleRegion() const {return m_visibleRegion;}
    void setController(ReaderController *controller);
    void setPageIndex(int page);
    void setRasterScale(double scale);
    void setPaperAppearance(const QString &appearance);
    void setEmbeddedAnnotations(bool enabled);
    void setTilesEnabled(bool enabled);
    void setVisibleRegion(const QRectF &region);
signals:
    void controllerChanged();void pageIndexChanged();void rasterScaleChanged();void loadedChanged();
    void paperAppearanceChanged();void embeddedAnnotationsChanged();void tilesEnabledChanged();
    void visibleRegionChanged();void refinementChanged();
    void resourceActiveChanged();
    void texturesReadyChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *node,UpdatePaintNodeData *) override;
    void itemChange(ItemChange change,const ItemChangeData &data) override;
private:
    double effectiveScale() const;
    double fallbackScale() const;
    bool needsTiles() const;
    void resetImages();
    void request();
    void refresh();
    void setRefined(bool value);
    bool demandVisible()const;
    void syncBudget();
    void budgetChanged();
    QPointer<ReaderController> m_controller;
    QVector<QMetaObject::Connection> m_connections;
    QVector<QMetaObject::Connection> m_windowConnections;
    int m_page=-1,m_level=-1000;
    double m_scale=1,m_lastDeviceScale=0;
    ResidentImage m_image;
    QList<TileSpec> m_tiles,m_previousTiles;
    QHash<QString,ResidentImage> m_tileImages,m_previousImages;
    QRectF m_visibleRegion;
    QString m_paperAppearance=QStringLiteral("original");
    bool m_embedded=false,m_tilesEnabled=false,m_refined=false,m_demandCurrent=false;
    bool m_resourceActive=true;
    qint64 m_targetBytes=0;
    bool m_texturesReady=false;
    quint64 m_textureEpoch=0;
    QTimer m_requestTimer;
};
