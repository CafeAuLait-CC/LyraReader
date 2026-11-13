#include "ReaderWindowFactory.h"
#include "WorkspaceController.h"
#include "NativeRaster.h"
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTimer>

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
    connect(workspace,&WorkspaceController::newWindowRequested,this,[this](const QUrl &file,int targetPage,double targetY){createWindow(file,targetPage,targetY);});
    connect(workspace,&WorkspaceController::detachActiveTabRequested,this,[this,workspace,window]{detachActiveTab(workspace,window);});
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
    if(window)window->show();
    if(window)window->raise();
    if(window)window->requestActivate();
    if(window && window->isVisible() && emptySource && origin && oldWindow && origin->tabs().size()==1 && origin->activeReader()==emptySource && emptySource->fileUrl().isEmpty()) {
        QVariant reason;
        if(QMetaObject::invokeMethod(oldWindow,"tabTransferUiBlockReason",Q_RETURN_ARG(QVariant,reason)) && reason.toString().isEmpty() && oldWindow)oldWindow->close();
    }
}
