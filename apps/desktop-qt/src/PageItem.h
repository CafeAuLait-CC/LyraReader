#pragma once
#include "ReaderController.h"
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
public:
    explicit PageItem(QQuickItem *parent = nullptr);
    ReaderController *controller() const { return m_controller; }
    int pageIndex() const { return m_page; }
    double rasterScale() const { return m_scale; }
    QString paperAppearance() const { return m_paperAppearance; }
    void setPaperAppearance(const QString &appearance) { if(m_paperAppearance==appearance)return; m_paperAppearance=appearance; update(); emit paperAppearanceChanged(); }
    bool loaded() const { return !m_image.isNull(); }
    bool embeddedAnnotations()const{return m_embedded;}
    void setController(ReaderController *controller);
    void setPageIndex(int page);
    void setRasterScale(double scale);
    void setEmbeddedAnnotations(bool enabled){if(m_embedded==enabled)return;m_embedded=enabled;m_image={};m_dirty=true;m_requestTimer.start();update();emit embeddedAnnotationsChanged();}
signals:
    void controllerChanged();
    void pageIndexChanged();
    void rasterScaleChanged();
    void loadedChanged();
    void paperAppearanceChanged();
    void embeddedAnnotationsChanged();
protected:
    QSGNode *updatePaintNode(QSGNode *node, UpdatePaintNodeData *) override;
    void itemChange(ItemChange change, const ItemChangeData &data) override;
private:
    double effectiveScale() const;
    void request();
    void refresh();
    QPointer<ReaderController> m_controller;
    int m_page = -1;
    double m_scale = 1;
    double m_lastDeviceScale = 0;
    QImage m_image;
    QString m_paperAppearance=QStringLiteral("original");
    int m_uploadedAppearance=-1;
    bool m_dirty = true;
    bool m_embedded = false;
    QTimer m_requestTimer;
};
