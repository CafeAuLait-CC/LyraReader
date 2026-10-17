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
    Q_PROPERTY(bool loaded READ loaded NOTIFY loadedChanged)
public:
    explicit PageItem(QQuickItem *parent = nullptr);
    ReaderController *controller() const { return m_controller; }
    int pageIndex() const { return m_page; }
    double rasterScale() const { return m_scale; }
    bool loaded() const { return !m_image.isNull(); }
    void setController(ReaderController *controller);
    void setPageIndex(int page);
    void setRasterScale(double scale);
signals:
    void controllerChanged();
    void pageIndexChanged();
    void rasterScaleChanged();
    void loadedChanged();
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
    bool m_dirty = true;
    QTimer m_requestTimer;
};
