#include "PageItem.h"
#include <QQuickWindow>
#include <QSGImageNode>
#include <cmath>

PageItem::PageItem(QQuickItem *parent) : QQuickItem(parent) {
    setFlag(ItemHasContents, true);
    m_requestTimer.setSingleShot(true);
    m_requestTimer.setInterval(70);
    connect(&m_requestTimer, &QTimer::timeout, this, &PageItem::request);
}

void PageItem::setController(ReaderController *controller) {
    if (m_controller == controller) return;
    if (m_controller) disconnect(m_controller, nullptr, this, nullptr);
    m_controller = controller;
    m_image = {};
    m_dirty = true;
    if (controller) {
        connect(controller, &ReaderController::pageReady, this, [this](int page, double scale) {
            if (page == m_page && ReaderController::rasterKey(page, scale) == ReaderController::rasterKey(m_page, effectiveScale())) refresh();
        });
        connect(controller, &ReaderController::documentReset, this, [this] {
            m_image = {};
            m_dirty = true;
            update();
            emit loadedChanged();
        });
        connect(controller, &ReaderController::documentChanged, &m_requestTimer, qOverload<>(&QTimer::start));
    }
    m_requestTimer.start();
    update();
    emit controllerChanged();
    emit loadedChanged();
}

void PageItem::setPageIndex(int page) {
    if (m_page == page) return;
    m_page = page;
    m_image = {};
    m_dirty = true;
    refresh();
    m_requestTimer.start();
    update();
    emit pageIndexChanged();
    emit loadedChanged();
}

void PageItem::setRasterScale(double scale) {
    if (qFuzzyCompare(m_scale, scale)) return;
    m_scale = scale;
    refresh();
    m_requestTimer.start();
    emit rasterScaleChanged();
}

void PageItem::refresh() {
    if (!m_controller) return;
    auto image = m_controller->cachedPage(m_page, effectiveScale());
    if (image.isNull()) return; // Keep the previous resolution sharp while refinement is pending.
    if (m_image.cacheKey() == image.cacheKey()) return;
    m_image = std::move(image);
    m_dirty = true;
    update();
    emit loadedChanged();
}

void PageItem::request() {
    if (!m_controller || m_page < 0) return;
    refresh();
    m_controller->requestPage(m_page, effectiveScale());
}

double PageItem::effectiveScale() const {
    // A Wayland window's fractional scale can differ from its QScreen's scale.
    double deviceScale = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    if (!std::isfinite(deviceScale) || deviceScale <= 0) deviceScale = 1.0;
    return m_scale * deviceScale;
}

void PageItem::itemChange(ItemChange change, const ItemChangeData &data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
        const double deviceScale = window() ? window()->effectiveDevicePixelRatio() : 1.0;
        if (!qFuzzyCompare(deviceScale, m_lastDeviceScale)) {
            m_lastDeviceScale = deviceScale;
            if (!m_requestTimer.isActive()) m_requestTimer.start();
        }
    }
}

QSGNode *PageItem::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) {
    auto *node = static_cast<QSGImageNode *>(oldNode);
    if (m_image.isNull()) { delete node; return nullptr; }
    if (!node || m_dirty) {
        // Let Qt create the node appropriate to its graphics backend. Replacing
        // the owned node also disposes of its texture exactly once.
        delete node;
        node = window()->createImageNode();
        if (!node) return nullptr;
        auto *texture = window()->createTextureFromImage(m_image);
        if (!texture) { delete node; return nullptr; }
        node->setTexture(texture);
        node->setOwnsTexture(true);
        node->setFiltering(QSGTexture::Linear);
        node->setSourceRect(QRectF(QPointF(0, 0), m_image.size()));
        m_dirty = false;
        qInfo().nospace() << "aris-qt-upload: page=" << m_page << " size=" << m_image.width() << 'x' << m_image.height();
    }
    node->setRect(boundingRect());
    return node;
}
