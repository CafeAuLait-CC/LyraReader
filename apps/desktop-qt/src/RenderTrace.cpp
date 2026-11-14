#include "RenderTrace.h"
#include "PageItem.h"
#include <QFile>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJSValue>
#include <QMap>
#include <QQuickWindow>
#include <QSet>
#include <QThread>
#include <QTransform>
#include <QUuid>
#include <algorithm>
#include <cmath>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <limits>
#include <system_error>

namespace RenderTrace {
double now(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
namespace {
constexpr qint64 maximumEventBytes=1024*1024;
const QByteArray prefix=QByteArrayLiteral("lyra-reader-perf-trace: ");
QJsonObject gap(quint64 count){return {{"kind","trace-gap"},{"time",now()},{"dropped_records",qint64(count)}};}
}
struct Sink::State {
    mutable std::mutex mutex;
    std::condition_variable wake;
    std::deque<QByteArray> queue;
    qsizetype maximumRecords=0;
    qint64 maximumPayload=0,payload=0;
    quint64 dropped=0,reported=0;
    bool stopping=false,failed=false,file=false;
    QString error;
};
Sink::Sink(qsizetype records,qint64 bytes):m_state(std::make_shared<State>()) {
    m_state->maximumRecords=records;m_state->maximumPayload=bytes;
    record({{"kind","trace-start"},{"time",now()},{"schema_version",1},{"backend","qt-scene"},{"clock","steady-clock-seconds"},{"compiled_qt",QT_VERSION_STR},{"runtime_qt",qVersion()},
        {"presentation_measurement","unavailable"},{"presentation_reason","Qt scene callbacks do not expose a compositor presentation timestamp."}});
}
std::shared_ptr<Sink> Sink::memory(qsizetype records,qint64 bytes) {
    if(records<1 || records>65536 || bytes<128 || bytes>64*1024*1024)return {};
    return std::shared_ptr<Sink>(new Sink(records,bytes));
}
std::shared_ptr<Sink> Sink::file(const QString &newPath,qint64 maximumBytes) {
    if(newPath.isEmpty() || maximumBytes<4096 || maximumBytes>1024LL*1024*1024)return {};
    auto sink=std::shared_ptr<Sink>(new Sink(512,8*1024*1024));auto state=sink->m_state;state->file=true;
    try {
        sink->m_writer=std::thread([state,newPath,maximumBytes] {
            const auto fail=[&](const QString &message){std::lock_guard lock(state->mutex);state->error=message;state->failed=true;state->queue.clear();state->payload=0;};
            QFile output(newPath);
            if(!output.open(QIODevice::WriteOnly|QIODevice::NewOnly)){fail(QStringLiteral("Render trace could not create a new log: ")+output.errorString().left(2048));return;}
            qint64 written=0;
            const auto write=[&](const QByteArray &json) {
                const auto line=prefix+json+'\n';
                if(line.size()>maximumBytes-written){fail(QStringLiteral("Render trace reached its file capacity; the measurement is incomplete."));return false;}
                if(output.write(line)!=line.size()){fail(QStringLiteral("Render trace write failed: ")+output.errorString().left(2048));return false;}
                written+=line.size();return true;
            };
            while(true) {
                QByteArray event;quint64 lost=0;bool stop=false;
                {
                    std::unique_lock lock(state->mutex);state->wake.wait(lock,[&]{return state->stopping || !state->queue.empty();});
                    if(state->dropped!=state->reported){lost=state->dropped;state->reported=lost;}
                    if(!state->queue.empty()){event=std::move(state->queue.front());state->queue.pop_front();state->payload-=event.size();}
                    else stop=state->stopping;
                }
                if(lost && !write(QJsonDocument(gap(lost)).toJson(QJsonDocument::Compact)))return;
                if(!event.isEmpty() && !write(event))return;
                if(stop)break;
            }
            quint64 lost;{std::lock_guard lock(state->mutex);lost=state->dropped;}
            if(!write(QJsonDocument(QJsonObject{{"kind","trace-end"},{"time",now()},{"dropped_records",qint64(lost)}}).toJson(QJsonDocument::Compact)))return;
            if(!output.flush())fail(QStringLiteral("Render trace flush failed: ")+output.errorString().left(2048));
        });
    }catch(const std::system_error &) {
        std::lock_guard lock(state->mutex);state->failed=true;state->error=QStringLiteral("The render trace writer thread could not start.");
    }
    return sink;
}
Sink::~Sink(){finish();}
bool Sink::record(const QJsonObject &event) {
    // Events contain a capped number of geometry entries. Serialization has a measurable,
    // opt-in CPU cost; only the writer thread performs file I/O.
    const auto bytes=QJsonDocument(event).toJson(QJsonDocument::Compact);
    std::lock_guard lock(m_state->mutex);
    if(m_state->stopping || m_state->failed || bytes.size()>maximumEventBytes ||
       qsizetype(m_state->queue.size())>=m_state->maximumRecords || bytes.size()>m_state->maximumPayload-m_state->payload) {
        ++m_state->dropped;
        if(m_state->error.isEmpty())m_state->error=QStringLiteral("Render trace dropped diagnostic records; the measurement is incomplete.");
        return false;
    }
    m_state->payload+=bytes.size();m_state->queue.push_back(bytes);m_state->wake.notify_one();return true;
}
QList<QJsonObject> Sink::takeRecords() {
    std::deque<QByteArray> queue;quint64 lost=0;
    {
        std::lock_guard lock(m_state->mutex);
        if(m_state->file)return {};
        queue.swap(m_state->queue);m_state->payload=0;
        if(m_state->reported!=m_state->dropped){lost=m_state->dropped;m_state->reported=lost;}
    }
    QList<QJsonObject> result;if(lost)result.append(gap(lost));
    for(const auto &bytes:queue)result.append(QJsonDocument::fromJson(bytes).object());
    return result;
}
QString Sink::error()const{std::lock_guard lock(m_state->mutex);return m_state->error;}
quint64 Sink::dropped()const{std::lock_guard lock(m_state->mutex);return m_state->dropped;}
void Sink::finish() {
    {
        std::lock_guard lock(m_state->mutex);
        if(!m_state->stopping && !m_state->file) {
            const auto bytes=QJsonDocument(QJsonObject{{"kind","trace-end"},{"time",now()},{"dropped_records",qint64(m_state->dropped)}}).toJson(QJsonDocument::Compact);
            if(qsizetype(m_state->queue.size())<m_state->maximumRecords && bytes.size()<=m_state->maximumPayload-m_state->payload){m_state->queue.push_back(bytes);m_state->payload+=bytes.size();}
            else {++m_state->dropped;if(m_state->error.isEmpty())m_state->error=QStringLiteral("Render trace could not retain its final diagnostic record.");}
        }
        m_state->stopping=true;m_state->wake.notify_all();
    }
    // Called after the observer is stopped, never from a render callback or the writer.
    if(m_writer.joinable())m_writer.join();
}

struct Window::State {
    struct Gui {
        QPointer<ReaderController> reader;
        int anchor=-1;
        double zoom=0,offset=0;
        bool offsetKnown=false;
        QString mode=QStringLiteral("unavailable"),role=QStringLiteral("standalone");
    } gui;
    mutable std::mutex mutex;
    std::atomic<bool> active{true};
    std::shared_ptr<Sink> sink;
    QString instance=QUuid::createUuid().toString(QUuid::WithoutBraces),parentInstance,diagnostic;
    quint64 contentSeq=0,frameSeq=0,epoch=0,generation=0,revision=0;
    QPointer<ReaderController> reader;
    QJsonObject latest,frozen;
    QList<std::weak_ptr<SceneState>> scenes;
};
namespace {
bool finite(const QRectF &r){return std::isfinite(r.x()) && std::isfinite(r.y()) && std::isfinite(r.width()) && std::isfinite(r.height());}
QJsonArray rectangle(const QRectF &r){return {r.x(),r.y(),r.width(),r.height()};}
bool axisAligned(QQuickItem *item,QQuickWindow *window) {
    bool valid=false;const auto transform=item->itemTransform(window->contentItem(),&valid);
    const bool axes=(qFuzzyIsNull(transform.m12()) && qFuzzyIsNull(transform.m21())) || (qFuzzyIsNull(transform.m11()) && qFuzzyIsNull(transform.m22()));
    return valid && transform.isAffine() && axes;
}
QRectF visiblePaper(PageItem *item,QQuickWindow *window,bool &unsupported) {
    if(!window->isVisible() || window->visibility()==QWindow::Minimized || !item->isVisible())return {};
    QRectF clip(0,0,window->width(),window->height());
    for(auto *parent=static_cast<QQuickItem *>(item);parent;parent=parent->parentItem()) {
        if(!std::isfinite(parent->opacity())){unsupported=true;return {};}
        if(parent->opacity()<=0)return {};
        if(parent->clip()) {
            if(!axisAligned(parent,window)){unsupported=true;return {};}
            const auto bounds=parent->mapRectToScene(parent->boundingRect());if(!finite(bounds)){unsupported=true;return {};}
            clip=clip.intersected(bounds);
        }
    }
    if(!axisAligned(item,window)){unsupported=true;return {};}
    const auto bounds=item->mapRectToScene(item->boundingRect());if(!finite(bounds)){unsupported=true;return {};}
    return clip.intersected(bounds);
}
QString contentSource(const QSet<QString> &sources,bool sharp) {
    if(sources.isEmpty())return QStringLiteral("none");
    if(sharp && sources.contains(QStringLiteral("tile")))return QStringLiteral("tile");
    if(sharp && sources.contains(QStringLiteral("page-raster")))return QStringLiteral("page-raster");
    for(const auto *name:{"partial-tile","previous-tile","history","preview","previous-raster","page-raster","tile"})
        if(sources.contains(QLatin1String(name)))return QLatin1String(name);
    return QStringLiteral("unattributed");
}
bool increment(quint64 &value) {
    if(value>=quint64(std::numeric_limits<qint64>::max()))return false;
    ++value;return true;
}
QJsonObject frame(const QJsonObject &content,const QString &instance,quint64 frameSeq,const QString &stage) {
    QJsonObject result{{"kind","frame"},{"time",now()},{"instance",instance},{"frame_seq",qint64(frameSeq)},
        {"stage",stage},{"presented",false},{"presented_time","unavailable"},
        {"presented_reason","Qt scene callbacks do not expose compositor presentation timestamps."}};
    for(const auto *key:{"content_seq","epoch","anchor_page","anchor_source","page_quads","anchor_page_quads","paper_quads","tile_quads","content_pages","surface","offset_pt","mode","window_role","parent_instance","geometry_unsupported","truncated"})
        if(content.contains(QLatin1String(key)))result.insert(QLatin1String(key),content.value(QLatin1String(key)));
    if(content.isEmpty())result.insert(QStringLiteral("unattributed"),true);
    return result;
}
}
Window *Window::observer(QQuickWindow *window){return window?window->findChild<Window *>(QStringLiteral("lyraRenderTraceObserver"),Qt::FindDirectChildrenOnly):nullptr;}
Window *Window::attach(QQuickWindow *window,const std::shared_ptr<Sink> &sink) {
    if(!window || !sink || QThread::currentThread()!=window->thread())return nullptr;
    if(auto *existing=observer(window))return existing->sink()==sink?existing:nullptr;
    return new Window(window,sink);
}
void Window::inherit(QQuickWindow *window) {
    if(!window || QThread::currentThread()!=window->thread() || observer(window))return;
    QSet<QWindow *> seen;
    for(auto *parent=window->transientParent();parent && !seen.contains(parent);parent=parent->transientParent()) {
        seen.insert(parent);
        if(auto *owner=observer(qobject_cast<QQuickWindow *>(parent))){new Window(window,owner->sink(),owner->instanceId());return;}
    }
}
std::shared_ptr<Sink> Window::sink()const{return m_state->sink;}
QString Window::instanceId()const{return m_state->instance;}
void Window::captureGui() {
    if(!m_window)return;
    State::Gui gui;const bool preview=m_window->objectName()==QStringLiteral("pdfPreviewWindow");
    gui.role=preview?QStringLiteral("pdf-preview"):m_window->objectName()==QStringLiteral("readerWindow")?QStringLiteral("reader"):QStringLiteral("standalone");
    // QML properties are evaluated only here on the GUI thread, never in render callbacks.
    const auto value=m_window->property(preview?"previewReader":"currentReader");
    gui.reader=value.value<ReaderController *>();
    if(!gui.reader && value.metaType()==QMetaType::fromType<QJSValue>())gui.reader=qobject_cast<ReaderController *>(value.value<QJSValue>().toQObject());
    bool anchorKnown=false;gui.anchor=m_window->property(preview?"page":"currentPage").toInt(&anchorKnown);if(!anchorKnown)gui.anchor=-1;
    bool zoomKnown=false;gui.zoom=m_window->property("zoom").toDouble(&zoomKnown);if(!zoomKnown || !std::isfinite(gui.zoom) || gui.zoom<=0)gui.zoom=0;
    gui.mode=m_window->property(preview?"textMode":"textViewVisible").toBool()?QStringLiteral("text"):m_window->property("overviewVisible").toBool()?QStringLiteral("overview"):QStringLiteral("pdf-canvas");
    if(!preview) {
        const auto view=m_window->property("pageList").value<QQuickItem *>();
        if(view && gui.zoom>0) {
            bool yKnown=false,originKnown=false;const auto y=view->property("contentY").toDouble(&yKnown),origin=view->property("originY").toDouble(&originKnown);
            gui.offset=(y-origin)/gui.zoom;gui.offsetKnown=yKnown && originKnown && std::isfinite(gui.offset);
        }
    }
    std::lock_guard lock(m_state->mutex);m_state->gui=gui;
}
Window::Window(QQuickWindow *window,std::shared_ptr<Sink> sink,const QString &parentInstance):QObject(window),m_window(window),m_state(std::make_shared<State>()) {
    setObjectName(QStringLiteral("lyraRenderTraceObserver"));m_state->sink=std::move(sink);m_state->parentInstance=parentInstance;window->setProperty("lyraRenderTraceEnabled",true);
    for(auto *item:PageItem::traceItems(window))item->setSceneTraceEnabled(!item->embeddedAnnotations());
    captureGui();
    m_connections.append(connect(window,&QQuickWindow::afterAnimating,this,&Window::captureGui));
    m_connections.append(connect(window,&QQuickWindow::afterSynchronizing,window,[state=m_state,window] {
        if(!state->active)return;
        State::Gui gui;{std::lock_guard lock(state->mutex);gui=state->gui;}
        QPointer<ReaderController> reader=gui.reader;bool haveVisibleController=false,contextMismatch=false;
        QList<std::weak_ptr<SceneState>> scenes;
        QJsonArray details;QMap<int,QString> sources;QSet<int> nonempty;bool unsupported=false,truncated=false,allSharp=true,duplicate=false;
        int pageQuads=0,paperQuads=0,tileQuads=0,anchorQuads=0;
        // This callback is direct, after updatePaintNode, with the GUI thread blocked by Qt.
        // Only C++ getters and committed scene metadata are read in this section.
        for(auto *item:PageItem::traceItems(window)) {
            if(auto scene=item->sceneTraceState()) {
                if(scenes.size()>=SceneState::maximumQuads){truncated=true;break;}
                scenes.append(scene);
            }
            if(item->embeddedAnnotations() || item->pageIndex()<0)continue;
            const auto paper=visiblePaper(item,window,unsupported);if(paper.isEmpty())continue;
            if(item->controller() && item->pageIndex()>=item->controller()->pageCount()){unsupported=true;continue;}
            if(paperQuads>=512 || pageQuads>=SceneState::maximumQuads){truncated=true;break;}
            if(!haveVisibleController){reader=item->controller();haveVisibleController=true;}
            if(item->controller()!=reader){contextMismatch=true;continue;}
            const auto snapshot=item->sceneTraceSnapshot();truncated=truncated || snapshot.truncated;
            const auto page=item->pageIndex();QJsonArray quads;QSet<QString> roles;int count=0;
            for(const auto &quad:snapshot.quads) {
                if(pageQuads>=SceneState::maximumQuads){truncated=true;break;}
                const auto mapped=item->mapRectToScene(quad.target);if(!finite(mapped)){unsupported=true;continue;}
                const auto clipped=mapped.intersected(paper);if(clipped.isEmpty())continue;
                quads.append(QJsonObject{{"rect",rectangle(clipped)},{"source",quad.source},{"retained_after_rejection",quad.retainedAfterRejection}});roles.insert(quad.source);++count;++pageQuads;
                if(quad.source.contains(QStringLiteral("tile")))++tileQuads;
                if(page==gui.anchor)++anchorQuads;
            }
            const bool sharp=count>0 && snapshot.complete && item->refined() && !snapshot.revision && snapshot.sourceEpoch==item->traceSourceEpoch();
            const auto source=contentSource(roles,sharp);if(sources.contains(page))duplicate=true;sources.insert(page,source);if(count)nonempty.insert(page);
            details.append(QJsonObject{{"page",page},{"source",source},{"source_epoch",qint64(snapshot.sourceEpoch)},{"desired_source_epoch",qint64(item->traceSourceEpoch())},
                {"revision_fallback",snapshot.revision},{"sharp",sharp},{"paper_rect",rectangle(paper)},{"quads",quads}});
            allSharp=allSharp && sharp;++paperQuads;
        }
        const bool contextMatches=!contextMismatch && reader==gui.reader;
        const int pageCount=reader?reader->pageCount():0;
        const int anchor=contextMatches && gui.anchor>=0 && gui.anchor<pageCount?gui.anchor:-1;
        const auto generation=reader?reader->documentGeneration():0,revision=reader?reader->editRevision():0;
        QJsonArray pages,labels,contentPages;for(auto it=sources.cbegin();it!=sources.cend();++it){pages.append(it.key());labels.append(it.value());}
        QList<int> visible=nonempty.values();std::sort(visible.begin(),visible.end());for(auto page:visible)contentPages.append(page);
        QJsonObject event;
        {
            std::lock_guard lock(state->mutex);
            if(!increment(state->contentSeq)){state->diagnostic=QStringLiteral("Render trace sequence exhausted.");state->active=false;return;}
            if(!state->epoch || state->reader!=reader || state->generation!=generation || state->revision!=revision) {
                if(!increment(state->epoch)){state->diagnostic=QStringLiteral("Render trace document epoch exhausted.");state->active=false;return;}
                state->reader=reader;state->generation=generation;state->revision=revision;
            }
            event={{"kind","content"},{"time",now()},{"instance",state->instance},{"content_seq",qint64(state->contentSeq)},{"epoch",qint64(state->epoch)},
                {"document_generation",qint64(generation)},{"edit_revision",qint64(revision)},{"page_count",reader?reader->pageCount():0},{"anchor_page",anchor},{"anchor_source",anchor>=0?sources.value(anchor,QStringLiteral("none")):QStringLiteral("unavailable")},
                {"context_mismatch",!contextMatches},{"offset_pt",gui.offsetKnown?QJsonValue(gui.offset):QJsonValue(QJsonValue::Null)},{"mode",gui.mode},{"window_role",gui.role},{"parent_instance",state->parentInstance},
                {"pages",pages},{"sources",labels},{"content_pages",contentPages},{"page_sources",details},{"sharp",paperQuads>0 && allSharp && contextMatches && !unsupported && !truncated && !duplicate},
                {"page_quads",pageQuads},{"paper_quads",paperQuads},{"tile_quads",tileQuads},{"anchor_page_quads",anchor>=0?anchorQuads:0},
                {"geometry_unsupported",unsupported},{"truncated",truncated},{"duplicate_page_items",duplicate},
                {"quad_basis","clipped_scene_geometry_before_renderer_and_compositor_occlusion"},
                {"coordinate_space","window_scene_logical_px"},
                {"surface",QJsonObject{{"width",window->width()},{"height",window->height()},{"dpr",window->effectiveDevicePixelRatio()},{"graphics_api",int(window->rendererInterface()->graphicsApi())},{"exposed",window->isExposed()}}}};
            state->latest=event;state->scenes=std::move(scenes);
        }
        // Admission failures remain in the sink and are surfaced by GUI diagnostics;
        // a diagnostic gap must not block drawing or a PDF operation.
        state->sink->record(event);
    },Qt::DirectConnection));
    m_connections.append(connect(window,&QQuickWindow::beforeRendering,window,[state=m_state] {
        if(!state->active)return;std::lock_guard lock(state->mutex);
        if(state->latest.isEmpty()){state->frozen={};return;}
        if(!increment(state->frameSeq)){state->diagnostic=QStringLiteral("Render trace frame sequence exhausted.");state->active=false;return;}
        state->frozen=state->latest;
    },Qt::DirectConnection));
    const auto terminal=[state=m_state](const QString &stage) {
        if(!state->active)return;QJsonObject content;quint64 sequence;
        {std::lock_guard lock(state->mutex);content=state->frozen;sequence=state->frameSeq;}
        if(!sequence) {
            // An observer attached to an already rendering window can see the tail
            // of a frame whose beforeRendering signal preceded the attachment.
            // Record this boundary explicitly; measurement starts at the next full frame.
            state->sink->record({{"kind","trace-boundary"},{"time",now()},{"instance",state->instance},
                {"stage",stage},{"reason","observer-attached-after-frame-start"}});
            return;
        }
        state->sink->record(frame(content,state->instance,sequence,stage));
    };
    m_connections.append(connect(window,&QQuickWindow::frameSwapped,window,[terminal]{terminal(QStringLiteral("scene-queued"));},Qt::DirectConnection));
    m_connections.append(connect(window,&QQuickWindow::afterFrameEnd,window,[terminal]{terminal(QStringLiteral("scene-submitted"));},Qt::DirectConnection));
    const auto invalidate=[state=m_state] {
        QList<std::weak_ptr<SceneState>> scenes;
        {std::lock_guard lock(state->mutex);state->latest={};state->frozen={};scenes=state->scenes;}
        // The stop callback may run without the GUI lock. Never inspect QQuickItems here.
        for(const auto &weak:scenes)if(auto scene=weak.lock()){std::lock_guard lock(scene->mutex);scene->owner=nullptr;scene->scene={};}
    };
    m_connections.append(connect(window,&QQuickWindow::sceneGraphAboutToStop,window,invalidate,Qt::DirectConnection));
    m_connections.append(connect(window,&QQuickWindow::sceneGraphInvalidated,window,invalidate,Qt::DirectConnection));
    m_diagnostics.setInterval(100);connect(&m_diagnostics,&QTimer::timeout,this,[this] {
        auto error=m_state->sink->error();{std::lock_guard lock(m_state->mutex);if(error.isEmpty())error=m_state->diagnostic;}
        if(error.isEmpty() || !m_window || error==property("lastDiagnostic").toString())return;
        setProperty("lastDiagnostic",error);qWarning().noquote()<<error;
        if(m_window->property("operationStatus").isValid())m_window->setProperty("operationStatus",error);
    });m_diagnostics.start();
}
Window::~Window() {
    m_state->active=false;for(const auto &connection:m_connections)QObject::disconnect(connection);
    if(m_window){m_window->setProperty("lyraRenderTraceEnabled",false);for(auto *item:PageItem::traceItems(m_window))item->setSceneTraceEnabled(false);}
}
}
