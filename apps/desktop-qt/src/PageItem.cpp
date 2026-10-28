#include "PageItem.h"
#include "PaperAppearance.h"
#include "BudgetedTexture.h"
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGTransformNode>
#include <cmath>

namespace {
// An explicit transform root preserves item transforms and software clips.
class PageScene final:public QSGTransformNode {
public:
    QHash<QString,BudgetedTexture *> images;
    QStringList order;
};
}

PageItem::PageItem(QQuickItem *parent):QQuickItem(parent) {
    setFlag(ItemHasContents,true);m_requestTimer.setSingleShot(true);m_requestTimer.setInterval(70);
    connect(&m_requestTimer,&QTimer::timeout,this,&PageItem::request);
    connect(RenderBudget::instance(),&RenderBudget::targetsChanged,this,&PageItem::budgetChanged);
}
PageItem::~PageItem() {
    RenderBudget::instance()->setClient(this,0);
    if(m_controller)m_controller->clearRasterDemand(quintptr(this));
    for(const auto &connection:m_connections)QObject::disconnect(connection);
}
void PageItem::setRefined(bool value) {
    if(!value){++m_textureEpoch;if(m_texturesReady){m_texturesReady=false;emit texturesReadyChanged();}}
    if(m_refined==value)return;m_refined=value;emit refinementChanged();
}
bool PageItem::demandVisible()const {
    if(!m_resourceActive || !isVisible() || !window() || !window()->isVisible() || window()->visibility()==QWindow::Minimized || !m_controller || m_page<0 || m_page>=m_controller->pageCount())return false;
    if(!m_tilesEnabled)return true;
    const auto page=m_controller->pages().at(m_page).toMap();
    return m_visibleRegion.intersects(QRectF(0,0,page.value("width").toDouble(),page.value("height").toDouble()));
}
void PageItem::syncBudget() {
    RenderBudget::instance()->setClient(this,demandVisible()?(m_tilesEnabled?16:1):0);
    const auto previous=m_targetBytes;m_targetBytes=RenderBudget::instance()->targetBytes(this);
    if(!m_targetBytes){if(loaded())resetImages();m_requestTimer.stop();return;}
    if(previous==m_targetBytes)return;
    if(m_targetBytes<previous) {
        m_previousTiles.clear();m_previousImages.clear();m_tiles.clear();m_tileImages.clear();m_level=-1000;
        if(m_image.pixels.sizeInBytes()>m_targetBytes/2)m_image={};
        update();
    }
    m_demandCurrent=false;setRefined(false);m_requestTimer.start();
}
void PageItem::budgetChanged(){syncBudget();}
void PageItem::setResourceActive(bool active) {
    if(m_resourceActive==active)return;m_resourceActive=active;
    syncBudget();if(!demandVisible()){resetImages();m_requestTimer.stop();}else m_requestTimer.start();
    emit resourceActiveChanged();
}
void PageItem::resetImages() {
    if(m_controller)m_controller->clearRasterDemand(quintptr(this));
    m_image={};m_usingBackdrop=false;m_tiles.clear();m_tileImages.clear();m_previousTiles.clear();m_previousImages.clear();m_level=-1000;m_demandCurrent=false;
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
void PageItem::setPageIndex(int page) {if(m_page==page)return;resetImages();m_page=page;refresh();m_requestTimer.start();emit pageIndexChanged();}
void PageItem::setRasterScale(double scale) {if(!std::isfinite(scale) || scale<=0 || scale>128 || qFuzzyCompare(m_scale,scale))return;m_scale=scale;m_demandCurrent=false;setRefined(false);m_requestTimer.start();refresh();emit rasterScaleChanged();update();}
void PageItem::setPaperAppearance(const QString &appearance) {if(m_paperAppearance==appearance)return;m_paperAppearance=appearance;update();emit paperAppearanceChanged();}
void PageItem::setEmbeddedAnnotations(bool enabled) {if(m_embedded==enabled)return;m_embedded=enabled;resetImages();m_requestTimer.start();emit embeddedAnnotationsChanged();}
void PageItem::setTilesEnabled(bool enabled) {if(m_tilesEnabled==enabled)return;m_tilesEnabled=enabled;m_demandCurrent=false;setRefined(false);m_requestTimer.start();emit tilesEnabledChanged();}
void PageItem::setVisibleRegion(const QRectF &region) {
    if(m_visibleRegion==region)return;m_visibleRegion=region;m_demandCurrent=false;setRefined(false);syncBudget();
    if(!demandVisible()){resetImages();m_requestTimer.stop();}else {refresh();m_requestTimer.start(16);}emit visibleRegionChanged();
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
    return m_targetBytes>=2*1024*1024 && pixels>qMin<double>(3*1024*1024,m_targetBytes/8.0);
}
double PageItem::fallbackScale() const {
    if(!m_controller || m_page<0 || m_page>=m_controller->pageCount())return effectiveScale();
    const auto page=m_controller->pages().at(m_page).toMap();
    const double area=page.value(QStringLiteral("width")).toDouble()*page.value(QStringLiteral("height")).toDouble();
    const double bytes=needsTiles()?qMin<qint64>(4*1024*1024,m_targetBytes/4):qMax<qint64>(4096,m_targetBytes/2);
    const double scale=qMin(effectiveScale(),std::sqrt(bytes/(area*4)));
    return scale>=.125?std::floor(scale*8)/8:std::exp2(std::floor(std::log2(scale)*4)/4);
}
void PageItem::refresh() {
    syncBudget();if(!demandVisible())return;
    const bool wasLoaded=loaded();
    const auto fallback=m_controller->cachedPage(m_page,fallbackScale(),m_embedded);
    bool blocked=false;
    if(!fallback.isNull() && fallback.cacheKey()!=m_image.pixels.cacheKey()) {
        auto retained=ResidentImage::retain(fallback);
        if(!retained.isNull())m_image=std::move(retained);else blocked=true;
    }
    const bool fallbackReady=!fallback.isNull() && m_image.pixels.cacheKey()==fallback.cacheKey();
    if(fallbackReady)m_usingBackdrop=false;
    else if(m_image.isNull()) {
        auto retained=ResidentImage::retain(m_controller->cachedBackdrop(m_page,m_embedded));
        if(!retained.isNull()){m_image=std::move(retained);m_usingBackdrop=true;}
    }
    QSet<QString> wanted;bool complete=true;
    for(const auto &tile:m_tiles) {
        wanted.insert(tile.key);
        if(!m_tileImages.contains(tile.key)) {
            const auto image=m_controller->cachedTile(tile.key);
            if(!image.isNull()) {
                auto retained=ResidentImage::retain(image);
                if(!retained.isNull())m_tileImages.insert(tile.key,std::move(retained));else blocked=true;
            }
        }
        if(!m_tileImages.contains(tile.key))complete=false;
    }
    for(auto it=m_tileImages.begin();it!=m_tileImages.end();)if(!wanted.contains(it.key()))it=m_tileImages.erase(it);else ++it;
    if(complete && m_demandCurrent){m_previousTiles.clear();m_previousImages.clear();}
    if(blocked){m_previousTiles.clear();m_previousImages.clear();m_requestTimer.start(200);}
    setRefined(m_demandCurrent && (needsTiles()?complete:fallbackReady));
    update();emit refinementChanged();if(wasLoaded!=loaded())emit loadedChanged();
}
void PageItem::request() {
    syncBudget();if(!demandVisible())return;
    if(needsTiles()) {
        int requested=qBound(-24,int(std::ceil(std::log2(effectiveScale())*4)),28);
        const auto dimensions=m_controller->pages().at(m_page).toMap();
        const auto view=m_visibleRegion.intersected(QRectF(0,0,dimensions.value("width").toDouble(),dimensions.value("height").toDouble()));
        while(requested>-24) {
            const double edge=512/ReaderController::tileScale(requested);
            const double count=(std::ceil(view.right()/edge)-std::floor(view.left()/edge))*(std::ceil(view.bottom()/edge)-std::floor(view.top()/edge));
            if(count*515*515*4<=m_targetBytes-qMin<qint64>(4*1024*1024,m_targetBytes/4))break;--requested;
        }
        const auto next=m_controller->requestTiles(quintptr(this),m_page,requested,m_visibleRegion,QSet<QString>(m_tileImages.keyBegin(),m_tileImages.keyEnd()));
        const int level=next.isEmpty()?requested:next.first().level;
        if(level!=m_level) {
            m_previousTiles.clear();m_previousImages.clear();qsizetype retained=0;
            for(const auto &tile:m_tiles)if(tile.target.intersects(m_visibleRegion) && m_tileImages.contains(tile.key)) {
                const auto image=m_tileImages.value(tile.key);
                if(retained+image.pixels.sizeInBytes()>m_targetBytes/3)continue;
                m_previousTiles.append(tile);m_previousImages.insert(tile.key,image);retained+=image.pixels.sizeInBytes();
            }
            m_tileImages.clear();m_level=level;
        }
        m_tiles=next;
    }else {m_controller->clearTileDemand(quintptr(this));m_tiles.clear();m_tileImages.clear();m_previousTiles.clear();m_previousImages.clear();}
    m_demandCurrent=true;m_controller->requestPageForConsumer(quintptr(this),m_page,fallbackScale(),m_embedded);refresh();
    if(!m_refined || m_image.isNull())m_requestTimer.start(200);
}
void PageItem::itemChange(ItemChange change,const ItemChangeData &data) {
    QQuickItem::itemChange(change,data);
    if(change==ItemSceneChange) {
        for(const auto &connection:m_windowConnections)QObject::disconnect(connection);m_windowConnections.clear();
        if(window())m_windowConnections.append(connect(window(),&QWindow::visibilityChanged,this,[this]{budgetChanged();}));
        syncBudget();
    }
    if(change==ItemVisibleHasChanged) {
        syncBudget();if(demandVisible())m_requestTimer.start();else {resetImages();m_requestTimer.stop();}
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
    QStringList order;bool orderChanged=false,blocked=false;
    const auto append=[&](const QString &key,const ResidentImage &image,const QRectF &target,const QRectF &source) {
        if(image.isNull())return;
        auto *node=root->images.value(key);
        if(!node){node=new BudgetedTexture(this);root->images.insert(key,node);root->appendChildNode(node);orderChanged=true;}
        if(!node->setImage(window(),image,appearance))blocked=true;
        if(node->empty())return;
        node->setRect(target,source);order.append(key);
    };
    append(QStringLiteral("base"),m_image,boundingRect(),QRectF(0,0,1,1));
    const auto tiles=[&](const QList<TileSpec> &specs,const QHash<QString,ResidentImage> &images) {
        for(const auto &tile:specs) {
            if(!tile.target.intersects(m_visibleRegion))continue;
            const auto image=images.value(tile.key);if(image.isNull())continue;
            const QRectF texture((tile.target.x()-tile.render.x())*tile.scale/image.pixels.width(),(tile.target.y()-tile.render.y())*tile.scale/image.pixels.height(),tile.target.width()*tile.scale/image.pixels.width(),tile.target.height()*tile.scale/image.pixels.height());
            append(tile.key,image,QRectF(tile.target.x()*m_scale,tile.target.y()*m_scale,tile.target.width()*m_scale,tile.target.height()*m_scale),texture);
        }
    };
    tiles(m_previousTiles,m_previousImages);tiles(m_tiles,m_tileImages);
    for(auto it=root->images.begin();it!=root->images.end();) {
        if(!order.contains(it.key())){root->removeChildNode(it.value());delete it.value();it=root->images.erase(it);}else ++it;
    }
    if(orderChanged || root->order!=order){for(const auto &key:order){auto *node=root->images.value(key);root->removeChildNode(node);root->appendChildNode(node);}root->order=order;}
    const auto epoch=m_textureEpoch;const bool ready=m_refined && !blocked;
    QMetaObject::invokeMethod(this,[this,epoch,ready]{if(epoch==m_textureEpoch && m_texturesReady!=ready){m_texturesReady=ready;emit texturesReadyChanged();}},Qt::QueuedConnection);
    if(blocked)QMetaObject::invokeMethod(this,[this]{m_requestTimer.start(200);},Qt::QueuedConnection);
    return root;
}
