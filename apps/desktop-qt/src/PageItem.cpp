#include "PageItem.h"
#include "PaperAppearance.h"
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
    auto image = m_controller->cachedPage(m_page, effectiveScale(),m_embedded);
    if (image.isNull()) return; // Keep the previous resolution sharp while refinement is pending.
    if (m_image.cacheKey() == image.cacheKey()) return;
    m_image = std::move(image);
    m_dirty = true;
    update();
    emit loadedChanged();
}

void PageItem::request() {
    if (!m_controller || m_page < 0 || !isVisible()) return;
    refresh();
    if (!m_controller->cachedPage(m_page, effectiveScale(),m_embedded).isNull()) return;
    m_controller->requestPage(m_page, effectiveScale(),m_embedded);
    // A bounded scheduler can discard obsolete work during fast jumps/zooms.
    // An item still alive at this density must eventually retry rather than stay blank.
    m_requestTimer.start(200);
}

double PageItem::effectiveScale() const {
    // A Wayland window's fractional scale can differ from its QScreen's scale.
    double deviceScale = window() ? window()->effectiveDevicePixelRatio() : 1.0;
    if (!std::isfinite(deviceScale) || deviceScale <= 0) deviceScale = 1.0;
    return m_scale * deviceScale;
}

void PageItem::itemChange(ItemChange change, const ItemChangeData &data) {
    QQuickItem::itemChange(change, data);
    if(change==ItemVisibleHasChanged && isVisible())m_requestTimer.start();
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
        const double deviceScale = window() ? window()->effectiveDevicePixelRatio() : 1.0;
        if (!qFuzzyCompare(deviceScale, m_lastDeviceScale)) {
            m_lastDeviceScale = deviceScale;
            if (!m_requestTimer.isActive()) m_requestTimer.start();
        }
    }
}

QSGNode *PageItem::updatePaintNode(QSGNode *node, UpdatePaintNodeData *) {
    if (m_image.isNull()) { delete node; return nullptr; }
    const int appearance=PaperAppearance::mode(m_paperAppearance);
    const bool software=window()->rendererInterface()->graphicsApi()==QSGRendererInterface::Software;
    if (!node || m_dirty || (software && m_uploadedAppearance!=appearance)) {
        delete node;
        if(software) {
            auto *imageNode=window()->createImageNode();
            if(!imageNode)return nullptr;
            const auto display=PaperAppearance::displayImage(m_image,appearance);
            auto *texture=window()->createTextureFromImage(display);
            if(!texture){delete imageNode;return nullptr;}
            imageNode->setTexture(texture);
            imageNode->setOwnsTexture(true);
            imageNode->setFiltering(QSGTexture::Linear);
            imageNode->setSourceRect(QRectF(QPointF(0,0),display.size()));
            node=imageNode;
        } else node=PaperAppearance::createNode(window(),m_image,appearance);
        if(!node)return nullptr;
        m_dirty=false;
        m_uploadedAppearance=appearance;
        qInfo().nospace()<<"lyra-reader-qt-upload: page="<<m_page<<" size="<<m_image.width()<<'x'<<m_image.height();
    }
    if(software)static_cast<QSGImageNode *>(node)->setRect(boundingRect());
    else PaperAppearance::updateNode(node,boundingRect(),appearance);
    return node;
}
