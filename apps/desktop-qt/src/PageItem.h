#pragma once
#include "ReaderController.h"
#include "RenderBudget.h"
#include "RenderTrace.h"
#include <QQuickItem>
#include <QPointer>
#include <QTimer>
#include <mutex>

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
    Q_PROPERTY(bool backdropVisible READ backdropVisible NOTIFY refinementChanged)
    Q_PROPERTY(int loadedTileCount READ loadedTileCount NOTIFY refinementChanged)
    Q_PROPERTY(bool resourceActive READ resourceActive WRITE setResourceActive NOTIFY resourceActiveChanged)
    Q_PROPERTY(bool rasterDemandPaused READ rasterDemandPaused WRITE setRasterDemandPaused NOTIFY rasterDemandPausedChanged)
    Q_PROPERTY(bool texturesReady READ texturesReady NOTIFY texturesReadyChanged)
    Q_PROPERTY(bool revisionFallbackActive READ revisionFallbackActive NOTIFY revisionFallbackChanged)
    Q_PROPERTY(bool revisionContinuityAllowed READ revisionContinuityAllowed WRITE setRevisionContinuityAllowed NOTIFY revisionContinuityAllowedChanged)
    Q_PROPERTY(QString paperGeometryError READ paperGeometryError NOTIFY paperGeometryChanged)
    Q_PROPERTY(bool paperGeometryActive READ paperGeometryActive NOTIFY paperGeometryChanged)
    Q_PROPERTY(qulonglong paperGeometryRevision READ paperGeometryRevision NOTIFY paperGeometryChanged)
    Q_PROPERTY(double paperSceneLimit READ paperSceneLimit CONSTANT)
public:
    explicit PageItem(QQuickItem *parent=nullptr);
    ~PageItem() override;
    ReaderController *controller() const {return m_controller;}
    int pageIndex() const {return m_page;}
    double rasterScale() const {return m_scale;}
    QString paperAppearance() const {return m_paperAppearance;}
    bool loaded() const {return !m_image.isNull() || !m_tileImages.isEmpty() || bool(m_revisionFrame);}
    bool refined() const {return m_refined;}
    bool backdropVisible()const{return m_usingBackdrop && !m_refined && !m_image.isNull();}
    int loadedTileCount() const {return int(m_tileImages.size());}
    bool embeddedAnnotations() const {return m_embedded;}
    bool resourceActive()const{return m_resourceActive;}
    bool rasterDemandPaused()const{return m_rasterDemandPaused;}
    bool texturesReady()const{return m_texturesReady;}
    bool revisionFallbackActive()const{return bool(m_revisionFrame);}
    bool revisionContinuityAllowed()const{return m_revisionContinuityAllowed;}
    void setRevisionContinuityAllowed(bool allowed);
    QString paperGeometryError()const{return m_paperError;}
    bool paperGeometryActive()const{return m_paperLayout.has_value();}
    qulonglong paperGeometryRevision()const{return m_paperEpoch;}
    double paperSceneLimit()const;
    std::optional<LyraReaderPaperLayout> paperLayout()const{return m_paperLayout;}
    // One atomic geometry update. It does not change source pixels, raster demand or zoom.
    Q_INVOKABLE bool configurePaper(double originalHeightPt,double splitPt,double gapPt);
    Q_INVOKABLE void clearPaperGeometry();
    Q_INVOKABLE QVariantMap paperViewport(const QRectF &displayRegion,qulonglong revision) const;
    Q_INVOKABLE QVariantMap paperEraserSegments(const QPointF &from,const QPointF &to)const;
    Q_INVOKABLE QVariantMap paperPoint(const QPointF &display)const;
    Q_INVOKABLE QVariantMap paperRegion(const QRectF &source,qulonglong revision)const;
    Q_INVOKABLE QVariantMap paperAxisY(double y,bool toDisplay,qulonglong revision)const;
    void setResourceActive(bool active);
    void setRasterDemandPaused(bool paused);
    bool tilesEnabled() const {return m_tilesEnabled;}
    QRectF visibleRegion() const {return m_visibleRegion;}
    void setController(ReaderController *controller);
    void setPageIndex(int page);
    void setRasterScale(double scale);
    void setPaperAppearance(const QString &appearance);
    void setEmbeddedAnnotations(bool enabled);
    void setTilesEnabled(bool enabled);
    void setVisibleRegion(const QRectF &region);
    // Only read the registry/GUI getters on the GUI thread, or during the window's
    // direct afterSynchronizing callback while Qt has blocked the GUI thread.
    static QList<PageItem *> traceItems(QQuickWindow *window);
    void setSceneTraceEnabled(bool enabled);
    RenderTrace::Scene sceneTraceSnapshot()const;
    std::shared_ptr<RenderTrace::SceneState> sceneTraceState()const{return m_sceneTrace;}
    quint64 traceSourceEpoch()const{return m_sourceEpoch;}
signals:
    void controllerChanged();void pageIndexChanged();void rasterScaleChanged();void loadedChanged();
    void paperAppearanceChanged();void embeddedAnnotationsChanged();void tilesEnabledChanged();
    void visibleRegionChanged();void refinementChanged();
    void resourceActiveChanged();
    void rasterDemandPausedChanged();
    void texturesReadyChanged();
    void revisionFallbackChanged();
    void revisionContinuityAllowedChanged();
    void paperGeometryChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *node,UpdatePaintNodeData *) override;
    void itemChange(ItemChange change,const ItemChangeData &data) override;
private:
    double effectiveScale() const;
    double fallbackScale() const;
    bool needsTiles() const;
    void resetImages(bool keepRevision=false);
    void prepareRevision(bool preserveViewport);
    void retireRevision();
    void clearAcceptedFrame();
    QSGNode *paintFrame(QSGNode *node,bool previous,bool &blocked);
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
    bool m_rasterDemandPaused=false;
    bool m_embedded=false,m_tilesEnabled=false,m_refined=false,m_demandCurrent=false;
    bool m_resourceActive=true;
    bool m_usingBackdrop=false;
    bool m_traceBaseCurrent=false;
    std::shared_ptr<RenderTrace::SceneState> m_sceneTrace;
    qint64 m_targetBytes=0;
    bool m_texturesReady=false;
    quint64 m_textureEpoch=0;
    struct RevisionFrame {
        ResidentImage image;
        QList<TileSpec> tiles;
        QHash<QString,ResidentImage> images;
        quint64 sourceEpoch=0;
    };
    // The render thread publishes only complete scene-node groups. The mutex protects
    // the snapshot pointer, never PDFium work or texture creation. Pixel leases are shared.
    std::mutex m_frameMutex;
    std::shared_ptr<const RevisionFrame> m_acceptedFrame,m_revisionFrame;
    quint64 m_sourceEpoch=1;
    bool m_preserveNextReset=false;
    bool m_revisionContinuityAllowed=true;
    QTimer m_requestTimer;
    std::optional<LyraReaderPaperLayout> m_paperLayout;
    QString m_paperError;
    quint64 m_paperEpoch=0;
};
