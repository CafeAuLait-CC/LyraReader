#include "DisplayCalibration.h"
#include "AuxiliaryWindowPolicy.h"
#include "PageItem.h"
#include "CropItem.h"
#include "ReaderController.h"
#include "WorkspaceController.h"
#include "AnnotationOverlay.h"
#include "NativeRaster.h"
#include <QCommandLineParser>
#include <QFileInfo>
#include <QApplication>
#include <QFontDatabase>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QStandardPaths>
#include <QTimer>
#include <functional>

static const char *graphicsName(QSGRendererInterface::GraphicsApi api) {
    switch (api) {
    case QSGRendererInterface::OpenGL: return "OpenGL";
    case QSGRendererInterface::Vulkan: return "Vulkan";
    case QSGRendererInterface::Direct3D11: return "Direct3D11";
    case QSGRendererInterface::Direct3D12: return "Direct3D12";
    case QSGRendererInterface::Metal: return "Metal";
    case QSGRendererInterface::Software: return "Software";
    default: return "Other";
    }
}

int main(int argc, char **argv) {
    QApplication application(argc, argv);
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/LyraReaderSansSC-Regular.ttf"));
    QCoreApplication::setApplicationName(QStringLiteral("LyraReader"));
    QCoreApplication::setOrganizationName(QStringLiteral("Alex"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("alex.com"));
    // Installed builds have a desktop entry the portal can resolve. An uninstalled
    // development binary should not register a nonexistent desktop identity.
    if (!QStandardPaths::locate(QStandardPaths::GenericDataLocation,
            QStringLiteral("applications/com.alex.lyrareader.desktop")).isEmpty())
        QGuiApplication::setDesktopFileName(QStringLiteral("com.alex.lyrareader"));
    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("LyraReader native Qt PDF reader"));
    parser.addHelpOption();
    parser.addPositionalArgument(QStringLiteral("file"), QStringLiteral("Local PDF to open"));
    parser.addOption({QStringLiteral("quit-after"), QStringLiteral("Exit after N milliseconds (development check)"), QStringLiteral("ms")});
    parser.addOption({QStringLiteral("snapshot"), QStringLiteral("Save a window snapshot before quitting (development check)"), QStringLiteral("path")});
    parser.addOption({QStringLiteral("graphics"), QStringLiteral("Graphics backend: auto, vulkan, opengl, software"), QStringLiteral("backend"), QStringLiteral("auto")});
    parser.process(application);
    const auto graphics = parser.value(QStringLiteral("graphics"));
    if (graphics == QStringLiteral("vulkan")) QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
    else if (graphics == QStringLiteral("opengl")) QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    else if (graphics == QStringLiteral("software")) QQuickWindow::setSceneGraphBackend(QStringLiteral("software"));
    else if (graphics != QStringLiteral("auto")) { qCritical() << "Unknown graphics backend:" << graphics; return 2; }
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
#ifdef Q_OS_WIN
        QQuickStyle::setStyle(QStringLiteral("FluentWinUI3"));
#else
        QQuickStyle::setStyle(QStringLiteral("Fusion"));
#endif
    }
    qmlRegisterUncreatableType<ReaderController>("LyraReader", 1, 0, "ReaderController", QStringLiteral("Created by the application"));
    qmlRegisterType<DisplayCalibration>("LyraReader",1,0,"DisplayCalibration");
    qmlRegisterType<AuxiliaryWindowPolicy>("LyraReader",1,0,"AuxiliaryWindowPolicy");
    qmlRegisterType<PageItem>("LyraReader", 1, 0, "PdfPage");
    qmlRegisterType<CropItem>("LyraReader",1,0,"PdfCrop");
    qmlRegisterType<AnnotationOverlay>("LyraReader",1,0,"PdfAnnotations");
    std::function<QQuickWindow *(const QUrl &,int,double)> createWindow;
    createWindow = [&](const QUrl &url,int page,double y) -> QQuickWindow * {
        auto *engine = new QQmlApplicationEngine(&application);
        engine->addImageProvider(QStringLiteral("lyrapreview"),new NativeImageProvider);
        auto *workspace = new WorkspaceController(engine);
        engine->rootContext()->setContextProperty(QStringLiteral("workspace"),workspace);
        engine->rootContext()->setContextProperty(QStringLiteral("reader"),workspace->activeReader());
        engine->load(QUrl(QStringLiteral("qrc:/qml/Main.qml")));
        if (engine->rootObjects().isEmpty()) { delete engine; return nullptr; }
        auto *created = qobject_cast<QQuickWindow *>(engine->rootObjects().first());
        if (!created) { delete engine; return nullptr; }
        created->setPersistentSceneGraph(false);
        created->setProperty("requestedPage",page);
        created->setProperty("requestedY",y);
        QObject::connect(workspace,&WorkspaceController::newWindowRequested,&application,[&](const QUrl &file,int targetPage,double targetY) {createWindow(file,targetPage,targetY);});
        QObject::connect(created,&QQuickWindow::closing,engine,[engine,created] {
            QTimer::singleShot(0,engine,[engine,created] { if(!created->isVisible())engine->deleteLater(); });
        });
        QObject::connect(created,&QQuickWindow::sceneGraphInitialized,created,[created] {
            qInfo()<<"lyra-reader-qt-backend:"<<QGuiApplication::platformName()
                   <<"graphicsApi="<<graphicsName(created->rendererInterface()->graphicsApi());
        },Qt::DirectConnection);
        if (!url.isEmpty()) workspace->openFile(url);
        return created;
    };
    auto *window=createWindow({},-1,0);
    if (!window) return 1;
    const auto files = parser.positionalArguments();
    if (!files.isEmpty()) {
        auto *workspace=window->property("session").value<WorkspaceController *>();
        if (workspace) for (const auto &file:files) workspace->openFile(QUrl::fromLocalFile(QFileInfo(file).absoluteFilePath()));
    }
    if (parser.isSet(QStringLiteral("quit-after"))) {
        bool ok = false;
        const int duration = parser.value(QStringLiteral("quit-after")).toInt(&ok);
        if (!ok || duration < 1) return 2;
        const auto snapshot = parser.value(QStringLiteral("snapshot"));
        QTimer::singleShot(duration, &application, [&application, window=QPointer<QQuickWindow>(window), snapshot] {
            if(!window){application.quit();return;}
            if (!snapshot.isEmpty()) {
                if (auto *sidebar = window->findChild<QObject *>(QStringLiteral("pagesSidebar")))
                    qInfo() << "lyra-reader-qt-sidebar:" << "height=" << sidebar->property("height")
                        << "contentHeight=" << sidebar->property("contentHeight")
                        << "contentY=" << sidebar->property("contentY")
                        << "originY=" << sidebar->property("originY")
                        << "current=" << sidebar->property("currentIndex");
            }
            if (!snapshot.isEmpty() && !window->grabWindow().save(snapshot)) {
                qCritical() << "Could not save window snapshot" << snapshot;
                application.exit(3);
                return;
            }
            application.quit();
        });
    }
    const int result=application.exec();
    // Destroy QML windows and their platform/theme connections while QApplication
    // services are still alive, rather than in QObject's later child cleanup.
    qDeleteAll(application.findChildren<QQmlApplicationEngine *>(QString{},Qt::FindDirectChildrenOnly));
    return result;
}
