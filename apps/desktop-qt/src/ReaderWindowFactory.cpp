#include "ReaderWindowFactory.h"
#include "WorkspaceController.h"
#include "NativeRaster.h"
#include "RenderTrace.h"
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTimer>

namespace {
void finishTransfer(QPointer<WorkspaceController> source,QPointer<QQuickWindow> oldWindow,
                    QPointer<QQuickWindow> window,QPointer<ReaderController> emptySource) {
    if(window){if(window->visibility()==QWindow::Minimized)window->showNormal();else window->show();}
    if(window)window->raise();
    if(window)window->requestActivate();
    if(window && window->isVisible() && emptySource && source && oldWindow && source->tabs().size()==1 && source->activeReader()==emptySource && emptySource->fileUrl().isEmpty()) {
        QVariant reason;
        if(QMetaObject::invokeMethod(oldWindow,"tabTransferUiBlockReason",Q_RETURN_ARG(QVariant,reason)) && reason.toString().isEmpty() && oldWindow)oldWindow->close();
    }
}
}
QQuickWindow *ReaderWindowFactory::createWindow(const QUrl &url,int page,double y,bool visible) {
    auto *engine=new QQmlApplicationEngine(this);
    engine->addImageProvider(QStringLiteral("lyrapreview"),new NativeImageProvider);
    auto *workspace=new WorkspaceController(engine);
    engine->rootContext()->setContextProperty(QStringLiteral("workspace"),workspace);
    engine->setInitialProperties({{QStringLiteral("visible"),visible}});
    engine->load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
    auto *window=engine->rootObjects().isEmpty() ? nullptr : qobject_cast<QQuickWindow *>(engine->rootObjects().first());
    if(!window){delete engine;return nullptr;}
    window->setPersistentSceneGraph(false);
    window->setProperty("requestedPage",page);
    window->setProperty("requestedY",y);
    if(m_renderTrace)RenderTrace::Window::attach(window,m_renderTrace);
    connect(workspace,&WorkspaceController::newWindowRequested,this,[this](const QUrl &file,int targetPage,double targetY){createWindow(file,targetPage,targetY);});
    connect(workspace,&WorkspaceController::detachActiveTabRequested,this,[this,owner=QPointer<WorkspaceController>(workspace),window=QPointer<QQuickWindow>(window)]{if(owner && window)detachActiveTab(owner,window);});
    connect(workspace,&WorkspaceController::moveActiveTabToWindowRequested,this,[this,owner=QPointer<WorkspaceController>(workspace),window=QPointer<QQuickWindow>(window)](WorkspaceController *target,ReaderController *reader,qulonglong generation){if(owner && window)moveToWindow(owner,window,target,reader,generation);});
    connect(window,&QQuickWindow::closing,engine,[engine,window]{
        QTimer::singleShot(0,engine,[engine,window]{if(!window->isVisible())engine->deleteLater();});
    });
    if(!url.isEmpty())workspace->openFile(url);
    QPointer<QQuickWindow> guard(window);
    QPointer<QQmlApplicationEngine> engineGuard(engine);
    emit windowCreated(window);
    if(!guard && engineGuard)engineGuard->deleteLater();
    return guard;
}

void ReaderWindowFactory::detachActiveTab(WorkspaceController *source,QQuickWindow *sourceWindow) {
    QPointer<WorkspaceController> origin(source);
    QPointer<QQuickWindow> oldWindow(sourceWindow);
    QPointer<ReaderController> originalReader(source->activeReader());
    const auto generation=originalReader ? originalReader->documentGeneration() : 0;
    const auto reason=source->tabTransferBlockReason();
    if(!origin)return;
    if(!reason.isEmpty()){emit origin->tabTransferFailed(reason);return;}
    // Load the destination before changing ownership; a failed QML load leaves the
    // original reader and its UI intact. It is first mapped only after the handoff.
    QPointer<QQuickWindow> window(createWindow({},-1,0,false));
    if(!origin || !oldWindow){if(window)qmlEngine(window)->deleteLater();return;}
    if(!window){emit origin->tabTransferFailed(tr("The new reader window could not be opened. The tab is still here."));return;}
    QPointer<WorkspaceController> target(window->property("session").value<WorkspaceController *>());
    QPointer<ReaderController> emptySource;
    const auto error=(!originalReader || origin->activeReader()!=originalReader || originalReader->documentGeneration()!=generation)
        ? tr("The active tab changed before the new window was ready. Nothing was moved.") : origin->transferActiveTabTo(target,&emptySource);
    if(!error.isEmpty()) {
        if(window)qmlEngine(window)->deleteLater();
        if(origin)emit origin->tabTransferFailed(error);
        return;
    }
    finishTransfer(origin,oldWindow,window,emptySource);
}
void ReaderWindowFactory::moveToWindow(WorkspaceController *source,QQuickWindow *sourceWindow,WorkspaceController *target,ReaderController *reader,qulonglong generation) {
    QPointer<WorkspaceController> origin(source);
    QPointer<QQuickWindow> oldWindow(sourceWindow);
    if(!WorkspaceController::allWorkspaces().contains(target) || target==source) {
        emit source->tabTransferFailed(tr("The selected reader window is no longer available. Nothing was moved."));return;
    }
    QPointer<QQuickWindow> window(qobject_cast<QQuickWindow *>(target->readerWindow()));
    if(!reader || origin->activeReader()!=reader || reader->documentGeneration()!=generation || !window || !window->isVisible()) {
        emit source->tabTransferFailed(tr("The selected tab or window changed. Nothing was moved."));return;
    }
    QPointer<ReaderController> emptySource;
    const auto error=origin->transferActiveTabTo(target,&emptySource);
    if(!error.isEmpty()){if(origin)emit origin->tabTransferFailed(error);return;}
    finishTransfer(origin,oldWindow,window,emptySource);
}
