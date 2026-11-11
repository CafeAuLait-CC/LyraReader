#include "ContentDragItem.h"
#include "ReaderController.h"
#include "NativeRaster.h"
#include "PageItem.h"
#include "BudgetedTexture.h"
#include <QFutureWatcher>
#include <QQuickWindow>
#include <QtConcurrentRun>
#include <cmath>
namespace {
struct PairResult {ResidentImage background,foreground;QString error;};
class DragScene final:public QSGTransformNode {
public:
    BudgetedTexture *background,*foreground;
    explicit DragScene(QQuickItem *owner):background(new BudgetedTexture(owner)),foreground(new BudgetedTexture(owner)){appendChildNode(background);appendChildNode(foreground);}
};
}
ContentDragItem::ContentDragItem(QQuickItem *parent):QQuickItem(parent){
    setFlag(ItemHasContents,true);m_textureRetry.setSingleShot(true);m_textureRetry.setInterval(200);
    connect(&m_textureRetry,&QTimer::timeout,this,[this]{if(m_active)update();});
}
ContentDragItem::~ContentDragItem(){RasterJobs::cancel(m_job);}
ReaderController *ContentDragItem::controller()const{return m_controller;}
PageItem *ContentDragItem::paperMap()const{return m_map;}
void ContentDragItem::setController(ReaderController *value){
    if(value==m_controller)return;cancel();for(const auto &c:m_connections)disconnect(c);m_connections.clear();m_controller=value;
    if(value){
        m_connections.append(connect(value,&ReaderController::documentChanged,this,[this]{if(m_active && (m_controller->loading() || m_controller->fileUrl()!=m_ownerUrl || !m_controller->pageCount() || (m_controller->documentGeneration()!=m_generation && (!m_commit || m_committed || m_controller->documentGeneration()!=m_generation+1))))cancel();}));
        m_connections.append(connect(value,&ReaderController::commandFinished,this,[this](qulonglong id,const QString &op,const QVariant &,const QString &error){
            if(!m_active || id!=m_commit || op!=QStringLiteral("content_stage"))return;
            if(!error.isEmpty()){cancel();return;}m_generation=m_controller->documentGeneration();m_committed=true;finishWhenPainted();
        }));
    }
    emit stateChanged();
}
void ContentDragItem::setPaperMap(PageItem *value){
    if(value==m_map)return;for(const auto &c:m_mapConnections)disconnect(c);m_mapConnections.clear();m_map=value;
    if(value){m_mapConnections.append(connect(value,&PageItem::paperGeometryChanged,this,[this]{update();}));m_mapConnections.append(connect(value,&PageItem::texturesReadyChanged,this,&ContentDragItem::finishWhenPainted));}
    emit mappingChanged();update();finishWhenPainted();
}
void ContentDragItem::setOffset(const QPointF &value){if(value==m_offset || !std::isfinite(value.x()) || !std::isfinite(value.y()))return;m_offset=value;emit offsetChanged();update();}
void ContentDragItem::setZoom(double value){if(!std::isfinite(value) || value<=0 || value==m_zoom)return;if(m_active)cancel();m_zoom=value;emit mappingChanged();update();}
void ContentDragItem::setPaperAppearance(const QString &value){if(value==m_paper)return;m_paper=value;emit mappingChanged();update();}
void ContentDragItem::cancel(){
    ++m_epoch;RasterJobs::cancel(m_job);m_job.reset();m_textureRetry.stop();m_background={};m_foreground={};m_source.reset();m_active=false;m_committed=false;m_commit=0;m_status=0;m_error.clear();m_page=-1;m_offset={};emit offsetChanged();emit stateChanged();update();
}
void ContentDragItem::fail(const QString &message){m_status=3;m_error=message;emit stateChanged();}
void ContentDragItem::prepare(int page,const QString &target,const QString &revision,const QRectF &bounds){
    cancel();if(!m_controller || m_controller->loading() || page<0 || page>=m_controller->pageCount())return;
    for(double v:{bounds.x(),bounds.y(),bounds.width(),bounds.height(),bounds.right(),bounds.bottom()})if(!std::isfinite(v)){fail(tr("Invalid object preview bounds."));return;}
    const auto sheet=m_controller->pages().at(page).toMap();const QRectF limit(0,0,sheet.value("width").toDouble(),sheet.value("height").toDouble());
    m_region=bounds.adjusted(-2,-2,2,2).intersected(limit);if(m_region.isEmpty()){fail(tr("The object is outside the page."));return;}
    m_source=m_controller->renderSource();if(!m_source){fail(tr("The page is not ready for an object preview."));return;}
    auto ticket=RasterJobs::enqueue();if(!ticket){m_source.reset();fail(tr("The renderer is busy. You can still move the object."));return;}
    m_job=ticket;m_page=page;m_generation=m_controller->documentGeneration();m_ownerUrl=m_controller->fileUrl();m_active=true;m_status=2;++m_requests;
    const auto epoch=m_epoch;const auto source=m_source;const auto region=m_region;
    const qint64 half=qint64(qMin<std::size_t>(lyra_reader_desktop_drag_pair_limit(),std::size_t(RenderBudget::maximumJobBytes)))/2;
    double scale=qMin(m_zoom*(window()?window()->devicePixelRatio():1),qMin(8192.0/qMax(region.width(),region.height()),std::sqrt(double(half)/(4*region.width()*region.height()))));
    while(std::ceil(region.width()*scale)*std::ceil(region.height()*scale)*4>half)scale*=.99;
    auto *watcher=new QFutureWatcher<PairResult>(this);
    connect(watcher,&QFutureWatcher<PairResult>::finished,this,[this,watcher,epoch,ticket]{
        auto result=watcher->result();watcher->deleteLater();if(epoch!=m_epoch)return;m_job.reset();if(ticket->cancelled.load())return;
        if(!m_controller || (!m_commit && m_generation!=m_controller->documentGeneration())){cancel();return;}
        if(result.background.isNull() || result.foreground.isNull()){fail(result.error.isEmpty()?tr("Could not prepare the object preview. You can still move it."):result.error);return;}
        m_background=std::move(result.background);m_foreground=std::move(result.foreground);m_status=1;emit stateChanged();update();finishWhenPainted();
    });
    watcher->setFuture(QtConcurrent::run(RasterJobs::pool(),[source,page,target,revision,region,scale,ticket,half]{
        RasterJobs::Run run(ticket);PairResult result;if(ticket->cancelled.load())return result;
        auto bg=RenderBudget::reserve(RenderBudget::Kind::Resident,half),fg=RenderBudget::reserve(RenderBudget::Kind::Resident,half);
        if(!bg || !fg){result.error=QStringLiteral("Object preview is waiting for rendering resources.");return result;}
        const auto images=source->dragPreview(page,target,revision,region,scale,&result.error);if(ticket->cancelled.load())return result;
        if(!images.background.isNull() && !images.foreground.isNull()){result.background=ResidentImage::publish(std::move(bg),images.background);result.foreground=ResidentImage::publish(std::move(fg),images.foreground);}return result;
    }));
    emit stateChanged();
}
void ContentDragItem::hold(qulonglong command){if(m_active && command){m_commit=command;emit stateChanged();}}
void ContentDragItem::finishWhenPainted(){if(m_active && m_committed && m_map && m_map->controller()==m_controller && m_controller->documentGeneration()==m_generation && m_map->texturesReady())cancel();}
void ContentDragItem::windowVisibilityChanged(){if(window() && (!window()->isVisible() || window()->visibility()==QWindow::Minimized))cancel();}
void ContentDragItem::itemChange(ItemChange change,const ItemChangeData &data){QQuickItem::itemChange(change,data);if(change==ItemSceneChange){for(const auto &c:m_windowConnections)disconnect(c);m_windowConnections.clear();if(window()){m_windowConnections.append(connect(window(),&QWindow::visibilityChanged,this,&ContentDragItem::windowVisibilityChanged));m_windowConnections.append(connect(window(),&QWindow::screenChanged,this,[this]{cancel();}));}}}
QSGNode *ContentDragItem::updatePaintNode(QSGNode *old,UpdatePaintNodeData *){
    auto *node=static_cast<DragScene *>(old);if(!m_active || m_background.isNull() || m_foreground.isNull() || !m_map){delete node;return nullptr;}
    if(!node)node=new DragScene(this);
    // Publish the two scene textures together. A single admitted foreground must
    // never be drawn over the unmasked original when the background is blocked.
    if(!node->background->setImage(window(),m_background,PaperAppearance::mode(m_paper)) || !node->foreground->setImage(window(),m_foreground,PaperAppearance::mode(m_paper))){delete node;QMetaObject::invokeMethod(this,[this]{if(m_active)m_textureRetry.start();},Qt::QueuedConnection);return nullptr;}
    const auto epoch=m_epoch;
    const auto invalid=[this,epoch]{QMetaObject::invokeMethod(this,[this,epoch]{if(m_epoch==epoch){cancel();fail(tr("The object preview has invalid paper geometry."));}},Qt::QueuedConnection);};
    const auto apply=[&](BudgetedTexture *texture,const ResidentImage &image,const QRectF &rect)->bool {
        PaperAppearance::Quad quads[2]{{QRectF(rect.x()*m_zoom,rect.y()*m_zoom,rect.width()*m_zoom,rect.height()*m_zoom),QRectF(0,0,1,1)}};int count=1;
        if(m_map->paperGeometryActive()){
            const LyraReaderPaperQuad input{{rect.x(),rect.y(),rect.width(),rect.height()},{0,0,1,1}};LyraReaderPaperQuadPair output{};LyraReaderBuffer error{};
            if(!lyra_reader_desktop_paper_quads(*m_map->paperLayout(),&input,1,&output,&error)){lyra_reader_desktop_buffer_free(error);return false;}
            if(output.count<1 || output.count>2)return false;count=int(output.count);
            for(int i=0;i<count;++i){const auto &q=output.pieces[i];quads[i]={QRectF(q.target.x*m_zoom,q.target.y*m_zoom,q.target.width*m_zoom,q.target.height*m_zoom),QRectF(q.source.x,q.source.y,q.source.width,q.source.height)};}
        }
        for(int i=0;i<count;++i)for(double v:{quads[i].target.x(),quads[i].target.y(),quads[i].target.width(),quads[i].target.height(),quads[i].target.right(),quads[i].target.bottom()})if(!std::isfinite(v) || std::abs(v)>m_map->paperSceneLimit())return false;
        Q_UNUSED(image);
        return texture->setRects(quads,count);
    };
    if(!apply(node->background,m_background,m_region) || !apply(node->foreground,m_foreground,m_region.translated(m_offset))){delete node;invalid();return nullptr;}return node;
}
