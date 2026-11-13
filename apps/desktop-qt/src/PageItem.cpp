#include "PageItem.h"
#include "PaperAppearance.h"
#include "BudgetedTexture.h"
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGTransformNode>
#include <cmath>
#include <limits>

namespace {
constexpr double maximumRasterScale=128;
constexpr double sceneCoordinateLimit=double(std::numeric_limits<float>::max())/(4*maximumRasterScale);
// An explicit transform root preserves item transforms and software clips.
class PageScene final:public QSGTransformNode {
public:
    QHash<QString,BudgetedTexture *> images;
    QStringList order;
    quint64 sourceEpoch=0,acceptedDemandEpoch=0;
    PageScene *staging=nullptr;
    ~PageScene()override{delete staging;}
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
double PageItem::paperSceneLimit()const{return sceneCoordinateLimit;}
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
    if(m_rasterDemandPaused)return;
    RenderBudget::instance()->setClient(this,demandVisible()?(m_tilesEnabled?16:1):0);
    const auto previous=m_targetBytes;m_targetBytes=RenderBudget::instance()->targetBytes(this);
    if(!m_targetBytes){if(loaded())resetImages();m_requestTimer.stop();return;}
    if(previous==m_targetBytes)return;
    if(m_targetBytes<previous) {
        if(!m_revisionFrame)clearAcceptedFrame();
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
void PageItem::setRasterDemandPaused(bool paused) {
    if(m_rasterDemandPaused==paused)return;
    m_rasterDemandPaused=paused;
    if(paused)m_requestTimer.stop();else {syncBudget();m_requestTimer.start();}
    emit rasterDemandPausedChanged();
}
void PageItem::prepareRevision(bool preserveViewport) {
    std::shared_ptr<const RevisionFrame> frame;
    if(preserveViewport && m_revisionContinuityAllowed && demandVisible() && !m_embedded && !m_paperLayout) {
        std::lock_guard lock(m_frameMutex);frame=m_acceptedFrame;
    }
    m_revisionFrame=std::move(frame);m_preserveNextReset=bool(m_revisionFrame);
    emit revisionFallbackChanged();
}
void PageItem::setRevisionContinuityAllowed(bool allowed) {
    if(m_revisionContinuityAllowed==allowed)return;
    m_revisionContinuityAllowed=allowed;if(!allowed)retireRevision();
    emit revisionContinuityAllowedChanged();
}
void PageItem::retireRevision() {
    if(!m_revisionFrame)return;
    m_revisionFrame.reset();
    {std::lock_guard lock(m_frameMutex);if(m_acceptedFrame && m_acceptedFrame->sourceEpoch!=m_sourceEpoch)m_acceptedFrame.reset();}
    update();emit revisionFallbackChanged();emit loadedChanged();
}
void PageItem::clearAcceptedFrame() {
    std::lock_guard lock(m_frameMutex);m_acceptedFrame.reset();
}
void PageItem::resetImages(bool keepRevision) {
    ++m_sourceEpoch;m_preserveNextReset=false;
    if(!keepRevision) {
        m_revisionFrame.reset();
        clearAcceptedFrame();
        emit revisionFallbackChanged();
    }
    if(m_controller)m_controller->clearRasterDemand(quintptr(this));
    m_image={};m_usingBackdrop=false;m_tiles.clear();m_tileImages.clear();m_previousTiles.clear();m_previousImages.clear();m_level=-1000;m_demandCurrent=false;
    setRefined(false);update();emit loadedChanged();emit refinementChanged();
}
void PageItem::setController(ReaderController *controller) {
    if(m_controller==controller)return;
    resetImages();clearPaperGeometry();for(const auto &connection:m_connections)QObject::disconnect(connection);m_connections.clear();
    m_controller=controller;
    if(controller) {
        m_connections.append(connect(controller,&ReaderController::pageReady,this,[this](int page,double){if(page==m_page)refresh();}));
        m_connections.append(connect(controller,&ReaderController::tileReady,this,[this](int page){if(page==m_page)refresh();}));
        m_connections.append(connect(controller,&ReaderController::revisionAboutToChange,this,&PageItem::prepareRevision));
        m_connections.append(connect(controller,&ReaderController::documentReset,this,[this]{resetImages(m_preserveNextReset);}));
        m_connections.append(connect(controller,&ReaderController::rasterFailed,this,[this](int page){if(page==m_page)retireRevision();}));
        m_connections.append(connect(controller,&ReaderController::rasterPressure,this,[this](int page){if(page==m_page){clearAcceptedFrame();retireRevision();}}));
        m_connections.append(connect(controller,&ReaderController::documentReset,this,&PageItem::clearPaperGeometry));
        m_connections.append(connect(controller,&ReaderController::documentChanged,this,[this]{m_requestTimer.start();}));
    }
    m_requestTimer.start();update();emit controllerChanged();
}
void PageItem::setPageIndex(int page) {if(m_page==page)return;resetImages();clearPaperGeometry();m_page=page;refresh();m_requestTimer.start();emit pageIndexChanged();}
bool PageItem::configurePaper(double height,double split,double gap) {
    const LyraReaderPaperLayout layout{height,split,gap,1,0};LyraReaderBuffer error{};
    // Cover every later supported zoom as well, before converting targets to QSG float data.
    if(height>sceneCoordinateLimit || gap>sceneCoordinateLimit) {m_paperError=tr("The inserted paper is outside the scene coordinate range.");emit paperGeometryChanged();return false;}
    if(!lyra_reader_desktop_paper_quads(layout,nullptr,0,nullptr,&error)) {
        m_paperError=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));
        lyra_reader_desktop_buffer_free(error);emit paperGeometryChanged();return false;
    }
    if(m_paperLayout && m_paperLayout->height==height && m_paperLayout->split==split && m_paperLayout->gap==gap && m_paperError.isEmpty())return true;
    retireRevision();++m_paperEpoch;m_paperLayout=layout;m_paperError.clear();update();emit paperGeometryChanged();return true;
}
void PageItem::clearPaperGeometry() {
    if(!m_paperLayout && m_paperError.isEmpty())return;
    ++m_paperEpoch;m_paperLayout.reset();m_paperError.clear();update();emit paperGeometryChanged();
}
QVariantMap PageItem::paperViewport(const QRectF &region,qulonglong revision)const {
    if(!m_controller || m_controller->loading() || m_page<0 || m_page>=m_controller->pageCount() || revision!=m_paperEpoch)
        return {{QStringLiteral("error"),tr("The page layout changed. Try again.")}};
    if(!std::isfinite(region.x()) || !std::isfinite(region.y()) || !std::isfinite(region.width())
            || !std::isfinite(region.height()) || !std::isfinite(region.right()) || !std::isfinite(region.bottom())
            || region.width()<0 || region.height()<0)
        return {{QStringLiteral("error"),tr("The paper viewport is invalid.")}};
    const auto height=m_controller->pages().at(m_page).toMap().value(QStringLiteral("height")).toDouble();
    const auto layout=m_paperLayout.value_or(LyraReaderPaperLayout{height,0,0,0,0});
    LyraReaderPaperBand band{};LyraReaderBuffer error{};
    if(!lyra_reader_desktop_paper_band(layout,region.y(),region.bottom(),&band,&error)) {
        const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));
        lyra_reader_desktop_buffer_free(error);return {{QStringLiteral("error"),message}};
    }
    if(band.present>1 || band.reserved || !std::isfinite(band.top) || !std::isfinite(band.bottom)
            || band.top<0 || band.bottom<band.top || band.bottom>height)
        return {{QStringLiteral("error"),tr("The paper mapper returned an invalid viewport.")}};
    if(!band.present || region.width()==0)return {{QStringLiteral("hit"),false}};
    return {{QStringLiteral("hit"),true},{QStringLiteral("rect"),QRectF(region.x(),band.top,region.width(),band.bottom-band.top)}};
}
QVariantMap PageItem::paperAxisY(double y,bool toDisplay,qulonglong revision)const {
    if(!m_controller || m_controller->loading() || m_page<0 || m_page>=m_controller->pageCount() || revision!=m_paperEpoch)return {{QStringLiteral("error"),tr("The page layout changed. Try again.")}};
    const double originalHeight=m_controller->pages().at(m_page).toMap().value(QStringLiteral("height")).toDouble();
    const auto layout=m_paperLayout.value_or(LyraReaderPaperLayout{originalHeight,0,0,0,0});
    LyraReaderPaperAxis output{};LyraReaderBuffer error{};
    if(!lyra_reader_desktop_paper_axis(layout,y,toDisplay?0u:1u,&output,&error)) {
        const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));lyra_reader_desktop_buffer_free(error);return {{QStringLiteral("error"),message}};
    }
    if(output.present>1)return {{QStringLiteral("error"),tr("The paper mapper returned an invalid anchor.")}};
    if(!output.present)return {{QStringLiteral("hit"),false}};
    // The shared anchor remains unclamped. Reject an unrepresentable Qt scene position
    // before a file-controlled double reaches QML's eventual QSG float transform.
    if(std::abs(output.y)>sceneCoordinateLimit)return {{QStringLiteral("error"),tr("The paper anchor is outside the scene coordinate range.")}};
    return {{QStringLiteral("hit"),true},{QStringLiteral("y"),output.y}};
}
QVariantMap PageItem::paperRegion(const QRectF &source,qulonglong revision)const {
    if(!m_controller || m_controller->loading() || m_page<0 || m_page>=m_controller->pageCount() || revision!=m_paperEpoch)return {{QStringLiteral("error"),tr("The page layout changed. Try again.")}};
    const double originalHeight=m_controller->pages().at(m_page).toMap().value(QStringLiteral("height")).toDouble();
    const auto layout=m_paperLayout.value_or(LyraReaderPaperLayout{originalHeight,0,0,0,0});
    LyraReaderPaperRegion output{};LyraReaderBuffer error{};
    if(!lyra_reader_desktop_paper_region(layout,width()/m_scale,{source.x(),source.y(),source.width(),source.height()},&output,&error)) {
        const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));lyra_reader_desktop_buffer_free(error);return {{QStringLiteral("error"),message}};
    }
    if(output.count>2)return {{QStringLiteral("error"),tr("The paper mapper returned an invalid region count.")}};
    if(!output.count)return {{QStringLiteral("hit"),false}};
    const auto rect=[](const LyraReaderTileRect &r){return QVariantMap{{QStringLiteral("x"),r.x},{QStringLiteral("y"),r.y},{QStringLiteral("width"),r.width},{QStringLiteral("height"),r.height}};};
    QVariantList pieces;for(std::uint32_t i=0;i<output.count;++i)pieces.append(rect(output.pieces[i]));
    return {{QStringLiteral("hit"),true},{QStringLiteral("bounds"),rect(output.bounds)},{QStringLiteral("pieces"),pieces}};
}
QVariantMap PageItem::paperPoint(const QPointF &display)const {
    if(!m_controller || m_controller->loading() || m_page<0 || m_page>=m_controller->pageCount())return {{QStringLiteral("error"),tr("The page is not ready. Try again.")}};
    const double originalHeight=m_controller->pages().at(m_page).toMap().value(QStringLiteral("height")).toDouble();
    const auto layout=m_paperLayout.value_or(LyraReaderPaperLayout{originalHeight,0,0,0,0});
    LyraReaderPaperHit output{};LyraReaderBuffer error{};
    if(!lyra_reader_desktop_paper_hit(layout,width()/m_scale,{display.x(),display.y()},&output,&error)) {
        const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));lyra_reader_desktop_buffer_free(error);return {{QStringLiteral("error"),message}};
    }
    if(output.present>1)return {{QStringLiteral("error"),tr("The paper mapper returned an invalid hit.")}};
    if(!output.present)return {{QStringLiteral("hit"),false}};
    return {{QStringLiteral("hit"),true},{QStringLiteral("x"),output.point.x},{QStringLiteral("y"),output.point.y}};
}
QVariantMap PageItem::paperEraserSegments(const QPointF &from,const QPointF &to)const {
    if(!m_controller || m_controller->loading() || m_page<0 || m_page>=m_controller->pageCount())return {{QStringLiteral("error"),tr("The page is not ready. Try the eraser again.")}};
    const double originalHeight=m_controller->pages().at(m_page).toMap().value(QStringLiteral("height")).toDouble();
    const auto layout=m_paperLayout.value_or(LyraReaderPaperLayout{originalHeight,0,0,0,0});
    LyraReaderPaperSegments output{};LyraReaderBuffer error{};
    if(!lyra_reader_desktop_paper_segments(layout,width()/m_scale,{from.x(),from.y()},{to.x(),to.y()},&output,&error)) {
        const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));lyra_reader_desktop_buffer_free(error);return {{QStringLiteral("error"),message}};
    }
    if(output.count>2)return {{QStringLiteral("error"),tr("The paper mapper returned an invalid segment count.")}};
    QVariantList result;
    for(std::uint32_t i=0;i<output.count;++i){const auto &s=output.pieces[i];result.append(QVariantMap{{QStringLiteral("from"),QVariantMap{{QStringLiteral("x"),s.from.x},{QStringLiteral("y"),s.from.y}}},{QStringLiteral("to"),QVariantMap{{QStringLiteral("x"),s.to.x},{QStringLiteral("y"),s.to.y}}}});}
    return {{QStringLiteral("segments"),result}};
}
void PageItem::setRasterScale(double scale) {if(!std::isfinite(scale) || scale<=0 || scale>maximumRasterScale || qFuzzyCompare(m_scale,scale))return;m_scale=scale;m_demandCurrent=false;setRefined(false);m_requestTimer.start();refresh();emit rasterScaleChanged();update();}
void PageItem::setPaperAppearance(const QString &appearance) {if(m_paperAppearance==appearance)return;m_paperAppearance=appearance;update();emit paperAppearanceChanged();}
void PageItem::setEmbeddedAnnotations(bool enabled) {if(m_embedded==enabled)return;m_embedded=enabled;resetImages();m_requestTimer.start();emit embeddedAnnotationsChanged();}
void PageItem::setTilesEnabled(bool enabled) {if(m_tilesEnabled==enabled)return;m_tilesEnabled=enabled;m_demandCurrent=false;setRefined(false);m_requestTimer.start();emit tilesEnabledChanged();}
void PageItem::setVisibleRegion(const QRectF &region) {
    if(m_visibleRegion==region)return;m_visibleRegion=region;m_demandCurrent=false;setRefined(false);
    // Geometry-only paper motion retains the current pixels and demand until the
    // final source band is known. Previously queued work may still finish normally.
    if(m_rasterDemandPaused){update();emit visibleRegionChanged();return;}
    syncBudget();
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
    if(m_rasterDemandPaused)return;
    syncBudget();if(!demandVisible())return;
    if(needsTiles()) {
        const auto plan=m_controller->requestTilesForSurface(quintptr(this),m_page,effectiveScale(),m_targetBytes,m_visibleRegion,QSet<QString>(m_tileImages.keyBegin(),m_tileImages.keyEnd()));
        // A rejected plan is not an empty, completed demand. Keep any old image
        // available while the Reader reports the failure, without claiming refinement.
        if(!plan.accepted){retireRevision();m_demandCurrent=false;setRefined(false);refresh();return;}
        const auto &next=plan.tiles;
        const int level=next.isEmpty()?m_level:next.first().level;
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
QSGNode *PageItem::paintFrame(QSGNode *old,bool previous,bool &blocked) {
    const auto &image=previous?m_revisionFrame->image:m_image;
    const auto &currentTiles=previous?m_revisionFrame->tiles:m_tiles;
    const auto &currentImages=previous?m_revisionFrame->images:m_tileImages;
    auto *root=static_cast<PageScene *>(old);
    if(!loaded() || width()<=0 || height()<=0){delete root;return nullptr;}
    if(!root)root=new PageScene;
    root->sourceEpoch=previous?m_revisionFrame->sourceEpoch:m_sourceEpoch;
    const int appearance=PaperAppearance::mode(m_paperAppearance);
    QStringList order;bool orderChanged=false;
    const auto append=[&](const QString &key,const ResidentImage &image,const PaperAppearance::Quad *quads,int count) {
        if(image.isNull())return;
        auto *node=root->images.value(key);
        if(!node){node=new BudgetedTexture(this);root->images.insert(key,node);root->appendChildNode(node);orderChanged=true;}
        if(!node->setImage(window(),image,appearance))blocked=true;
        if(node->empty())return;
        if(!node->setRects(quads,count))blocked=true;order.append(key);
    };
    struct Draw {QString key;ResidentImage image;QRectF target,source;};
    QVector<Draw> draws;
    const auto collect=[&](const QString &key,const ResidentImage &image,const QRectF &target,const QRectF &source) {
        if(image.isNull())return;
        if(m_paperLayout){draws.append({key,image,target,source});return;}
        // Keep the ordinary reader path free of paper-batch allocations or FFI calls.
        const QRectF logical=key==QStringLiteral("base")?boundingRect():QRectF(target.x()*m_scale,target.y()*m_scale,target.width()*m_scale,target.height()*m_scale);
        const PaperAppearance::Quad quad{logical,source};append(key,image,&quad,1);
    };
    const QRectF paper= m_paperLayout ? QRectF(0,0,width()/m_scale,m_paperLayout->height) : QRectF(0,0,width()/m_scale,height()/m_scale);
    collect(QStringLiteral("base"),image,paper,QRectF(0,0,1,1));
    const auto tiles=[&](const QList<TileSpec> &specs,const QHash<QString,ResidentImage> &images) {
        for(const auto &tile:specs) {
            if(!tile.target.intersects(m_visibleRegion))continue;
            const auto image=images.value(tile.key);if(image.isNull())continue;
            const QRectF texture((tile.target.x()-tile.render.x())*tile.scale/image.pixels.width(),(tile.target.y()-tile.render.y())*tile.scale/image.pixels.height(),tile.target.width()*tile.scale/image.pixels.width(),tile.target.height()*tile.scale/image.pixels.height());
            collect(tile.key,image,tile.target,texture);
        }
    };
    if(!previous)tiles(m_previousTiles,m_previousImages);tiles(currentTiles,currentImages);
    QVector<LyraReaderPaperQuadPair> mapped;
    if(m_paperLayout) {
        QVector<LyraReaderPaperQuad> requests;requests.reserve(draws.size());
        const auto rect=[](const QRectF &r){return LyraReaderTileRect{r.x(),r.y(),r.width(),r.height()};};
        for(const auto &draw:draws)requests.append({rect(draw.target),rect(draw.source)});
        mapped.resize(draws.size());LyraReaderBuffer error{};
        if(!lyra_reader_desktop_paper_quads(*m_paperLayout,requests.constData(),std::size_t(requests.size()),mapped.data(),&error)) {
            const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));lyra_reader_desktop_buffer_free(error);
            const auto epoch=m_paperEpoch;
            QMetaObject::invokeMethod(this,[this,epoch,message]{if(epoch==m_paperEpoch && message!=m_paperError){m_paperError=message;emit paperGeometryChanged();}},Qt::QueuedConnection);
            blocked=true;delete root;return nullptr;
        }
    }
    for(qsizetype i=0;i<draws.size();++i) {
        const auto &draw=draws[i];PaperAppearance::Quad quads[2];int count=1;
        const auto &pair=mapped[i];count=int(pair.count);
        for(int k=0;k<count;++k){const auto &q=pair.pieces[k];quads[k]={QRectF(q.target.x,q.target.y,q.target.width,q.target.height),QRectF(q.source.x,q.source.y,q.source.width,q.source.height)};}
        for(int k=0;k<count;++k){auto &r=quads[k].target;r=QRectF(r.x()*m_scale,r.y()*m_scale,r.width()*m_scale,r.height()*m_scale);}
        append(draw.key,draw.image,quads,count);
    }
    for(auto it=root->images.begin();it!=root->images.end();) {
        if(!order.contains(it.key())){root->removeChildNode(it.value());delete it.value();it=root->images.erase(it);}else ++it;
    }
    if(orderChanged || root->order!=order){for(const auto &key:order){auto *node=root->images.value(key);root->removeChildNode(node);root->appendChildNode(node);}root->order=order;}
    return root;
}
QSGNode *PageItem::updatePaintNode(QSGNode *old,UpdatePaintNodeData *) {
    auto *root=static_cast<PageScene *>(old);
    if(!loaded() || width()<=0 || height()<=0){delete root;return nullptr;}
    bool blocked=false,ready=false;
    if(m_revisionFrame) {
        // Draw one complete previous revision, never a mixture with new partial tiles.
        if(root && root->sourceEpoch!=m_revisionFrame->sourceEpoch){delete root;root=nullptr;}
        root=static_cast<PageScene *>(paintFrame(root,true,blocked));
        if(root && m_refined && (!m_image.isNull() || !m_tileImages.isEmpty())) {
            auto *next=root->staging;root->staging=nullptr;
            if(next && next->sourceEpoch!=m_sourceEpoch){delete next;next=nullptr;}
            bool nextBlocked=false;
            next=static_cast<PageScene *>(paintFrame(next,false,nextBlocked));
            if(next && !nextBlocked) {delete root;root=next;ready=true;}
            else {root->staging=next;blocked=true;}
        }
    }else {
        if(root && root->sourceEpoch!=m_sourceEpoch) {
            // Admission pressure may retire an old page. Reuse its partial staging
            // group, but never leave an old texture under a new source's stable key.
            auto *next=root->staging;root->staging=nullptr;delete root;root=next;
            if(root && root->sourceEpoch!=m_sourceEpoch){delete root;root=nullptr;}
        }
        root=static_cast<PageScene *>(paintFrame(root,false,blocked));ready=m_refined && !blocked;
    }
    ready=ready && root && (!m_image.isNull() || !m_tileImages.isEmpty());
    if(ready) {
        std::lock_guard lock(m_frameMutex);
        if(!m_acceptedFrame || root->acceptedDemandEpoch!=m_textureEpoch) {
            auto frame=std::make_shared<RevisionFrame>();frame->image=m_image;frame->tiles=m_tiles;frame->images=m_tileImages;frame->sourceEpoch=m_sourceEpoch;
            m_acceptedFrame=std::move(frame);root->acceptedDemandEpoch=m_textureEpoch;
        }
    }
    const auto epoch=m_textureEpoch,source=m_sourceEpoch;
    QMetaObject::invokeMethod(this,[this,epoch,source,ready,blocked] {
        if(source!=m_sourceEpoch)return;
        // Hard texture admission limits can make two complete revisions impossible.
        // Release the old one and retry; pressure is not a refined or successful page.
        if(blocked)clearAcceptedFrame();
        if(ready || blocked)retireRevision();
        if(epoch==m_textureEpoch && m_texturesReady!=ready){m_texturesReady=ready;emit texturesReadyChanged();}
        if(blocked)m_requestTimer.start(200);
    },Qt::QueuedConnection);
    return root;
}
