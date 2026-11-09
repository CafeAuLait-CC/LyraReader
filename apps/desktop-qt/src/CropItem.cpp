#include "CropItem.h"
#include "BudgetedTexture.h"
#include "NativeRaster.h"
#include "PaperAppearance.h"
#include "PageItem.h"
#include <QFutureWatcher>
#include <QtConcurrentRun>
#include <QUrlQuery>
#include <QQuickWindow>
#include <cmath>
namespace {struct CropResult {ResidentImage image;bool pressure=false;QString error;};}

CropItem::CropItem(QQuickItem *parent):QQuickItem(parent) {
    setFlag(ItemHasContents,true);m_timer.setSingleShot(true);m_timer.setInterval(70);
    connect(&m_timer,&QTimer::timeout,this,&CropItem::request);
    connect(RenderBudget::instance(),&RenderBudget::targetsChanged,this,[this] {
        const auto previous=m_target;syncBudget();
        if(previous!=m_target && active()){invalidate();m_timer.start();}
    });
}
CropItem::~CropItem(){for(const auto &c:m_paperConnections)QObject::disconnect(c);RasterJobs::cancel(m_job);RenderBudget::instance()->setClient(this,0);}
PageItem *CropItem::paperMap()const{return m_paperMap;}
void CropItem::geometryUpdated(){++m_geometryEpoch;update();emit paperGeometryChanged();}
void CropItem::setPaperMap(PageItem *page) {
    if(m_paperMap==page)return;
    for(const auto &c:m_paperConnections)QObject::disconnect(c);m_paperConnections.clear();m_paperMap=page;
    if(page) {
        m_paperConnections.append(connect(page,&PageItem::paperGeometryChanged,this,&CropItem::geometryUpdated));
        m_paperConnections.append(connect(page,&QObject::destroyed,this,&CropItem::geometryUpdated));
    }
    geometryUpdated();
}
void CropItem::setPaperRect(const QRectF &rect){if(m_paperRect==rect)return;m_paperRect=rect;geometryUpdated();}
void CropItem::setPaperZoom(double zoom){if(m_paperZoom==zoom)return;m_paperZoom=zoom;geometryUpdated();}
void CropItem::setPaperOrigin(const QPointF &origin){if(m_paperOrigin==origin)return;m_paperOrigin=origin;geometryUpdated();}
void CropItem::reportGeometryError(const QString &error) {
    if(m_geometryError==error)return;
    const auto epoch=m_geometryEpoch;
    QMetaObject::invokeMethod(this,[this,epoch,error]{if(epoch==m_geometryEpoch && m_geometryError!=error){m_geometryError=error;emit paperGeometryChanged();}},Qt::QueuedConnection);
}
void CropItem::setStatus(int status){if(m_status==status)return;m_status=status;emit statusChanged();}
bool CropItem::active()const{return m_resourceActive && isVisible() && window() && window()->isVisible() && window()->visibility()!=QWindow::Minimized && !m_source.isEmpty();}
void CropItem::scheduleVisibilityUpdate() {
    if(m_visibilityPending)return;m_visibilityPending=true;
    // A geometry binding can temporarily hide a clip and reveal it again in the same GUI
    // update. Decide resource ownership once the bindings settle, before starting any job.
    QTimer::singleShot(0,this,[this]{m_visibilityPending=false;visibilityUpdated();});
}
void CropItem::visibilityUpdated(){syncBudget();const bool visible=active();if(visible==m_lastActive)return;m_lastActive=visible;invalidate();if(visible)m_timer.start();else {m_timer.stop();m_image={};setStatus(0);update();}}
void CropItem::syncBudget(){RenderBudget::instance()->setClient(this,active()?8:0);m_target=RenderBudget::instance()->targetBytes(this);}
void CropItem::invalidate(){++m_epoch;RasterJobs::cancel(m_job);m_job.reset();}
void CropItem::setSource(const QUrl &source) {
    if(m_source==source)return;
    auto withoutPaper=[](QUrl value){QUrlQuery query(value);query.removeAllQueryItems(QStringLiteral("paper"));value.setQuery(query);return value;};
    const bool changed=withoutPaper(source)!=withoutPaper(m_source);m_source=source;emit sourceChanged();
    if(changed){invalidate();m_image={};m_error.clear();setStatus(source.isEmpty()?0:2);syncBudget();m_timer.start();update();}
}
void CropItem::setPaperAppearance(const QString &paper){if(m_paper==paper)return;m_paper=paper;emit paperAppearanceChanged();update();}
void CropItem::setResourceActive(bool value){if(m_resourceActive==value)return;m_resourceActive=value;scheduleVisibilityUpdate();emit resourceActiveChanged();}
void CropItem::itemChange(ItemChange change,const ItemChangeData &data) {
    QQuickItem::itemChange(change,data);
    if(change==ItemSceneChange){QObject::disconnect(m_visibilityConnection);if(window())m_visibilityConnection=connect(window(),&QWindow::visibilityChanged,this,&CropItem::visibilityUpdated);}
    if(change==ItemVisibleHasChanged || change==ItemSceneChange)scheduleVisibilityUpdate();
}
void CropItem::request() {
    syncBudget();if(!active() || m_job)return;
    auto ticket=RasterJobs::enqueue();if(!ticket){m_timer.start(200);return;}m_job=ticket;
    const auto epoch=m_epoch;const auto url=m_source;const auto bytes=qMax<qint64>(4096,m_target/2);setStatus(2);
    auto *watcher=new QFutureWatcher<CropResult>(this);
    connect(watcher,&QFutureWatcher<CropResult>::finished,this,[this,watcher,epoch,ticket] {
        auto result=watcher->result();watcher->deleteLater();if(epoch!=m_epoch)return;m_job.reset();
        if(ticket->cancelled.load())return;
        if(result.pressure){m_timer.start(200);return;}
        if(result.image.isNull()){m_error=result.error.isEmpty()?tr("The preview could not be rendered."):result.error;setStatus(3);return;}
        m_error.clear();m_image=std::move(result.image);setStatus(1);update();
    });
    watcher->setFuture(QtConcurrent::run(RasterJobs::pool(),[url,bytes,ticket] {
        RasterJobs::Run run(ticket);CropResult result;if(ticket->cancelled.load())return result;
        auto reservation=RenderBudget::reserve(RenderBudget::Kind::Resident,RenderBudget::maximumJobBytes);
        if(!reservation){result.pressure=true;return result;}
        auto image=NativeImageProvider::rawImage(url,bytes,&result.error);
        if(!image.isNull() && !ticket->cancelled.load())result.image=ResidentImage::publish(std::move(reservation),std::move(image));
        return result;
    }));
}
QSGNode *CropItem::updatePaintNode(QSGNode *old,UpdatePaintNodeData *) {
    auto *node=static_cast<BudgetedTexture *>(old);
    if(m_image.isNull()){delete node;return nullptr;}
    PaperAppearance::Quad quads[2]{{boundingRect(),QRectF(0,0,1,1)}};int count=1;
    if(m_paperMap && m_paperMap->paperGeometryActive()) {
        const auto fail=[&](const QString &message)->QSGNode *{reportGeometryError(message);delete node;return nullptr;};
        const double limit=m_paperMap->paperSceneLimit();
        if(!std::isfinite(m_paperZoom) || m_paperZoom<=0 || m_paperRect.width()<=0 || m_paperRect.height()<=0)
            return fail(tr("The image has invalid paper geometry."));
        for(double v:{m_paperRect.x(),m_paperRect.y(),m_paperRect.width(),m_paperRect.height(),m_paperRect.right(),m_paperRect.bottom(),m_paperOrigin.x(),m_paperOrigin.y()})
            if(!std::isfinite(v) || std::abs(v)>limit)return fail(tr("The image is outside the scene coordinate range."));
        // This page-owned crop keeps exactly one decoded image and texture. Only targets/UVs
        // change in the sync phase; the shared mapper owns split and tiny-gap semantics.
        const LyraReaderPaperQuad input{{m_paperRect.x(),m_paperRect.y(),m_paperRect.width(),m_paperRect.height()},{0,0,1,1}};
        LyraReaderPaperQuadPair output{};LyraReaderBuffer error{};
        if(!lyra_reader_desktop_paper_quads(*m_paperMap->paperLayout(),&input,1,&output,&error)) {
            const auto message=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));lyra_reader_desktop_buffer_free(error);return fail(message);
        }
        if(output.count<1 || output.count>2)return fail(tr("The image mapper returned an invalid segment count."));
        count=int(output.count);
        for(int i=0;i<count;++i) {
            const auto &q=output.pieces[i];
            for(double v:{q.target.x-m_paperOrigin.x(),q.target.y-m_paperOrigin.y(),q.target.width,q.target.height,q.target.x+q.target.width-m_paperOrigin.x(),q.target.y+q.target.height-m_paperOrigin.y()})
                if(!std::isfinite(v*m_paperZoom) || std::abs(v*m_paperZoom)>limit)return fail(tr("The image is outside the scene coordinate range."));
            quads[i]={QRectF((q.target.x-m_paperOrigin.x())*m_paperZoom,(q.target.y-m_paperOrigin.y())*m_paperZoom,q.target.width*m_paperZoom,q.target.height*m_paperZoom),QRectF(q.source.x,q.source.y,q.source.width,q.source.height)};
        }
    }
    reportGeometryError({});
    if(!node)node=new BudgetedTexture(this);
    if(!node->setImage(window(),m_image,PaperAppearance::mode(m_paper)))
        QMetaObject::invokeMethod(this,[this]{m_timer.start(200);},Qt::QueuedConnection);
    node->setRects(quads,count);return node;
}
