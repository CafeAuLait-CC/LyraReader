#include "PageItem.h"
#include "PaperAppearance.h"
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGTransformNode>
#include <cmath>

namespace {
struct SceneImage {QSGNode *node=nullptr;qint64 key=0;int appearance=-1;};
// An explicit transform root also preserves item transforms and clips in Qt's software renderer.
class PageScene final:public QSGTransformNode {
public:
    QHash<QString,SceneImage> images;
    QStringList order;
};
QSGNode *imageNode(QQuickWindow *window,const QImage &image,int appearance,bool software) {
    if(!software)return PaperAppearance::createNode(window,image,appearance);
    auto *node=window->createImageNode();if(!node)return nullptr;
    const auto display=PaperAppearance::displayImage(image,appearance);
    auto *texture=window->createTextureFromImage(display);
    if(!texture){delete node;return nullptr;}
    node->setTexture(texture);node->setOwnsTexture(true);node->setFiltering(QSGTexture::Linear);return node;
}
}
PageItem::PageItem(QQuickItem *parent):QQuickItem(parent) {
    setFlag(ItemHasContents,true);m_requestTimer.setSingleShot(true);m_requestTimer.setInterval(70);
    connect(&m_requestTimer,&QTimer::timeout,this,&PageItem::request);
}
PageItem::~PageItem() {
    if(m_controller)m_controller->clearTileDemand(quintptr(this));
    for(const auto &connection:m_connections)QObject::disconnect(connection);
}
void PageItem::setRefined(bool value) {if(m_refined==value)return;m_refined=value;emit refinementChanged();}
void PageItem::resetImages() {
    if(m_controller)m_controller->clearTileDemand(quintptr(this));
    m_image={};m_tiles.clear();m_tileImages.clear();m_previousTiles.clear();m_previousImages.clear();m_level=-1000;m_demandCurrent=false;
    setRefined(false);update();emit loadedChanged();emit refinementChanged();
}
void PageItem::setController(ReaderController *controller) {
    if(m_controller==controller)return;
    resetImages();for(const auto &connection:m_connections)QObject::disconnect(connection);m_connections.clear();
    m_controller=controller;
    if(controller) {
        m_connections.append(connect(controller,&ReaderController::pageReady,this,[this](int page,double){if(page==m_page)refresh();}));
        m_connections.append(connect(controller,&ReaderController::tileReady,this,[this](int page){if(page==m_page)refresh();}));
        m_connections.append(connect(controller,&ReaderController::documentReset,this,&PageItem::resetImages));
        m_connections.append(connect(controller,&ReaderController::documentChanged,this,[this]{m_requestTimer.start();}));
    }
    m_requestTimer.start();update();emit controllerChanged();
}
void PageItem::setPageIndex(int page) {if(m_page==page)return;resetImages();m_page=page;m_requestTimer.start();emit pageIndexChanged();}
void PageItem::setRasterScale(double scale) {if(!std::isfinite(scale) || scale<=0 || scale>128 || qFuzzyCompare(m_scale,scale))return;m_scale=scale;m_demandCurrent=false;setRefined(false);m_requestTimer.start();refresh();emit rasterScaleChanged();update();}
void PageItem::setPaperAppearance(const QString &appearance) {if(m_paperAppearance==appearance)return;m_paperAppearance=appearance;update();emit paperAppearanceChanged();}
void PageItem::setEmbeddedAnnotations(bool enabled) {if(m_embedded==enabled)return;m_embedded=enabled;resetImages();m_requestTimer.start();emit embeddedAnnotationsChanged();}
void PageItem::setTilesEnabled(bool enabled) {if(m_tilesEnabled==enabled)return;m_tilesEnabled=enabled;m_demandCurrent=false;setRefined(false);m_requestTimer.start();emit tilesEnabledChanged();}
void PageItem::setVisibleRegion(const QRectF &region) {
    if(m_visibleRegion==region)return;m_visibleRegion=region;m_demandCurrent=false;setRefined(false);m_requestTimer.start(16);emit visibleRegionChanged();
}
double PageItem::effectiveScale() const {
    double device=window()?window()->effectiveDevicePixelRatio():1.0;
    if(!std::isfinite(device) || device<=0)device=1;
    return m_scale*device;
}
bool PageItem::needsTiles() const {
    if(!m_tilesEnabled || m_embedded || !m_controller || m_page<0 || m_page>=m_controller->pageCount())return false;
    const auto page=m_controller->pages().at(m_page).toMap();
    const double pixels=page.value(QStringLiteral("width")).toDouble()*page.value(QStringLiteral("height")).toDouble()*std::pow(effectiveScale(),2);
    return pixels>3*1024*1024;
}
double PageItem::fallbackScale() const {
    if(!needsTiles())return effectiveScale();
    const auto page=m_controller->pages().at(m_page).toMap();
    const double area=page.value(QStringLiteral("width")).toDouble()*page.value(QStringLiteral("height")).toDouble();
    return qMax(.01,std::floor(qMin(1.0,std::sqrt(1024*1024/area))*8)/8);
}
void PageItem::refresh() {
    if(!m_controller)return;
    const bool wasLoaded=loaded();
    const auto fallback=m_controller->cachedPage(m_page,fallbackScale(),m_embedded);
    if(!fallback.isNull())m_image=fallback;
    QSet<QString> wanted;bool complete=true;
    for(const auto &tile:m_tiles) {
        wanted.insert(tile.key);
        if(!m_tileImages.contains(tile.key)) {
            const auto image=m_controller->cachedTile(tile.key);
            if(!image.isNull())m_tileImages.insert(tile.key,image);
        }
        if(!m_tileImages.contains(tile.key))complete=false;
    }
    for(auto it=m_tileImages.begin();it!=m_tileImages.end();)if(!wanted.contains(it.key()))it=m_tileImages.erase(it);else ++it;
    if(complete && m_demandCurrent){m_previousTiles.clear();m_previousImages.clear();}
    setRefined(m_demandCurrent && (needsTiles()?complete:!fallback.isNull()));
    update();emit refinementChanged();if(wasLoaded!=loaded())emit loadedChanged();
}
void PageItem::request() {
    if(!m_controller || m_page<0 || m_page>=m_controller->pageCount() || !isVisible())return;
    if(needsTiles()) {
        const int requested=qBound(-24,int(std::ceil(std::log2(effectiveScale())*4)),28);
        const auto next=m_controller->requestTiles(quintptr(this),m_page,requested,m_visibleRegion,QSet<QString>(m_tileImages.keyBegin(),m_tileImages.keyEnd()));
        const int level=next.isEmpty()?requested:next.first().level;
        if(level!=m_level) {
            m_previousTiles.clear();m_previousImages.clear();qsizetype retained=0;
            for(const auto &tile:m_tiles)if(tile.target.intersects(m_visibleRegion) && m_tileImages.contains(tile.key)) {
                const auto image=m_tileImages.value(tile.key);
                if(retained+image.sizeInBytes()>32*1024*1024)continue;
                m_previousTiles.append(tile);m_previousImages.insert(tile.key,image);retained+=image.sizeInBytes();
            }
            m_tileImages.clear();m_level=level;
        }
        m_tiles=next;
    }else {m_controller->clearTileDemand(quintptr(this));m_tiles.clear();m_tileImages.clear();m_previousTiles.clear();m_previousImages.clear();}
    m_demandCurrent=true;m_controller->requestPage(m_page,fallbackScale(),m_embedded);refresh();
    if(!m_refined || m_image.isNull())m_requestTimer.start(200);
}
void PageItem::itemChange(ItemChange change,const ItemChangeData &data) {
    QQuickItem::itemChange(change,data);
    if(change==ItemVisibleHasChanged) {
        if(isVisible())m_requestTimer.start();else if(m_controller){m_controller->clearTileDemand(quintptr(this));m_tileImages.clear();m_previousImages.clear();update();}
    }
    if(change==ItemDevicePixelRatioHasChanged || change==ItemSceneChange) {
        const double device=window()?window()->effectiveDevicePixelRatio():1;
        if(!qFuzzyCompare(device,m_lastDeviceScale)){m_lastDeviceScale=device;m_demandCurrent=false;setRefined(false);m_requestTimer.start();}
    }
}
QSGNode *PageItem::updatePaintNode(QSGNode *old,UpdatePaintNodeData *) {
    auto *root=static_cast<PageScene *>(old);
    if(!loaded()){delete root;return nullptr;}
    if(!root)root=new PageScene;
    const int appearance=PaperAppearance::mode(m_paperAppearance);
    const bool software=window()->rendererInterface()->graphicsApi()==QSGRendererInterface::Software;
    QStringList order;bool orderChanged=false;
    const auto append=[&](const QString &key,const QImage &image,const QRectF &target,const QRectF &source) {
        if(image.isNull())return;
        auto &entry=root->images[key];
        if(!entry.node || entry.key!=image.cacheKey() || (software && entry.appearance!=appearance)) {
            if(entry.node){root->removeChildNode(entry.node);delete entry.node;}
            entry.node=imageNode(window(),image,appearance,software);entry.key=image.cacheKey();entry.appearance=appearance;
            if(!entry.node)return;
            root->appendChildNode(entry.node);orderChanged=true;
        }
        if(software){auto *node=static_cast<QSGImageNode *>(entry.node);node->setRect(target);node->setSourceRect(QRectF(source.x()*image.width(),source.y()*image.height(),source.width()*image.width(),source.height()*image.height()));}
        else PaperAppearance::updateNode(entry.node,target,appearance,source);
        order.append(key);
    };
    append(QStringLiteral("base"),m_image,boundingRect(),QRectF(0,0,1,1));
    const auto tiles=[&](const QList<TileSpec> &specs,const QHash<QString,QImage> &images) {
        for(const auto &tile:specs) {
            if(!tile.target.intersects(m_visibleRegion))continue;
            const auto image=images.value(tile.key);if(image.isNull())continue;
            const QRectF texture((tile.target.x()-tile.render.x())*tile.scale/image.width(),(tile.target.y()-tile.render.y())*tile.scale/image.height(),tile.target.width()*tile.scale/image.width(),tile.target.height()*tile.scale/image.height());
            append(tile.key,image,QRectF(tile.target.x()*m_scale,tile.target.y()*m_scale,tile.target.width()*m_scale,tile.target.height()*m_scale),texture);
        }
    };
    tiles(m_previousTiles,m_previousImages);tiles(m_tiles,m_tileImages);
    for(auto it=root->images.begin();it!=root->images.end();) {
        if(!order.contains(it.key())){if(it->node){root->removeChildNode(it->node);delete it->node;}it=root->images.erase(it);}else ++it;
    }
    if(orderChanged || root->order!=order){for(const auto &key:order){auto *node=root->images.value(key).node;root->removeChildNode(node);root->appendChildNode(node);}root->order=order;}
    return root;
}
