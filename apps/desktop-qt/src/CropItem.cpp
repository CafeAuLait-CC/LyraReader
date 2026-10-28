#include "CropItem.h"
#include "BudgetedTexture.h"
#include "NativeRaster.h"
#include "PaperAppearance.h"
#include <QFutureWatcher>
#include <QtConcurrentRun>
#include <QUrlQuery>
#include <QQuickWindow>
namespace {struct CropResult {ResidentImage image;bool pressure=false;QString error;};}

CropItem::CropItem(QQuickItem *parent):QQuickItem(parent) {
    setFlag(ItemHasContents,true);m_timer.setSingleShot(true);m_timer.setInterval(70);
    connect(&m_timer,&QTimer::timeout,this,&CropItem::request);
    connect(RenderBudget::instance(),&RenderBudget::targetsChanged,this,[this] {
        const auto previous=m_target;syncBudget();
        if(previous!=m_target && active()){invalidate();m_timer.start();}
    });
}
CropItem::~CropItem(){RasterJobs::cancel(m_job);RenderBudget::instance()->setClient(this,0);}
void CropItem::setStatus(int status){if(m_status==status)return;m_status=status;emit statusChanged();}
bool CropItem::active()const{return m_resourceActive && isVisible() && window() && window()->isVisible() && window()->visibility()!=QWindow::Minimized && !m_source.isEmpty();}
void CropItem::visibilityUpdated(){syncBudget();invalidate();if(active())m_timer.start();else {m_timer.stop();m_image={};setStatus(0);update();}}
void CropItem::syncBudget(){RenderBudget::instance()->setClient(this,active()?8:0);m_target=RenderBudget::instance()->targetBytes(this);}
void CropItem::invalidate(){++m_epoch;RasterJobs::cancel(m_job);m_job.reset();}
void CropItem::setSource(const QUrl &source) {
    if(m_source==source)return;
    auto withoutPaper=[](QUrl value){QUrlQuery query(value);query.removeAllQueryItems(QStringLiteral("paper"));value.setQuery(query);return value;};
    const bool changed=withoutPaper(source)!=withoutPaper(m_source);m_source=source;emit sourceChanged();
    if(changed){invalidate();m_image={};m_error.clear();setStatus(source.isEmpty()?0:2);syncBudget();m_timer.start();update();}
}
void CropItem::setPaperAppearance(const QString &paper){if(m_paper==paper)return;m_paper=paper;emit paperAppearanceChanged();update();}
void CropItem::setResourceActive(bool value){if(m_resourceActive==value)return;m_resourceActive=value;syncBudget();invalidate();if(active())m_timer.start();else {m_timer.stop();m_image={};setStatus(0);update();}emit resourceActiveChanged();}
void CropItem::itemChange(ItemChange change,const ItemChangeData &data) {
    QQuickItem::itemChange(change,data);
    if(change==ItemSceneChange){QObject::disconnect(m_visibilityConnection);if(window())m_visibilityConnection=connect(window(),&QWindow::visibilityChanged,this,&CropItem::visibilityUpdated);}
    if(change==ItemVisibleHasChanged || change==ItemSceneChange)visibilityUpdated();
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
    if(!node)node=new BudgetedTexture(this);
    if(!node->setImage(window(),m_image,PaperAppearance::mode(m_paper)))
        QMetaObject::invokeMethod(this,[this]{m_timer.start(200);},Qt::QueuedConnection);
    node->setRect(boundingRect());return node;
}
