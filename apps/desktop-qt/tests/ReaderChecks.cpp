#include "ReaderController.h"
#include "PageItem.h"
#include "CropItem.h"
#include "PaperAppearance.h"
#include "PdfPrintJob.h"
#include "NativeRaster.h"
#include "PreviewController.h"
#include "MockChatServer.h"
#include "PerformanceRecorder.h"
#include "NativeCorpusChecks.h"
#include <QJsonDocument>
#include <QSaveFile>
#include <QSysInfo>
#include <QUuid>
#include <QPrinter>
#include "AnnotationOverlay.h"
#include "WorkspaceController.h"
#include <QApplication>
#include <QAccessible>
#include <QFontDatabase>
#include <QDir>
#include <QSignalSpy>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QJSValue>
#include <QInputMethodEvent>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSettings>
#include <QTemporaryDir>
#include <QtTest>
#include <functional>
#include <thread>
#include <vector>
#include <atomic>

static QQuickItem *visualItem(QQuickItem *root,const QString &name) {
    if(root->objectName()==name)return root;
    for(auto *child:root->childItems())if(auto *found=visualItem(child,name))return found;
    return nullptr;
}

class ReaderChecks : public QObject {
    Q_OBJECT
public:
    QString root;
private slots:
    void initTestCase() {
        qInfo() << "Qt test platform:" << QGuiApplication::platformName();
        if (qEnvironmentVariableIsSet("LYRA_READER_REQUIRE_NATIVE_QT")) {
            QVERIFY(QGuiApplication::platformName() == "wayland" || QGuiApplication::platformName() == "xcb");
        }
        qmlRegisterUncreatableType<ReaderController>("LyraReader", 1, 0, "ReaderController", "Created by host");
        qmlRegisterType<PageItem>("LyraReader", 1, 0, "PdfPage");
        qmlRegisterType<CropItem>("LyraReader",1,0,"PdfCrop");
        qmlRegisterType<AnnotationOverlay>("LyraReader",1,0,"PdfAnnotations");
    }
    void recentHistoryIsSharedByAllReaderWindows() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto firstPath=scratch.path()+"/first.pdf",secondPath=scratch.path()+"/second.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",firstPath));QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",secondPath));
        QSettings settings;settings.setValue("reader/recentDocuments",QVariantList{QVariantMap{{"url","https://example.invalid/document.pdf"}},QVariantMap{{"url",QUrl::fromLocalFile(firstPath).toString()},{"title",""}},QVariantMap{{"url",QUrl::fromLocalFile(firstPath).toString()},{"title","duplicate"}}});
        WorkspaceController first,second;
        QCOMPARE(first.recentDocuments().size(),1);QCOMPARE(first.recentDocuments(),second.recentDocuments());
        QCOMPARE(first.recentDocuments().first().toMap().value("title").toString(),QString("first.pdf"));
        first.clearRecentDocuments();QVERIFY(second.recentDocuments().isEmpty());
        first.openFile(QUrl::fromLocalFile(firstPath));QTRY_COMPARE_WITH_TIMEOUT(first.activeReader()->pageCount(),1,10000);
        QTRY_COMPARE(second.recentDocuments().size(),1);QCOMPARE(first.recentDocuments(),second.recentDocuments());
        second.openFile(QUrl::fromLocalFile(secondPath));QTRY_COMPARE_WITH_TIMEOUT(second.activeReader()->pageCount(),3,10000);
        QTRY_COMPARE(first.recentDocuments().size(),2);QCOMPARE(first.recentDocuments(),second.recentDocuments());
        QCOMPARE(first.recentDocuments().first().toMap().value("title").toString(),QString("second.pdf"));
        first.clearRecentDocuments();QVERIFY(second.recentDocuments().isEmpty());
        second.activeReader()->openFile(QUrl::fromLocalFile(secondPath));QTRY_COMPARE_WITH_TIMEOUT(second.activeReader()->pendingCommands(),0,10000);QTRY_COMPARE(first.recentDocuments().size(),1);
        WorkspaceController third;QCOMPARE(third.recentDocuments(),first.recentDocuments());third.clearRecentDocuments();QVERIFY(first.recentDocuments().isEmpty());QVERIFY(second.recentDocuments().isEmpty());
    }
    void accessibleTabsExposeSelectionAndActivationAfterAsyncLoads() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto firstPath=scratch.path()+"/first.pdf",secondPath=scratch.path()+"/second.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",firstPath));QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",secondPath));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(firstPath));auto *first=workspace.activeReader();
        workspace.openFile(QUrl::fromLocalFile(secondPath));auto *second=workspace.activeReader();QVERIFY(first!=second);
        QTRY_COMPARE_WITH_TIMEOUT(first->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);
        const auto tab=[&](const QString &name) {
            std::function<QAccessibleInterface *(QQuickItem *)> find=[&](QQuickItem *item)->QAccessibleInterface * {
                auto *interface=QAccessible::queryAccessibleInterface(item);
                if(interface && interface->role()==QAccessible::PageTab && interface->text(QAccessible::Name)==name)return interface;
                for(auto *child:item->childItems())if(auto *found=find(child))return found;
                return nullptr;
            };
            return find(window->contentItem());
        };
        QTRY_VERIFY(tab("first.pdf") && tab("second.pdf"));
        QTRY_VERIFY(tab("second.pdf")->state().selected);QVERIFY(!tab("first.pdf")->state().selected);
        auto *action=tab("first.pdf")->actionInterface();QVERIFY(action);QVERIFY(action->actionNames().contains(QAccessibleActionInterface::pressAction()));
        action->doAction(QAccessibleActionInterface::pressAction());QTRY_COMPARE(workspace.activeReader(),first);
        QTRY_VERIFY(tab("first.pdf")->state().selected);QVERIFY(!tab("second.pdf")->state().selected);
    }
    void requestedWindowRegionOverridesSavedFirstPagePosition() {
        WorkspaceController saved;const auto url=QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf");
        saved.openFile(url);QTRY_COMPARE_WITH_TIMEOUT(saved.activeReader()->pageCount(),3,10000);
        saved.saveViewState(saved.activeReader(),{{"page",2},{"offset",1800},{"viewportAnchor",QVariantMap{{"page",2},{"y",99}}},{"zoom",1},{"fitting",false}});
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        window->setProperty("requestedPage",0);window->setProperty("requestedY",150.0);workspace.openFile(url);
        QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
        QTRY_COMPARE(window->property("requestedPage").toInt(),-1);
        auto *view=window->findChild<QQuickItem *>("pageList");QVERIFY(view);
        QTRY_VERIFY(visualItem(window->contentItem(),"pdfPage0"));
        QTRY_VERIFY(qAbs(visualItem(window->contentItem(),"pdfPage0")->mapToItem(view,QPointF(0,0)).y()+150.0*window->property("zoom").toDouble())<1);
        QSignalSpy requested(&workspace,&WorkspaceController::newWindowRequested);workspace.openInNewWindow(url,1,200);
        QCOMPARE(requested.size(),1);QCOMPARE(requested.first().at(1).toInt(),1);QCOMPARE(requested.first().at(2).toDouble(),200.0);
        window->setProperty("requestedPage",1);window->setProperty("requestedY",200.0);QVERIFY(QMetaObject::invokeMethod(window,"restorePosition"));
        QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
        QTRY_VERIFY(visualItem(window->contentItem(),"pdfPage1"));
        QTRY_VERIFY(qAbs(visualItem(window->contentItem(),"pdfPage1")->mapToItem(view,QPointF(0,0)).y()+200.0*window->property("zoom").toDouble())<1);
    }
    void latePageZoomPreservesTheVisiblePointAndReadingPosition_data() {
        QTest::addColumn<bool>("facing");QTest::addColumn<bool>("legacy");
        QTest::newRow("continuous")<<false<<false;
        QTest::newRow("facing-right-page")<<true<<false;
        QTest::newRow("legacy-continuous-offset")<<false<<true;
        QTest::newRow("legacy-facing-offset")<<true<<true;
    }
    void latePageZoomPreservesTheVisiblePointAndReadingPosition() {
        QFETCH(bool,facing);QFETCH(bool,legacy);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto file=scratch.path()+"/late-page.pdf";
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",file));
        const auto url=QUrl::fromLocalFile(file);QVariantMap saved;QPointF savedPoint;
        {
            WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
            engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
            auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(url);
            QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
            auto *view=window->findChild<QQuickItem *>("pageList");QVERIFY(view);
            // Opening schedules a saved-position/layout restore; begin interaction
            // only after its first textured page has actually reached the scene.
            QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
            if(facing) {
                QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,"Facing")));
                QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
            }
            window->setProperty("fitting",false);
            QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,150.0)));
            const auto page=[&]{return visualItem(window->contentItem(),"pdfPage6");};
            QTRY_VERIFY_WITH_TIMEOUT(page() && page()->property("texturesReady").toBool(),10000);
            const QPointF anchor(view->width()/2,180);
            const auto point=page()->mapFromItem(view,anchor)/window->property("zoom").toDouble();
            for(int step=0;step<12;++step) {
                const double scale=step%3==0?2.7:step%3==1?4.0:3.6;
                QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,scale),Q_ARG(QVariant,anchor.x()),Q_ARG(QVariant,anchor.y())));
                QTest::qWait(16);QVERIFY(page());
                const auto actual=page()->mapFromItem(view,anchor)/scale;
                QVERIFY2(QLineF(point,actual).length()<0.5,qPrintable(QString("Zoom anchor drift: %1 pt").arg(QLineF(point,actual).length())));
            }
            QTRY_VERIFY_WITH_TIMEOUT(page() && page()->property("texturesReady").toBool(),10000);QCOMPARE(window->property("currentPage").toInt(),facing?5:6);
            // Retain a specifically selected right-hand page as well as the row anchor.
            QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,-page()->mapToItem(view,QPointF(0,0)).y()/window->property("zoom").toDouble())));
            const double bookmarkY=qMax(0.0,-page()->mapToItem(view,QPointF(0,0)).y()/window->property("zoom").toDouble());
            QVERIFY(QMetaObject::invokeMethod(window,"addBookmark"));
            const auto bookmarks=[&]{return workspace.activeReader()->data().value("marks").toMap().value("bookmarks").toList();};
            QTRY_COMPARE_WITH_TIMEOUT(bookmarks().size(),1,10000);QCOMPARE(bookmarks().first().toMap().value("page").toInt(),6);
            QVERIFY(qAbs(bookmarks().first().toMap().value("yPt").toDouble()-bookmarkY)<0.5);
            const auto before=page()->mapToItem(view,QPointF(0,0));
            QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,2),Q_ARG(QVariant,80.0)));
            QTest::qWait(20);QVERIFY(QMetaObject::invokeMethod(window,"goBack"));
            QTRY_VERIFY(page() && qAbs(page()->mapToItem(view,QPointF(0,0)).y()-before.y())<1);
            QCOMPARE(window->property("currentPage").toInt(),6);
            QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));saved=workspace.viewState(workspace.activeReader());
            savedPoint=page()->mapFromItem(view,QPointF(view->width()/2,180))/window->property("zoom").toDouble();
            QCOMPARE(saved.value("page").toInt(),6);QCOMPARE(saved.value("viewportAnchor").toMap().value("page").toInt(),facing?5:6);
            if(legacy){auto previous=saved;previous.remove("viewportAnchor");previous.remove("documentX");workspace.saveViewState(workspace.activeReader(),previous);}
        }
        {
            WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
            engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
            auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(url);
            QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
            auto *view=window->findChild<QQuickItem *>("pageList");QVERIFY(view);
            const auto page=[&]{return visualItem(window->contentItem(),"pdfPage6");};
            QTRY_VERIFY_WITH_TIMEOUT(page() && page()->property("texturesReady").toBool(),10000);
            QTRY_COMPARE(window->property("currentPage").toInt(),6);QCOMPARE(window->property("zoom").toDouble(),saved.value("zoom").toDouble());
            const double expected=-saved.value("viewportAnchor").toMap().value("y").toDouble()*window->property("zoom").toDouble();
            QTRY_VERIFY(qAbs(page()->mapToItem(view,QPointF(0,0)).y()-expected)<1);
            if(!legacy)QVERIFY(QLineF(savedPoint,page()->mapFromItem(view,QPointF(view->width()/2,180))/window->property("zoom").toDouble()).length()<0.5);
        }
    }
    void pageOverviewSupportsAccessibleSelectionAndKeyboardReading() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto file=scratch.path()+"/overview.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",file));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(file));
        QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
        window->setProperty("overviewVisible",true);QTRY_VERIFY(visualItem(window->contentItem(),"overviewPage2"));
        auto *third=visualItem(window->contentItem(),"overviewPage2");auto *first=visualItem(window->contentItem(),"overviewPage0");QVERIFY(third && first);
        auto *interface=QAccessible::queryAccessibleInterface(third);QVERIFY(interface);QCOMPARE(interface->role(),QAccessible::ListItem);QCOMPARE(interface->text(QAccessible::Name),QString("Overview page 3"));QVERIFY(interface->state().selectable);
        auto *action=interface->actionInterface();QVERIFY(action);QVERIFY(action->actionNames().contains(QAccessibleActionInterface::pressAction()));action->doAction(QAccessibleActionInterface::pressAction());
        QTRY_COMPARE(window->property("selectedPages").toList(),QVariantList({2}));QVERIFY(interface->state().selected);
        auto *canvas=window->findChild<QQuickItem *>("pageList");QVERIFY(canvas);
        canvas->setProperty("contentY",workspace.activeReader()->pages().at(1).toMap().value("top").toDouble()*window->property("zoom").toDouble());QTest::qWait(50);
        QCOMPARE(window->property("currentPage").toInt(),2); // Hidden canvas reflow must not change the overview's keyboard target.
        third->forceActiveFocus();QTest::keyClick(window,Qt::Key_Space,Qt::ControlModifier);QCOMPARE(window->property("selectedPages").toList(),QVariantList{});
        first->forceActiveFocus();QTest::keyClick(window,Qt::Key_Space,Qt::ShiftModifier);QCOMPARE(window->property("selectedPages").toList(),QVariantList({0,1,2}));
        QTest::keyClick(window,Qt::Key_Space);QCOMPARE(window->property("selectedPages").toList(),QVariantList({0}));
        QTest::keyClick(window,Qt::Key_Right);QTRY_VERIFY(visualItem(window->contentItem(),"overviewPage1")->hasActiveFocus());
        QTest::keyClick(window,Qt::Key_Return);QTRY_VERIFY(!window->property("overviewVisible").toBool());QTRY_COMPARE(window->property("currentPage").toInt(),1);
    }
    void recentDocumentsAndNarrowWindowRemainKeyboardReachable() {
        WorkspaceController workspace;workspace.clearRecentDocuments();
        workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));
        QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),3,10000);
        QTRY_COMPARE(workspace.recentDocuments().size(),1);
        auto *original=workspace.activeReader();workspace.newTab();
        QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());
        engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);if(QGuiApplication::platformName()!="offscreen")window->setMaximumSize(QSize(640,440));window->resize(640,440);
        QTRY_VERIFY_WITH_TIMEOUT(window->width()<=640 && window->height()<=440,5000);
        auto *recent=window->findChild<QQuickItem *>("recentDocuments");QVERIFY(recent);
        QTRY_COMPARE(recent->property("count").toInt(),1);
        QTRY_VERIFY(visualItem(window->contentItem(),"recentDocument0"));
        auto *row=visualItem(window->contentItem(),"recentDocument0");QVERIFY(row);QTest::qWait(150);
        QVERIFY(row->isVisible());
        auto *recentInterface=QAccessible::queryAccessibleInterface(row);QVERIFY(recentInterface);QVERIFY(recentInterface->actionInterface());QVERIFY(recentInterface->actionInterface()->actionNames().contains(QAccessibleActionInterface::pressAction()));
        QTRY_VERIFY(row->mapToScene(QPointF(0,row->height())).y()<=window->height());
        row->forceActiveFocus();QTest::keyClick(window,Qt::Key_Space);
        QTRY_COMPARE(workspace.activeReader(),original);QCOMPARE(workspace.tabs().size(),2);
        QTRY_COMPARE_WITH_TIMEOUT(original->pendingCommands(),0,10000);
        auto *more=window->findChild<QQuickItem *>("moreCommands");auto *search=window->findChild<QQuickItem *>("searchField");
        auto *sidebar=window->findChild<QQuickItem *>("readerSidebar");auto *area=window->findChild<QQuickItem *>("readingArea");
        QVERIFY(more && search && sidebar && area);QTest::qWait(150);
        const auto moreBounds=more->mapRectToScene(QRectF(0,0,more->width(),more->height()));
        const auto searchBounds=search->mapRectToScene(QRectF(0,0,search->width(),search->height()));
        QVERIFY(moreBounds.right()<=searchBounds.left());QVERIFY(searchBounds.right()<=window->width());
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,moreBounds.center().toPoint());
        auto *menu=window->findChild<QObject *>("moreCommandsMenu");QVERIFY(menu);QTRY_VERIFY(menu->property("visible").toBool());
        QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY(!menu->property("visible").toBool());
        window->setProperty("sidebarVisible",true);window->setProperty("searchVisible",true);
        QTRY_VERIFY(!sidebar->isVisible());QTRY_VERIFY(area->width()>350);
        window->setProperty("searchVisible",false);QTRY_VERIFY(sidebar->isVisible());
        workspace.selectTab(1);QTRY_VERIFY(recent->isVisible());
        auto *clear=window->findChild<QQuickItem *>("clearRecentDocuments");QVERIFY(clear);clear->forceActiveFocus();QTest::keyClick(window,Qt::Key_Space);
        QTRY_VERIFY(workspace.recentDocuments().isEmpty());QTRY_COMPARE(recent->property("count").toInt(),0);
        const auto snapshots=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");
        if(!snapshots.isEmpty())QVERIFY(window->grabWindow().save(snapshots+"/lyrareader-welcome-narrow.png"));
    }
    void wholeWindowSurvivesTextureReplacementAndPageJump() {
        ReaderController reader;
        QQmlApplicationEngine engine;
        engine.addImageProvider(QStringLiteral("lyrapreview"),new NativeImageProvider);
        engine.rootContext()->setContextProperty("reader", &reader);
        engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(QCoreApplication::applicationDirPath() + "/fixtures/qt-nine-pages.pdf"));
        QTRY_VERIFY_WITH_TIMEOUT(reader.completedRasters() > 0, 10000);
        if (qEnvironmentVariable("QSG_RHI_BACKEND") == "vulkan")
            QCOMPARE(window->rendererInterface()->graphicsApi(), QSGRendererInterface::Vulkan);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTest::qWait(100); // Finish the initial asynchronous layout before testing anchored zoom.
        const auto before = reader.completedRasters();
        QVERIFY(QMetaObject::invokeMethod(window, "zoomBy", Q_ARG(QVariant, 1.2)));
        QTRY_VERIFY_WITH_TIMEOUT(reader.completedRasters() > before, 10000);
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("refined").toBool(),10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingRasters(),0,10000);
        QTest::qWait(150); // Give the scene graph time to replace its first texture.
        const auto frame = window->grabWindow();
        QVERIFY(!frame.isNull());
        // Check the rendered sidebar, not only its logical scroll position. A
        // backend-specific clip/translation error can hide its first two rows.
        auto *sidebar = window->findChild<QQuickItem *>("pagesSidebar");
        QVERIFY(sidebar);
        auto *current = sidebar->property("currentItem").value<QQuickItem *>();
        QVERIFY(current);
        const auto point = current->mapToScene(QPointF(current->width() - 10, current->height() / 2));
        const double sx = double(frame.width()) / window->width();
        const double sy = double(frame.height()) / window->height();
        const auto selected = frame.pixelColor(qRound(point.x() * sx), qRound(point.y() * sy));
        const auto following = frame.pixelColor(qRound(point.x() * sx), qRound((point.y() + current->height()) * sy));
        QVERIFY2(selected != following, "The selected first page row must be visible in the captured frame");
        // Changing application appearance must repaint the chrome without
        // recoloring or rerasterizing the source PDF.
        auto *theme = window->findChild<QObject *>("lyraReaderTheme");
        QVERIFY(theme);
        QVERIFY(!theme->property("dark").toBool());
        const auto rastersBeforeAppearance = reader.completedRasters();
        QVERIFY(window->setProperty("appearance", "dark"));
        QTRY_VERIFY(theme->property("dark").toBool());
        QTest::qWait(150);
        const auto darkFrame = window->grabWindow();
        QVERIFY(!darkFrame.isNull());
        QVERIFY(frame.pixelColor(2, frame.height() / 2) != darkFrame.pixelColor(2, darkFrame.height() / 2));
        QCOMPARE(reader.completedRasters(), rastersBeforeAppearance);
        std::function<QQuickItem *(QQuickItem *)> findPage=[&](QQuickItem *item)->QQuickItem * {
            if(item->objectName()==QStringLiteral("pdfPage0"))return item;
            for(auto *child:item->childItems())if(auto *found=findPage(child))return found;
            return nullptr;
        };
        auto *page=findPage(window->contentItem());
        QVERIFY(page);
        auto *viewport=window->findChild<QQuickItem *>("pageList");
        QVERIFY(viewport);
        const auto sampleFrame=window->grabWindow();
        const auto visible=page->mapRectToScene(QRectF(0,0,page->width(),page->height()))
            .intersected(viewport->mapRectToScene(QRectF(0,0,viewport->width(),viewport->height())));
        const double sampleScaleX=double(sampleFrame.width())/window->width(),sampleScaleY=double(sampleFrame.height())/window->height();
        const QRect area=QRectF(visible.x()*sampleScaleX,visible.y()*sampleScaleY,visible.width()*sampleScaleX,visible.height()*sampleScaleY).toAlignedRect().intersected(sampleFrame.rect()).adjusted(4,4,-4,-4);
        int px=-1,py=-1;
        for(int y=area.top();y<area.bottom() && px<0;y+=8)for(int x=area.left();x<area.right();x+=8) {
            const auto c=sampleFrame.pixelColor(x,y);
            if(c.red()>252 && c.green()>252 && c.blue()>252){px=x;py=y;break;}
        }
        QVERIFY2(px>=0,"The visible PDF crop must contain paper for the display conversion check");
        const auto source=sampleFrame.pixelColor(px,py);
        for(const auto &mode: {QString("warm"),QString("night")}) {
            QVERIFY(window->setProperty("paperAppearance",mode));
            QTest::qWait(100);
            const auto paperFrame=window->grabWindow();
            const auto expected=PaperAppearance::displayColor(source,PaperAppearance::mode(mode));
            const auto actual=paperFrame.pixelColor(px,py);
            QVERIFY2(qAbs(actual.red()-expected.red())<=2 && qAbs(actual.green()-expected.green())<=2 && qAbs(actual.blue()-expected.blue())<=2,qPrintable(mode+": "+actual.name()+" expected "+expected.name()));
            QCOMPARE(reader.completedRasters(),rastersBeforeAppearance);
        }
        window->setProperty("paperAppearance","original");
        const auto snapshots = qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");
        if (!snapshots.isEmpty()) {
            QVERIFY(frame.save(snapshots + "/lyrareader-light.png"));
            QVERIFY(darkFrame.save(snapshots + "/lyrareader-dark.png"));
        }
        window->setProperty("appearance", "light");
        QVERIFY(QMetaObject::invokeMethod(window, "navigate", Q_ARG(QVariant, reader.pageCount() - 1), Q_ARG(QVariant, 0)));
        QTRY_COMPARE(window->property("currentPage").toInt(), reader.pageCount() - 1);
        QTest::qWait(200);
        window->resize(720, 600);
        QVERIFY(!window->grabWindow().isNull());
    }
    void realPdfRendersWithOwnedPixels() {
        ReaderController reader;
        QSignalSpy opened(&reader, &ReaderController::openFinished);
        reader.openFile(QUrl::fromLocalFile(root + "/tests/fixtures/text-page.pdf"));
        QVERIFY(opened.wait(10000));
        QVERIFY2(reader.error().isEmpty(), qPrintable(reader.error()));
        QVERIFY(reader.pageCount() > 0);
        QSignalSpy raster(&reader, &ReaderController::pageReady);
        reader.requestPage(0, 1.0);
        QVERIFY(raster.wait(10000));
        auto image = reader.cachedPage(0, 1.0);
        QVERIFY(!image.isNull());
        QVERIFY(image.width() > 100);
        // A real fixture has non-white ink, not merely a successfully allocated white page.
        bool ink = false;
        for (int y = 0; y < image.height() && !ink; y += 2)
            for (int x = 0; x < image.width(); x += 2)
                if (qGray(image.pixel(x, y)) < 200) { ink = true; break; }
        QVERIFY(ink);
        const auto before = reader.completedRasters();
        reader.requestPage(0, 1.0);
        QTest::qWait(150);
        QCOMPARE(reader.completedRasters(), before);
        // Switching documents drops the cache without invalidating a retained image.
        reader.openFile(QUrl::fromLocalFile(root + "/tests/fixtures/rotated.pdf"));
        QVERIFY(opened.wait(10000));
        QVERIFY(!image.isNull());
    }
    void latestOpenWinsAndWindowsAreIndependent() {
        ReaderController first, second;
        QSignalSpy opened(&first, &ReaderController::openFinished);
        QSignalSpy otherOpened(&second, &ReaderController::openFinished);
        first.openFile(QUrl::fromLocalFile(root + "/tests/fixtures/multipage.pdf"));
        first.openFile(QUrl::fromLocalFile(root + "/tests/fixtures/text-page.pdf"));
        second.openFile(QUrl::fromLocalFile(root + "/tests/fixtures/multipage.pdf"));
        QTRY_COMPARE_WITH_TIMEOUT(opened.count(), 1, 10000);
        QTRY_COMPARE_WITH_TIMEOUT(otherOpened.count(), 1, 10000);
        QCOMPARE(first.pageCount(), 1);
        QVERIFY(second.pageCount() > first.pageCount());
        QCOMPARE(first.title(), QString("text-page.pdf"));
        QCOMPARE(second.title(), QString("multipage.pdf"));
    }
    void badPathIsAnErrorAndClosingDuringWorkIsSafe() {
        ReaderController reader;
        QSignalSpy opened(&reader, &ReaderController::openFinished);
        reader.openFile(QUrl::fromLocalFile(root + "/tests/fixtures/not-present.pdf"));
        QVERIFY(opened.wait(10000));
        QVERIFY(!reader.error().isEmpty());
        QCOMPARE(reader.pageCount(), 0);
        auto *closing = new ReaderController;
        closing->openFile(QUrl::fromLocalFile(root + "/tests/fixtures/multipage.pdf"));
        delete closing;
        QTest::qWait(100);
    }
    void multiplyHighlightPreservesBlackTextOnEveryBackend(){
        QQmlApplicationEngine engine;
        engine.addImageProvider(QStringLiteral("lyrapreview"),new NativeImageProvider);
        engine.load(QUrl("qrc:/tests/MultiplyCheck.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        QVERIFY(window);
        QTest::qWait(150);
        const auto image=window->grabWindow();
        QVERIFY(!image.isNull());
        const double sx=double(image.width())/window->width(),sy=double(image.height())/window->height();
        const auto paper=image.pixelColor(qRound(30*sx),qRound(40*sy));
        const auto ink=image.pixelColor(qRound(90*sx),qRound(40*sy));
        QVERIFY2(paper.red()>245 && paper.green()>245 && paper.blue()>115 && paper.blue()<140,qPrintable(paper.name()));
        QVERIFY2(ink.red()<3 && ink.green()<3 && ink.blue()<3,qPrintable(ink.name()));
        // Updating an unrelated item must not multiply the unchanged highlight
        // onto an already tinted backing store outside the software dirty clip.
        for(int i=0;i<12;++i){window->setProperty("pulse",double(i%2));QTest::qWait(16);const auto frame=window->grabWindow();QCOMPARE(frame.pixelColor(qRound(30*sx),qRound(40*sy)),paper);QCOMPARE(frame.pixelColor(qRound(90*sx),qRound(40*sy)),ink);}
    }
    void printingUsesImmutableEditedPagesAndKeepsTheSourceUntouched() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/original.pdf",output=scratch.path()+"/printed.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        QFile originalFile(path);QVERIFY(originalFile.open(QIODevice::ReadOnly));const auto original=originalFile.readAll();originalFile.close();
        ReaderController reader;
        reader.openFile(QUrl::fromLocalFile(path));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),3,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        reader.submit("mark_create",{{"entry",QVariantMap{{"kind","highlight"},{"page",0},{"start",0},{"end",3},{"color","#FFFF0080"},{"note","Print test"}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        auto printer=std::make_shared<QPrinter>(QPrinter::HighResolution);
        printer->setOutputFormat(QPrinter::PdfFormat);
        printer->setOutputFileName(output);
        printer->setFromTo(1,2);
        printer->setPrintRange(QPrinter::PageRange);
        bool done=false;QString printError;
        PdfPrintJob::start(reader.documentHandle(),reader.pages(),printer,0,[&](QString error){printError=error;done=true;},false);
        reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));
        QTRY_VERIFY_WITH_TIMEOUT(done,20000);
        QVERIFY2(printError.isEmpty(),qPrintable(printError));
        QVERIFY(originalFile.open(QIODevice::ReadOnly));QCOMPARE(originalFile.readAll(),original);
        ReaderController printed;
        printed.openFile(QUrl::fromLocalFile(output));
        QTRY_COMPARE_WITH_TIMEOUT(printed.pageCount(),2,10000);
        QTRY_COMPARE_WITH_TIMEOUT(printed.pendingCommands(),0,10000);
        printed.requestPage(0,1);
        QTRY_VERIFY_WITH_TIMEOUT(!printed.cachedPage(0,1).isNull(),10000);
        const auto raster=printed.cachedPage(0,1);
        bool ink=false,yellow=false;
        for(int y=0;y<raster.height();++y)for(int x=0;x<raster.width();++x){const auto c=raster.pixelColor(x,y);if(c.red()<80&&c.green()<80&&c.blue()<80)ink=true;if(c.red()>180&&c.green()>180&&c.blue()<180)yellow=true;}
        QVERIFY(ink);QVERIFY(yellow);
    }
    void annotationGeometryUsesRealGesturesAndOneUndoPerGesture() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/geometry.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        ReaderController reader;QQmlApplicationEngine engine;
        engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTest::qWait(150);
        window->setProperty("fitting",false);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTest::qWait(100);
        auto *page=visualItem(window->contentItem(),"pdfPage0");QVERIFY(page);
        QTRY_VERIFY(reader.textPages().contains("0"));
        const auto chars=reader.textPages().value("0").toMap().value("chars").toList();QVERIFY(chars.size()>6);
        const auto character=[&](int i){const auto c=chars[i].toMap();return page->mapToScene(QPointF(c.value("x_pt").toDouble()+c.value("width_pt").toDouble()/2,c.value("y_pt").toDouble()+c.value("height_pt").toDouble()/2)).toPoint();};
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,character(0));
        QTest::mouseMove(window,character(5),30);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,character(5));
        const auto selection=window->property("selection").value<QJSValue>().toVariant().toMap();
        QVERIFY(selection.value("end").toInt()-selection.value("start").toInt()>=4);
        QTest::keyClick(window,Qt::Key_Escape);
        reader.submit("mark_create",{{"entry",QVariantMap{{"kind","square"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",100},{"y",100},{"width",100},{"height",70}}},{"color","#E8BC55FF"},{"note",""},{"strokeWidth",2}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        const auto entry=[&]{return reader.data().value("marks").toMap().value("annotations").toList().first().toMap();};
        const auto rect=[&]{return entry().value("rect").toMap();};
        const auto point=[&](double x,double y){return page->mapToScene(QPointF(x,y)).toPoint();};
        // Drag the top stroke: a single press/move/release writes exactly one undo step.
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(150,100));
        QTest::mouseMove(window,point(180,120),30);QTest::mouseMove(window,point(190,130),30);
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(190,130));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_VERIFY(qAbs(rect().value("x").toDouble()-140)<1);
        QVERIFY(qAbs(rect().value("y").toDouble()-130)<1);
        auto *editor=window->findChild<QObject *>("annotationEditor");QVERIFY(editor);QVERIFY(!editor->property("visible").toBool());
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QCOMPARE(rect().value("x").toDouble(),100.0);QCOMPARE(rect().value("y").toDouble(),100.0);
        reader.submit("marks_redo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_VERIFY(visualItem(window->contentItem(),"annotationHandle3"));
        auto *grip=visualItem(window->contentItem(),"annotationHandle3");
        const auto start=grip->mapToScene(QPointF(5,5)).toPoint();
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,start);
        QTest::mouseMove(window,start+QPoint(35,20),30);
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,start+QPoint(35,20));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_VERIFY(qAbs(rect().value("width").toDouble()-135)<1);
        QVERIFY(qAbs(rect().value("height").toDouble()-90)<1);
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QCOMPARE(rect().value("width").toDouble(),100.0);QCOMPARE(rect().value("x").toDouble(),140.0);
        // Escape cancels an in-progress move without adding another history step.
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(180,130));
        QTest::mouseMove(window,point(210,150),30);QTest::keyClick(window,Qt::Key_Escape);
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(210,150));
        QTest::qWait(100);QVERIFY(window->property("annotationDraft").isNull());
        QCOMPARE(rect().value("x").toDouble(),140.0);
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QCOMPARE(rect().value("x").toDouble(),100.0);
        // Keyboard repeats stay in a draft until release, with one history step.
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point(150,100));
        QTest::keyPress(window,Qt::Key_Right);QTest::keyPress(window,Qt::Key_Right);QTest::keyPress(window,Qt::Key_Right);
        QCOMPARE(rect().value("x").toDouble(),100.0);
        QTest::keyRelease(window,Qt::Key_Right);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_COMPARE(rect().value("x").toDouble(),103.0);
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(rect().value("x").toDouble(),100.0);
        QTest::keyClick(window,Qt::Key_Right,Qt::ControlModifier|Qt::ShiftModifier);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_COMPARE(rect().value("width").toDouble(),110.0);
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(rect().value("width").toDouble(),100.0);
        QTest::keyPress(window,Qt::Key_Down);QTest::keyClick(window,Qt::Key_Escape);QTest::keyRelease(window,Qt::Key_Down);
        QTest::qWait(50);QCOMPARE(rect().value("y").toDouble(),100.0);QVERIFY(window->property("annotationDraft").isNull());
        // Properties and geometry share the sidecar, and a fresh reader sees both.
        // Escape cleared selection; select the annotation through the page before editing.
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point(150,100));
        QVERIFY(QMetaObject::invokeMethod(window,"updateSelectedAnnotation",Q_ARG(QVariant,(QVariantMap{{"color","#7DADD680"},{"strokeWidth",5}}))));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));
        QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);
        const auto persisted=reopened.data().value("marks").toMap().value("annotations").toList().first().toMap();
        QCOMPARE(persisted.value("color").toString(),QString("#7DADD680"));QCOMPARE(persisted.value("strokeWidth").toInt(),5);
        QCOMPARE(persisted.value("rect").toMap().value("x").toDouble(),100.0);
        reader.submit("mark_create",{{"entry",QVariantMap{{"kind","arrow"},{"page",0},{"version",1},{"lineStart",QVariantMap{{"x",80},{"y",220}}},{"lineEnd",QVariantMap{{"x",200},{"y",280}}},{"color","#E8BC55FF"},{"note",""},{"strokeWidth",2}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTest::qWait(50);
        grip=visualItem(window->contentItem(),"annotationHandle1");QVERIFY(grip);
        const auto arrowEnd=grip->mapToScene(QPointF(5,5)).toPoint();
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,arrowEnd);
        QTest::mouseMove(window,arrowEnd+QPoint(-25,30),30);
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,arrowEnd+QPoint(-25,30));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        const auto arrow=reader.data().value("marks").toMap().value("annotations").toList().last().toMap();
        QVERIFY(qAbs(arrow.value("lineEnd").toMap().value("x").toDouble()-175)<1);
        QVERIFY(qAbs(arrow.value("lineEnd").toMap().value("y").toDouble()-310)<1);
        QCOMPARE(arrow.value("lineStart").toMap().value("x").toDouble(),80.0);
        reader.submit("mark_create",{{"entry",QVariantMap{{"kind","textBox"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",100},{"y",350},{"width",180},{"height",60}}},{"color","#7DADD6FF"},{"note",""},{"fontSize",14}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_VERIFY(editor->property("visible").toBool());
        auto *note=window->findChild<QObject *>("annotationNoteText");QVERIFY(note);note->setProperty("text",QString::fromUtf8("English 中文 🙂"));
        auto *warning=window->findChild<QQuickItem *>("annotationGlyphWarning");QVERIFY(warning);
        QTRY_VERIFY_WITH_TIMEOUT(warning->isVisible(),10000);
        QVERIFY(warning->property("text").toString().contains(QString::fromUtf8("🙂")));
        auto *font=window->findChild<QQuickItem *>("annotationFontSize");QVERIFY(font);font->forceActiveFocus();
        QTest::keyClick(window,Qt::Key_Up);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_COMPARE(reader.data().value("marks").toMap().value("annotations").toList().last().toMap().value("fontSize").toInt(),15);
        QMetaObject::invokeMethod(editor,"close");
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QCOMPARE(reader.data().value("marks").toMap().value("annotations").toList().last().toMap().value("note").toString(),QString::fromUtf8("English 中文 🙂"));
    }
    void fileReplyThreadsShowHiddenCrossPageAndMalformedChains() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/replies.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/annotated-replies.pdf",path));
        ReaderController reader;QQmlApplicationEngine engine;
        engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),2,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTest::qWait(100);
        const auto model=[&]{return window->property("annotationThreads").value<QJSValue>().toVariant().toMap();};
        QTRY_COMPARE(model().value("replyCount").toInt(),8);
        QCOMPARE(model().value("nestedReplyCount").toInt(),4);QCOMPARE(model().value("orphanedReplyCount").toInt(),4);
        const auto row=[&](const QString &id) {for(const auto &value:model().value("rows").toList())if(value.toMap().value("annotation").toMap().value("id").toString()==id)return value.toMap();return QVariantMap{};};
        QCOMPARE(model().value("rows").toList().size(),10);
        QCOMPARE(row("nm:reply-two").value("depth").toInt(),2);
        QCOMPARE(row("nm:reply-cross-page").value("sectionPage").toInt(),0);
        QCOMPARE(row("nm:reply-cross-page").value("annotation").toMap().value("page").toInt(),1);
        QVERIFY(row("nm:parent-highlight").value("annotation").toMap().value("visible").toBool());
        QVERIFY(!row("nm:reply-empty").isEmpty());
        auto *page=visualItem(window->contentItem(),"pdfPage0");QVERIFY(page);
        const auto highlight=row("nm:parent-highlight").value("annotation").toMap();
        const auto quad=highlight.value("quads").toList().first().toMap();
        QTRY_VERIFY_WITH_TIMEOUT(page->property("refined").toBool(),10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingRasters(),0,10000);
        QTest::qWait(100);const auto frame=window->grabWindow();const double zoom=window->property("zoom").toDouble();
        bool painted=false;
        for(double x=quad.value("x").toDouble()+2;x<quad.value("x").toDouble()+quad.value("width").toDouble()-2;x+=4) {
            const auto at=page->mapToScene(QPointF(x*zoom,(quad.value("y").toDouble()+2)*zoom));
            const int px=qRound(at.x()*frame.width()/window->width()),py=qRound(at.y()*frame.height()/window->height());
            if(!frame.rect().contains(px,py))continue;
            const auto c=frame.pixelColor(px,py);if(c.blue()>240 && c.red()<230 && c.green()>150)painted=true;
        }
        if(!painted){frame.save(root+"/build/foreign-markup-failure.png");qInfo()<<"Markup sample"<<quad<<highlight.value("color")<<highlight.value("blend")<<zoom<<page->mapToScene(QPointF(quad.value("x").toDouble()*zoom,quad.value("y").toDouble()*zoom));}
        QVERIFY2(painted,"File markup must be drawn on the page, including drawing=markup records");
        QVERIFY(row("nm:cycle-a").value("orphanReason").toString().contains("cycle"));
        QVERIFY(row("nm:reply-to-hidden").value("orphanReason").toString().contains("hidden"));
        QVERIFY(row("nm:reply-to-link").value("orphanReason").toString().contains("missing"));
        QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"annotations")));
        QTest::qWait(100);
        auto *list=window->findChild<QObject *>("annotationThreadList");QVERIFY(list);QCOMPARE(list->property("count").toInt(),10);
        const auto reply=row("nm:reply-two").value("annotation");
        QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,reply),Q_ARG(QVariant,true)));
        auto *note=window->findChild<QObject *>("annotationNoteText");QVERIFY(note);QVERIFY(note->property("readOnly").toBool());
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(reader.data().value("marks").toMap().value("annotations").toList().isEmpty());
        auto *editor=window->findChild<QObject *>("annotationEditor");QVERIFY(editor);QMetaObject::invokeMethod(editor,"close");
        reader.submit("file_adopt",{{"id","nm:parent-highlight"}});
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QCOMPARE(model().value("nestedReplyCount").toInt(),4);QCOMPARE(model().value("rows").toList().size(),10);
        const auto adopted=reader.data().value("marks").toMap().value("annotations").toList().first().toMap();
        reader.submit("mark_delete",{{"id",adopted.value("id")}});
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QCOMPARE(model().value("replyCount").toInt(),4);QVERIFY(row("nm:reply-two").isEmpty());
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QCOMPARE(model().value("nestedReplyCount").toInt(),4);
        const auto snapshots=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!snapshots.isEmpty())QVERIFY(window->grabWindow().save(snapshots+"/lyrareader-reply-threads.png"));
    }
    void redactionReviewDeletesRealContentAndKeepsNewerDrafts() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/source.pdf", output=scratch.path()+"/redacted.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto bytes=original.readAll();original.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());
        engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::qWait(150);
        window->setProperty("fitting",false);QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0));QTest::qWait(100);
        QTRY_VERIFY(reader->textPages().contains("0"));const auto before=reader->textPages().value("0").toMap();const auto chars=before.value("chars").toList();QVERIFY(chars.size()>8);
        QRectF area;
        for(int i=0;i<6;++i){const auto c=chars[i].toMap();const QRectF box(c.value("x_pt").toDouble(),c.value("y_pt").toDouble(),c.value("width_pt").toDouble(),c.value("height_pt").toDouble());if(!box.isEmpty())area=area.isEmpty()?box:area.united(box);}
        area=area.adjusted(-2,-2,2,2);
        auto *page=visualItem(window->contentItem(),"pdfPage0");QVERIFY(page);
        window->setProperty("annotationTool","redact");
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,page->mapToScene(area.topLeft()).toPoint());
        QTest::mouseMove(window,page->mapToScene(area.bottomRight()).toPoint(),30);
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,page->mapToScene(area.bottomRight()).toPoint());
        QTRY_COMPARE(reader->editDrafts().value("redactions").toList().size(),1);
        const auto areas=reader->editDrafts().value("redactions").toList();
        QVERIFY(QMetaObject::invokeMethod(window,"reviewRedactions",Q_ARG(QVariant,false)));
        auto *review=window->findChild<QObject *>("redactionReview");QVERIFY(review);
        QTRY_VERIFY(!review->property("loading").toBool());QVERIFY(review->property("error").toString().isEmpty());
        const auto preview=review->property("preview").toMap();QVERIFY(preview.value("removed_characters").toInt()>0);
        QMetaObject::invokeMethod(review,"close");
        // A failed save retains all marks. A save dialog's old snapshot must not clear newer marks.
        const QVariant context=QVariantMap{{"reader",QVariant::fromValue(reader)},{"kind","redactions"},{"redactions",areas}};
        window->setProperty("exportContext",context);
        QVERIFY(QMetaObject::invokeMethod(window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(scratch.path()+"/missing/out.pdf"))));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->error().isEmpty());QCOMPARE(reader->editDrafts().value("redactions").toList(),areas);reader->dismissError();
        auto newer=areas;newer.append(QVariantMap{{"page",0},{"x_pt",10},{"y_pt",10},{"width_pt",5},{"height_pt",5}});reader->setEditDraft("redactions",newer);
        QVERIFY(QMetaObject::invokeMethod(window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(output))));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QCOMPARE(reader->editDrafts().value("redactions").toList(),newer);QVERIFY(reader->data().value("save_redactions").toMap().value("verified").toBool());
        QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),bytes);original.close();
        ReaderController redacted;redacted.openFile(QUrl::fromLocalFile(output));QTRY_COMPARE_WITH_TIMEOUT(redacted.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(redacted.pendingCommands(),0,10000);
        redacted.requestText(0);QTRY_VERIFY(redacted.textPages().contains("0"));
        QVERIFY(redacted.textPages().value("0").toMap().value("text").toString().size()<before.value("text").toString().size());
        redacted.requestPage(0,1);QTRY_VERIFY_WITH_TIMEOUT(!redacted.cachedPage(0,1).isNull(),10000);const auto image=redacted.cachedPage(0,1);
        const auto saved=areas.first().toMap();const QRect sample=QRectF(saved.value("x_pt").toDouble()+1,saved.value("y_pt").toDouble()+1,saved.value("width_pt").toDouble()-2,saved.value("height_pt").toDouble()-2).toAlignedRect();
        for(int y=sample.top();y<sample.bottom();y+=3)for(int x=sample.left();x<sample.right();x+=3){const auto c=image.pixelColor(x,y);QVERIFY(c.red()<4 && c.green()<4 && c.blue()<4);}
        // Every removed character is absent from the saved page's text geometry.
        for(const auto &value:redacted.textPages().value("0").toMap().value("chars").toList()) {const auto c=value.toMap();if(c.value("unicode").toUInt()<=32)continue;const QRectF box(c.value("x_pt").toDouble(),c.value("y_pt").toDouble(),c.value("width_pt").toDouble(),c.value("height_pt").toDouble());QVERIFY(!box.intersects(area.adjusted(1,1,-1,-1)));}
        workspace.newTab();auto *other=workspace.activeReader();other->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));QTRY_VERIFY(other->pageCount()>0);QTRY_COMPARE_WITH_TIMEOUT(other->pendingCommands(),0,10000);QVERIFY(other->editDrafts().isEmpty());
        workspace.selectTab(0);QCOMPARE(reader->editDrafts().value("redactions").toList(),newer);
        reader->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",1}}}}}});QTest::qWait(50);QVERIFY(reader->error().contains("pending form"));reader->dismissError();
        workspace.closeTab(0);QCOMPARE(workspace.tabs().size(),2);auto *close=window->findChild<QObject *>("closeChangesConfirmation");QVERIFY(close);QTRY_VERIFY(close->property("visible").toBool());QMetaObject::invokeMethod(close,"close");
        workspace.requestQuit();QTRY_VERIFY(close->property("visible").toBool());QVERIFY(window->isVisible());QMetaObject::invokeMethod(close,"close");
        // Matching successful snapshots clear their marks, while the source remains unchanged.
        const QVariant currentContext=QVariantMap{{"reader",QVariant::fromValue(reader)},{"kind","redactions"},{"redactions",newer}};window->setProperty("exportContext",currentContext);
        QVERIFY(QMetaObject::invokeMethod(window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(scratch.path()+"/second.pdf"))));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasEditDrafts());
    }
    void formWidgetsEditOnThePageAndSaveAnIsolatedSnapshot() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/forms.pdf",output=scratch.path()+"/filled.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/form-fields.pdf",path));QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto bytes=original.readAll();original.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::qWait(150);
        window->setProperty("fitting",false);QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0));QTest::qWait(100);
        QVERIFY(QMetaObject::invokeMethod(window,"toggleForms"));QTRY_VERIFY(reader->data().contains("forms"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto fields=reader->data().value("forms").toMap().value("fields").toList();QCOMPARE(fields.size(),8);QVERIFY(reader->editDrafts().isEmpty());
        auto *view=window->findChild<QQuickItem *>("pageList");QVERIFY(view);
        const auto reveal=[&](QQuickItem *item){const auto center=item->mapToItem(view,QPointF(item->width()/2,item->height()/2));const double target=view->property("contentY").toDouble()+center.y()-view->height()/2;view->setProperty("contentY",qBound(-24.0,target,qMax(-24.0,view->property("contentHeight").toDouble()-view->height()+24)));QTest::qWait(50);};
        QVariantMap textField,checkField,radioField,choiceField;
        for(const auto &value:fields){const auto f=value.toMap();if(f.value("kind")=="text" && f.value("editable").toBool() && !f.value("multiline").toBool())textField=f;else if(f.value("kind")=="checkBox")checkField=f;else if(f.value("kind")=="radio")radioField=f;else if(f.value("kind")=="comboBox")choiceField=f;}
        QVERIFY(!textField.isEmpty());auto *text=visualItem(window->contentItem(),"formText_"+textField.value("id").toString()+"_0");QVERIFY(text);QVERIFY(text->isVisible());
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,text->mapToScene(QPointF(text->width()/2,text->height()/2)).toPoint());QTest::keyClick(window,Qt::Key_A,Qt::ControlModifier);
        QInputMethodEvent input;input.setCommitString(QString::fromUtf8("Linux 中文"));QCoreApplication::sendEvent(text,&input);
        QTRY_COMPARE(reader->editDrafts().value("forms").toMap().value(textField.value("id").toString()).toMap().value("text").toString(),QString::fromUtf8("Linux 中文"));
        auto *check=visualItem(window->contentItem(),"formCheck_"+checkField.value("id").toString()+"_0");QVERIFY(check);reveal(check);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,check->mapToScene(QPointF(check->width()/2,check->height()/2)).toPoint());
        QTRY_COMPARE(reader->editDrafts().value("forms").toMap().value(checkField.value("id").toString()).toMap().value("checked").toBool(),!checkField.value("checked").toBool());
        auto *checkAction=QAccessible::queryAccessibleInterface(check)->actionInterface();QVERIFY(checkAction);
        checkAction->doAction(QAccessibleActionInterface::toggleAction());QTRY_VERIFY(!reader->editDrafts().value("forms").toMap().contains(checkField.value("id").toString()));
        checkAction->doAction(QAccessibleActionInterface::pressAction());QTRY_VERIFY(reader->editDrafts().value("forms").toMap().contains(checkField.value("id").toString()));QVERIFY(check->property("checked").toBool()==!checkField.value("checked").toBool());
        const int radioTarget=radioField.value("selected").toList().isEmpty() || radioField.value("selected").toList().first().toInt()!=1 ? 1 : 0;
        auto *radio=visualItem(window->contentItem(),"formRadio_"+radioField.value("id").toString()+"_"+QString::number(radioTarget));QVERIFY(radio);reveal(radio);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,radio->mapToScene(QPointF(radio->width()/2,radio->height()/2)).toPoint());
        QTRY_VERIFY(reader->editDrafts().value("forms").toMap().contains(radioField.value("id").toString()));
        QCOMPARE(reader->editDrafts().value("forms").toMap().value(radioField.value("id").toString()).toMap().value("selected").toInt(),radioTarget);
        QVERIFY(radio->property("checked").toBool());auto *firstRadio=visualItem(window->contentItem(),"formRadio_"+radioField.value("id").toString()+"_"+QString::number(1-radioTarget));QVERIFY(firstRadio);QVERIFY(!firstRadio->property("checked").toBool());
        auto *radioAction=QAccessible::queryAccessibleInterface(radio)->actionInterface();QVERIFY(radioAction);
        radioAction->doAction(QAccessibleActionInterface::toggleAction());QVERIFY(radio->property("checked").toBool());QCOMPARE(reader->editDrafts().value("forms").toMap().value(radioField.value("id").toString()).toMap().value("selected").toInt(),radioTarget);
        auto *choice=visualItem(window->contentItem(),"formChoice_"+choiceField.value("id").toString()+"_0");QVERIFY(choice);reveal(choice);choice->forceActiveFocus();
        const int choiceInitial=choice->property("currentIndex").toInt(),choiceTarget=choiceInitial>0 ? choiceInitial-1 : choiceInitial+1;
        QTest::keyClick(window,choiceInitial>0 ? Qt::Key_Up : Qt::Key_Down);QTest::keyClick(window,Qt::Key_Return);
        QTRY_VERIFY(reader->editDrafts().value("forms").toMap().contains(choiceField.value("id").toString()));
        QCOMPARE(reader->editDrafts().value("forms").toMap().value(choiceField.value("id").toString()).toMap().value("selected").toInt(),choiceTarget);
        QTest::keyClick(window,Qt::Key_Escape);
        const auto values=reader->editDrafts().value("forms").toMap();QVariantList payload;for(const auto &value:values)payload.append(value);
        const QVariant context=QVariantMap{{"reader",QVariant::fromValue(reader)},{"kind","forms"},{"forms",payload}};window->setProperty("exportContext",context);
        workspace.newTab();auto *other=workspace.activeReader();other->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));QTRY_COMPARE_WITH_TIMEOUT(other->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(other->pendingCommands(),0,10000);QVERIFY(other->editDrafts().isEmpty());
        // The save operation still belongs to the tab that opened it.
        QVERIFY(QMetaObject::invokeMethod(window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(output))));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(reader->editDrafts().isEmpty());QVERIFY(other->data().value("save_forms").isNull());
        ReaderController filled;filled.openFile(QUrl::fromLocalFile(output));QTRY_COMPARE_WITH_TIMEOUT(filled.pageCount(),2,10000);filled.submit("forms");QTRY_COMPARE_WITH_TIMEOUT(filled.pendingCommands(),0,10000);
        const auto saved=filled.data().value("forms").toMap().value("fields").toList();
        QSet<QString> found;
        for(const auto &value:saved){const auto f=value.toMap();if(f.value("name")==textField.value("name")){QCOMPARE(f.value("value").toString(),QString::fromUtf8("Linux 中文"));found.insert("text");}if(f.value("name")==checkField.value("name")){QCOMPARE(f.value("checked").toBool(),!checkField.value("checked").toBool());found.insert("check");}if(f.value("name")==radioField.value("name")){QCOMPARE(f.value("selected").toList().first().toInt(),radioTarget);found.insert("radio");}if(f.value("name")==choiceField.value("name")){QCOMPARE(f.value("selected").toList().first().toInt(),choiceTarget);found.insert("choice");}}
        QCOMPARE(found.size(),4);
        QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),bytes);
    }
    void mergeAndSplitDialogsUseVerifiedWritersAndCarryRemappedMarks() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/source.pdf",mergedPath=scratch.path()+"/merged.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto bytes=original.readAll();original.close();
        const auto folder=scratch.path()+"/split";QVERIFY(QDir().mkpath(folder));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::qWait(150);
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","highlight"},{"page",2},{"start",0},{"end",3},{"color","#E8BC5580"},{"note","split identity"}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"showMergeDialog"));auto *dialog=window->findChild<QObject *>("pageExports");QVERIFY(dialog);QTRY_VERIFY(dialog->property("visible").toBool());
        dialog->setProperty("additions",QVariantList{QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"),QUrl::fromLocalFile(root+"/tests/fixtures/annotated.pdf")});
        QVERIFY(QMetaObject::invokeMethod(dialog,"move",Q_ARG(QVariant,0),Q_ARG(QVariant,1)));
        QVERIFY(QMetaObject::invokeMethod(dialog,"saveMergeTo",Q_ARG(QVariant,QUrl::fromLocalFile(mergedPath))));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        const auto merged=reader->data().value("save_merge").toMap();QCOMPARE(merged.value("first_page_count").toInt(),3);QVERIFY(merged.value("page_count").toInt()>4);QCOMPARE(merged.value("appended_page_counts").toList().last().toInt(),1);
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(mergedPath));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),merged.value("page_count").toInt(),10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QCOMPARE(reopened.data().value("marks").toMap().value("annotations").toList().first().toMap().value("page").toInt(),2);
        QVERIFY(QMetaObject::invokeMethod(window,"showSplitDialog"));
        dialog->setProperty("outputDirectory",QUrl::fromLocalFile(folder));auto *ranges=window->findChild<QObject *>("splitRanges");QVERIFY(ranges);ranges->setProperty("text","1-2, 2-3");QVERIFY(QMetaObject::invokeMethod(dialog,"requestPlan"));
        QTRY_VERIFY(!dialog->property("planning").toBool());QVERIFY(dialog->property("error").toString().contains("more than one"));QVERIFY(reader->error().isEmpty());
        ranges->setProperty("text",QString::fromUtf8("3, 1–2"));QVERIFY(QMetaObject::invokeMethod(dialog,"requestPlan"));QTRY_VERIFY(!dialog->property("planning").toBool());QVERIFY2(dialog->property("error").toString().isEmpty(),qPrintable(dialog->property("error").toString()));
        const auto plan=dialog->property("plan").toMap();QCOMPARE(plan.value("parts").toList().size(),2);QCOMPARE(plan.value("parts").toList().first().toMap().value("pages").toList(),QVariantList({0,1}));
        QTRY_VERIFY(dialog->property("canWrite").toBool());auto *apply=window->findChild<QQuickItem *>("applyPageExport");QVERIFY(apply);QTest::qWait(100);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,apply->mapToScene(QPointF(apply->width()/2,apply->height()/2)).toPoint());
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QTRY_VERIFY(reader->data().contains("save_split"));QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        const auto report=reader->data().value("save_split").toMap();QCOMPARE(report.value("parts").toList().size(),2);
        ReaderController last;last.openFile(QUrl::fromLocalFile(report.value("parts").toList().last().toMap().value("destination_path").toString()));QTRY_COMPARE_WITH_TIMEOUT(last.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(last.pendingCommands(),0,10000);
        const auto mark=last.data().value("marks").toMap().value("annotations").toList().first().toMap();QCOMPARE(mark.value("page").toInt(),0);QCOMPARE(mark.value("note").toString(),QString("split identity"));
        QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),bytes);
        QVERIFY(QMetaObject::invokeMethod(window,"showSplitDialog"));dialog->setProperty("outputDirectory",QUrl::fromLocalFile(folder));QVERIFY(QMetaObject::invokeMethod(dialog,"requestPlan"));QTRY_VERIFY(!dialog->property("planning").toBool());QVERIFY(!dialog->property("canWrite").toBool());QCOMPARE(dialog->property("plan").toMap().value("conflicts").toList().size(),2);
    }
    void aiPreviewStreamingCancellationAndTabsUseTheRealLocalTransport() {
        MockChatServer server;QVERIFY2(server.listen(),"Loopback HTTP is required for this GUI check; no external service is contacted");
        const auto imageUrl=server.baseUrl()+"/unwanted-image";
        server.responses.append({{MockChatServer::delta({{"reasoning_content","provider rationale"}}),MockChatServer::delta({{"content","Answer [p.2] **ready**.\n![remote][image]\n[image]: "+imageUrl}}),MockChatServer::usage(),QByteArray("data: [DONE]\n\n")},70,200});
        MockChatServer::Response slow;slow.holdLast=true;slow.chunks={MockChatServer::delta({{"content","chunk0 "}}),QByteArray("data: [DONE]\n\n")};server.responses.append(slow);
        server.responses.append({{MockChatServer::delta({{"content","retry succeeded"}}),MockChatServer::usage(),QByteArray("data: [DONE]\n\n")},30,200});
        server.responses.append({{QByteArray("{\"error\":{\"message\":\"fixture rejection\"}}")},0,400});server.responses.append(slow);
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::qWait(150);
        window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","fixture"}});QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"ai")));
        auto *panel=window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QCOMPARE(server.requests.size(),0);
        const auto plan=reader->aiState().value("plan").toMap();QVERIFY(plan.value("is_local").toBool());
        auto *send=window->findChild<QQuickItem *>("sendAiRequest");QVERIFY(send);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,send->mapToScene(QPointF(send->width()/2,send->height()/2)).toPoint());
        QTRY_COMPARE(server.requests.size(),1);QVERIFY(reader->aiState().value("running").toBool());
        workspace.newTab();auto *other=workspace.activeReader();other->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));QTRY_COMPARE_WITH_TIMEOUT(other->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(other->pendingCommands(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(other->aiState().value("output").toString().isEmpty());QVERIFY(reader->aiState().value("output").toString().contains("Answer"));QVERIFY(!reader->aiState().value("output").toString().contains("provider rationale"));QCOMPARE(reader->aiState().value("reasoning").toString(),QString("provider rationale"));QCOMPARE(reader->aiState().value("usage").toMap().value("total_tokens").toInt(),10);
        workspace.selectTab(0);QTest::qWait(200);QCOMPARE(server.requests.size(),1); // Reference images must remain text.
        auto *answer=window->findChild<QObject *>("aiAnswerText");QVERIFY(answer);QVERIFY(!answer->property("text").toString().contains("<img"));
        QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,"p.2")));QTRY_COMPARE(window->property("currentPage").toInt(),1);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->startAi("local",plan));QTRY_COMPARE(server.requests.size(),2);QTRY_VERIFY(reader->aiState().value("output").toString().contains("chunk0"));reader->cancelAi();QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(reader->aiState().value("status").toString().contains("Cancel",Qt::CaseInsensitive));QTRY_COMPARE_WITH_TIMEOUT(server.activeConnections(),0,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);auto *retry=window->findChild<QQuickItem *>("retryAiRequest");QVERIFY(retry);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,retry->mapToScene(QPointF(retry->width()/2,retry->height()/2)).toPoint());QTRY_COMPARE(server.requests.size(),3);QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(reader->aiState().value("output").toString().contains("retry succeeded"));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->startAi("local",plan));QTRY_COMPARE(server.requests.size(),4);QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(reader->aiState().value("status").toString().contains("fixture rejection"));QVERIFY(reader->error().isEmpty());
        reader->invalidateAiPlan();QVERIFY(!reader->startAi("local",plan));QCOMPARE(server.requests.size(),4);
        QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(!reader->aiState().value("plan").toMap().isEmpty());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->startAi("local",reader->aiState().value("plan").toMap()));QTRY_COMPARE(server.requests.size(),5);
        // Closing must drain in-flight commands even for a hidden/background tab,
        // where the compositor need not drive QML animation timers.
        workspace.selectTab(1);window->hide();QVERIFY(reader->submit("ai_poll")>0);QVERIFY(reader->pendingCommands()>0);
        QPointer<ReaderController> closing=reader;workspace.closeTab(0);QTRY_VERIFY_WITH_TIMEOUT(closing.isNull(),10000);QTRY_COMPARE_WITH_TIMEOUT(server.activeConnections(),0,10000);QCOMPARE(workspace.activeReader(),other);
    }
    void secureCredentialRoundTripUsesAnIsolatedEphemeralAccount() {
        if(!qEnvironmentVariableIsSet("LYRA_READER_CHECK_VAULT"))QSKIP("Opt-in real vault check; use LYRA_READER_CHECK_VAULT=1 with an unlocked system vault");
        CredentialStore store;QSignalSpy events(&store,&CredentialStore::finished);
        const auto token=QUuid::createUuid().toString(QUuid::WithoutBraces),account="https://lyra-vault-check-"+token+".invalid/v1",secret="ephemeral-test-"+token;
        const auto completion=[&](quint64 id) {
            QElapsedTimer timer;timer.start();
            while(timer.elapsed()<15000) {
                while(!events.isEmpty()){const auto event=events.takeFirst();if(event[0].toULongLong()==id)return event;}
                events.wait(int(qMin<qint64>(1000,15000-timer.elapsed())));
            }
            return QVariantList{};
        };
        const auto written=completion(store.write(account,secret));
        const bool wrote=!written.isEmpty(),writeOk=wrote && written[3].toString().isEmpty();
        QString failure=wrote ? written[3].toString() : QString{};bool readOk=false,removed=false,absent=false;
        if(writeOk){const auto event=completion(store.read(account));readOk=!event.isEmpty() && event[2].toString()==secret && event[3].toString().isEmpty();if(!event.isEmpty() && !readOk)failure=event[3].toString();}
        const auto deleted=completion(store.remove(account));removed=!deleted.isEmpty() && deleted[3].toString().isEmpty();if(!deleted.isEmpty() && !removed)failure=deleted[3].toString();
        if(removed){const auto event=completion(store.read(account));absent=!event.isEmpty() && event[2].toString().isEmpty() && event[3].toString().isEmpty();}
        QVERIFY2(wrote && writeOk && readOk && removed && absent,qPrintable(failure.isEmpty()?QString("System vault did not complete the isolated round trip"):failure));
    }
    void coldNarrativeCitationsAndBooktabsPreviewTheIndexedRegion() { NativeCorpus::coldNarrativeAndTablePreviews(root); }
    void realLockedPapersUseNativeReferenceCrops() { NativeCorpus::realPapers(root); }
    void documentCommentsStayLiteralAndDoNotLoadRemoteImages() {
        MockChatServer server;QVERIFY(server.listen());QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/literal.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto note="<b>Literal annotation</b><img src='"+server.baseUrl()+"/unwanted-image'>";
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","square"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",100},{"y",100},{"width",100},{"height",70}}},{"color","#E8BC55FF"},{"note",note},{"strokeWidth",2}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"annotations")));QTest::qWait(700);QCOMPARE(server.requests.size(),0);
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().first().toMap().value("note").toString(),note);
    }
    void pageTextViewExposesReadOnlyAccessibleTextAndKeyboardSelection() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto firstPath=scratch.path()+"/reading.pdf",secondPath=scratch.path()+"/other.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",firstPath));QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",secondPath));
        WorkspaceController workspace;auto &reader=*workspace.activeReader();QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.rootContext()->setContextProperty("workspace",&workspace);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(firstPath));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        const bool shortcutFocus=QGuiApplication::platformName()=="offscreen" || QGuiApplication::focusWindow()==window;
        auto *readAction=window->findChild<QObject *>("readPageTextAction");QVERIFY(readAction);
        if(shortcutFocus)QTest::keyClick(window,Qt::Key_R,Qt::ControlModifier|Qt::ShiftModifier);
        else {qInfo()<<"Window lacks native shortcut focus; exercise its real Action. Global native shortcut coverage remains pending.";QVERIFY(QMetaObject::invokeMethod(readAction,"trigger",Q_ARG(QObject *,nullptr)));}
        auto *view=window->findChild<QQuickItem *>("pageTextView");auto *text=window->findChild<QQuickItem *>("accessiblePageText");QVERIFY(view && text);QTRY_VERIFY(view->isVisible());
        QTRY_VERIFY(!text->property("text").toString().isEmpty());QVERIFY(text->property("readOnly").toBool());QCOMPARE(text->property("textFormat").toInt(),int(Qt::PlainText));
        const auto snapshots=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!snapshots.isEmpty())QVERIFY(window->grabWindow().save(snapshots+"/lyrareader-page-text.png"));
        text->forceActiveFocus();QTest::keyClick(window,Qt::Key_A,Qt::ControlModifier);QCOMPARE(text->property("selectedText").toString(),text->property("text").toString());
        auto *interface=QAccessible::queryAccessibleInterface(text);QVERIFY(interface);QCOMPARE(interface->role(),QAccessible::EditableText);
        auto *accessible=interface->textInterface();QVERIFY(accessible);QCOMPARE(accessible->characterCount(),text->property("text").toString().size());QVERIFY(interface->state().readOnly);QVERIFY(!interface->state().editable);QVERIFY(interface->text(QAccessible::Name).contains("Page 1"));
        QTest::keyClick(window,Qt::Key_Home,Qt::ControlModifier);QCOMPARE(text->property("cursorPosition").toInt(),0);QCOMPARE(window->property("currentPage").toInt(),0);
        QTest::keyClick(window,Qt::Key_PageDown,Qt::AltModifier);QTRY_COMPARE(window->property("currentPage").toInt(),1);QTRY_VERIFY(text->property("text").toString().contains("Page 2"));
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));QCOMPARE(workspace.viewState(&reader).value("page").toInt(),1);QVERIFY(!workspace.viewState(&reader).contains("offset"));
        workspace.newTab();workspace.activeReader()->openFile(QUrl::fromLocalFile(secondPath));QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
        workspace.selectTab(0);QTRY_COMPARE(window->property("currentPage").toInt(),1);QTRY_VERIFY(text->property("text").toString().contains("Page 2"));text->forceActiveFocus();
        QTest::keyClick(window,Qt::Key_PageUp,Qt::AltModifier);QTRY_COMPARE(window->property("currentPage").toInt(),0);
        if(shortcutFocus)QTest::keyClick(window,Qt::Key_R,Qt::ControlModifier|Qt::ShiftModifier);
        else QVERIFY(QMetaObject::invokeMethod(readAction,"trigger",Q_ARG(QObject *,nullptr)));
        QTRY_VERIFY(!view->isVisible());
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
    }
    void renderingPerformanceRecordsRealQueueLatencyFramesAndRss() {
        if(!qEnvironmentVariableIsSet("LYRA_READER_CHECK_PERFORMANCE"))QSKIP("Opt-in native performance run; use LYRA_READER_CHECK_PERFORMANCE=1");
        const auto publish=[](const QVariantMap &report) {
            const auto output=qEnvironmentVariable("LYRA_READER_PERF_OUTPUT");
            if(!output.isEmpty()){QSaveFile file(output);const auto bytes=QJsonDocument::fromVariant(report).toJson();if(!file.open(QIODevice::WriteOnly) || file.write(bytes)!=bytes.size() || !file.commit())return false;}
            qInfo().noquote()<<"lyra-reader-performance:"<<QJsonDocument::fromVariant(report).toJson(QJsonDocument::Compact);return true;
        };
        const auto input=qEnvironmentVariable("LYRA_READER_PERF_PDF",QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf");
        bool validPage=false;const int pageIndex=qEnvironmentVariable("LYRA_READER_PERF_PAGE","0").toInt(&validPage);QVERIFY(validPage && pageIndex>=0);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto fixture=scratch.path()+"/performance.pdf";QVERIFY(QFile::copy(input,fixture));
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);window->setPersistentSceneGraph(false);
        window->setProperty("requestedPage",pageIndex);
        const bool native=QGuiApplication::platformName()!="offscreen";
        if(native)window->setMaximumSize(QSize(1200,820));window->resize(1200,820);
        if(native) {
            const bool exposed=QTest::qWaitForWindowExposed(window,5000);
            if(exposed)window->requestActivate();
            if(!exposed || !QTest::qWaitForWindowActive(window,2500)) {
                QVERIFY(publish({{"schema",2},{"phase","preflight"},{"qt",qVersion()},{"platform",QGuiApplication::platformName()},
                    {"requestedBackend",qEnvironmentVariable("QSG_RHI_BACKEND")},{"windowActive",window->isActive()},{"windowExposed",window->isExposed()},
                    {"interactivePresentationMeasured",false},{"inputBurstsAttempted",false},{"reason",exposed ? "Native window could not obtain keyboard focus; no interactive timing was attempted." : "Native window was not exposed within the preflight timeout; no interactive timing was attempted."}}));
                QSKIP("Native window was not exposed or active; input bursts were not attempted. Diagnostic JSON was saved.");
            }
        }
        Performance::Frames frames(window);QList<double> inputIntervals,refinement,guiIntervals,inputPacing,burstDurations;
        qint64 peakRss=Performance::memory("VmRSS"),lastTick=Performance::now();
        bool focusMaintained=true;
        QTimer sampler;connect(window,&QWindow::activeChanged,&sampler,[&]{if(native && !window->isActive())focusMaintained=false;});
        sampler.setInterval(10);connect(&sampler,&QTimer::timeout,window,[&] {
            const auto time=Performance::now();guiIntervals.append((time-lastTick)/1000.0);lastTick=time;peakRss=qMax(peakRss,Performance::memory("VmRSS"));
        });sampler.start();
        const auto openStart=Performance::now();reader.openFile(QUrl::fromLocalFile(fixture));
        QTRY_VERIFY_WITH_TIMEOUT(reader.pageCount()>0,60000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,60000);
        QVERIFY(pageIndex<reader.pageCount());
        const auto textured=[&]{auto *page=visualItem(window->contentItem(),QString("pdfPage%1").arg(pageIndex));return page && page->property("texturesReady").toBool();};
        QTRY_VERIFY_WITH_TIMEOUT(textured(),30000);frames.arm();window->update();QTRY_VERIFY_WITH_TIMEOUT(frames.queued()>0,10000);
        const auto openMs=(frames.queued()-openStart)/1000.0;
        auto *view=window->findChild<QQuickItem *>("pageList");QVERIFY(view);window->setProperty("fitting",false);
        constexpr int trials=30;
        for(int trial=0;trial<trials;++trial) {
            frames.clear();const auto begin=Performance::now();qint64 lastInput=begin;
            for(int step=0;step<12;++step) {
                const auto inputTime=Performance::now();if(step)inputPacing.append((inputTime-lastInput)/1000.0);lastInput=inputTime;
                const auto scale=step%3==0?2.7:step%3==1?4.0:3.6;
                QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,scale),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
                view->setProperty("contentX",double((step+trial)%8*70));
                QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,pageIndex),Q_ARG(QVariant,double(200+(step+trial)%8*70)/scale)));
                if(step<11)QTest::qWait(16);
            }
            const auto endInput=Performance::now();burstDurations.append((endInput-begin)/1000.0);bool armed=false;QTimer ready;ready.setInterval(5);
            connect(&ready,&QTimer::timeout,window,[&]{if(!armed && textured() && reader.pendingRasters()==0){armed=true;frames.arm();window->update();}});ready.start();
            QTimer::singleShot(2000,&ready,[&,trial] {
                auto *page=visualItem(window->contentItem(),QString("pdfPage%1").arg(pageIndex));
                QVariantMap state{{"trial",trial},{"currentPage",window->property("currentPage")},{"zoom",window->property("zoom")},{"contentY",view->property("contentY")},{"originY",view->property("originY")},{"pendingRasters",reader.pendingRasters()},{"error",reader.error()},{"jobs",RasterJobs::statistics()},{"budget",RenderBudget::statistics()}};
                if(page){state.insert("visibleRegion",page->property("visibleRegion"));state.insert("refined",page->property("refined"));state.insert("texturesReady",page->property("texturesReady"));state.insert("sceneY",page->mapToScene(QPointF(0,0)).y());}else state.insert("pageMissing",true);
                qInfo().noquote()<<"lyra-reader-performance-pending:"<<QJsonDocument::fromVariant(state).toJson(QJsonDocument::Compact);
            });
            QTRY_VERIFY_WITH_TIMEOUT(frames.queued()>0,30000);ready.stop();
            refinement.append((frames.queued()-lastInput)/1000.0);inputIntervals.append(frames.intervals(begin,endInput));
            if(!focusMaintained || (native && trial>=2 && inputIntervals.isEmpty()))break;
        }
        sampler.stop();
        QVariantMap report{{"schema",2},{"phase","bursts"},{"qt",qVersion()},{"platform",QGuiApplication::platformName()},{"graphicsApi",int(window->rendererInterface()->graphicsApi())},{"requestedBackend",qEnvironmentVariable("QSG_RHI_BACKEND")},
            {"architecture",QSysInfo::currentCpuArchitecture()},{"fixture",QFileInfo(input).fileName()},{"pages",reader.pageCount()},{"pageIndex",pageIndex},{"windowWidth",window->width()},{"windowHeight",window->height()},{"devicePixelRatio",window->effectiveDevicePixelRatio()},
            {"pdfOpenToTexturedFrameQueueMs",openMs},{"lastInputToTexturedFrameQueueMs",Performance::distribution(refinement)},{"duringInputFrameQueueIntervalsMs",Performance::distribution(inputIntervals)},
            {"trialsRequested",trials},{"trialsCompleted",refinement.size()},{"inputsPerBurst",12},{"targetInputIntervalMs",16},{"actualInputIntervalsMs",Performance::distribution(inputPacing)},{"inputBurstDurationMs",Performance::distribution(burstDurations)},{"percentileMethod","lower order statistic"},
            {"guiTenMsTimerIntervalsMs",Performance::distribution(guiIntervals)},{"rssPeakSampledBytes",peakRss},{"rssFinalBytes",Performance::memory("VmRSS")},{"processLifetimeRssHighWaterBytes",Performance::memory("VmHWM")},
            {"renderResources",RenderBudget::statistics()},{"rasterJobs",RasterJobs::statistics()},{"cpuLruKiB",ReaderController::cpuCacheKiB()},
            {"interactivePresentationMeasured",inputIntervals.size()>=6 && focusMaintained},{"inputBurstsAttempted",true},{"nativeFocusRequired",native},{"focusMaintained",focusMaintained},{"windowExposed",window->isExposed()},{"windowActive",window->isActive()},
            {"measurementNotes","Up to thirty 12-input zoom/pan bursts targeting 16 ms; actual delivery intervals are recorded. Last input starts before applying its zoom/pan change and includes GUI handling and 5 ms readiness polling. frameSwapped measures queued presentation, not physical display FPS. Insufficient input-period frame callbacks or lost native focus invalidate the sample and stop further bursts; no cause for missing callbacks is inferred. RSS includes Qt, PDFium, fonts and index memory; unsupported OS values are -1. The source ledger includes pre-raster capacity reservations. Driver allocations and Qt chrome are outside the pixel payload ledger."}};
        QVERIFY(publish(report));
        QVERIFY(RenderBudget::statistics().value("residentPeakBytes").toLongLong()<=RenderBudget::residentLimit);
        QVERIFY(RenderBudget::statistics().value("texturePeakBytes").toLongLong()<=RenderBudget::textureLimit);
        QVERIFY(RasterJobs::statistics().value("peakRunning").toInt()<=RasterJobs::maximumRunning);
        if(inputIntervals.size()<6 || !focusMaintained)QSKIP("Insufficient input-period frames or lost native focus; interactive performance remains unmeasured. Diagnostic JSON was saved.");
    }
    void completedBackgroundPixelsStayChargedWhileTheGuiIsBusy() {
        QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong(),0,10000);
        const auto denied=RenderBudget::statistics().value("residentDenied").toLongLong();
        std::vector<std::unique_ptr<ReaderController>> readers;
        for(int i=0;i<16;++i){readers.push_back(std::make_unique<ReaderController>());readers.back()->openFile(QUrl::fromLocalFile(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf"));}
        for(const auto &reader:readers){QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);}
        for(const auto &reader:readers)reader->requestPage(0,4);
        // Finished futures must retain their lease before the GUI caches/paints them.
        QThread::msleep(900);
        const auto queued=RenderBudget::statistics();QVERIFY(queued.value("residentBytes").toLongLong()>0);QVERIFY(queued.value("residentBytes").toLongLong()<=RenderBudget::residentLimit);
        QVERIFY(queued.value("residentDenied").toLongLong()>denied);
        for(const auto &reader:readers){QTRY_VERIFY_WITH_TIMEOUT(reader->completedRasters()>0,15000);QVERIFY(reader->error().isEmpty());}
        readers.clear();QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong(),0,10000);
    }
    void liveRenderBudgetsResistContentionAndReleaseHiddenWindows() {
        QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong(),0,10000);
        for(const auto kind:{RenderBudget::Kind::Resident,RenderBudget::Kind::Texture}) {
            std::atomic_int ready{0},admitted{0};std::atomic_bool release{false};std::vector<std::thread> workers;
            for(int i=0;i<16;++i)workers.emplace_back([&]{auto lease=RenderBudget::reserve(kind,32LL*1024*1024);if(lease)++admitted;++ready;while(!release.load())std::this_thread::yield();});
            while(ready.load()!=16)QTest::qWait(1);
            const auto snapshot=RenderBudget::statistics();release=true;for(auto &worker:workers)worker.join();
            QCOMPARE(admitted.load(),6);
            const auto key=kind==RenderBudget::Kind::Resident ? "residentBytes" : "textureBytes";
            QCOMPARE(snapshot.value(key).toLongLong(),192LL*1024*1024);QCOMPARE(RenderBudget::statistics().value(key).toLongLong(),0);
        }
        WorkspaceController first,second;QQmlApplicationEngine a,b;
        const auto load=[&](QQmlApplicationEngine &engine,WorkspaceController &workspace) {
            engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));
            auto *window=engine.rootObjects().isEmpty()?nullptr:qobject_cast<QQuickWindow *>(engine.rootObjects().first());
            if(window){window->setPersistentSceneGraph(false);if(QGuiApplication::platformName()!="offscreen")window->setMaximumSize(QSize(960,640));window->resize(960,640);}
            workspace.openFile(QUrl::fromLocalFile(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf"));return window;
        };
        auto *one=load(a,first);auto *two=load(b,second);QVERIFY(one && two);
        QTRY_COMPARE_WITH_TIMEOUT(first.activeReader()->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(second.activeReader()->pageCount(),9,10000);
        QTRY_COMPARE_WITH_TIMEOUT(first.activeReader()->pendingCommands(),0,10000);QTRY_COMPARE_WITH_TIMEOUT(second.activeReader()->pendingCommands(),0,10000);QTest::qWait(150);
        one->setProperty("fitting",false);two->setProperty("fitting",false);
        QVERIFY(QMetaObject::invokeMethod(one,"changeZoom",Q_ARG(QVariant,4.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(two,"changeZoom",Q_ARG(QVariant,3.8),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        const auto ready=[&](QQuickWindow *window){auto *page=visualItem(window->contentItem(),"pdfPage0");return page && page->property("refined").toBool();};
        QTRY_VERIFY_WITH_TIMEOUT(ready(one) && ready(two),15000);
        auto *view=one->findChild<QQuickItem *>("pageList");QVERIFY(view);
        for(int i=0;i<12;++i){view->setProperty("contentX",i*45.0);view->setProperty("contentY",300+i*45.0);QTest::qWait(8);}
        QTRY_VERIFY_WITH_TIMEOUT(ready(one),15000);QTRY_COMPARE_WITH_TIMEOUT(first.activeReader()->pendingRasters(),0,15000);
        QVERIFY(!one->grabWindow().isNull());QVERIFY(!two->grabWindow().isNull());
        const auto stats=RenderBudget::statistics();QVERIFY(stats.value("residentBytes").toLongLong()>0);QVERIFY(stats.value("textureBytes").toLongLong()>0);
        QVERIFY(stats.value("residentPeakBytes").toLongLong()<=RenderBudget::residentLimit);QVERIFY(stats.value("texturePeakBytes").toLongLong()<=RenderBudget::textureLimit);
        QVERIFY(RasterJobs::statistics().value("peakRunning").toInt()<=RasterJobs::maximumRunning);
        QVERIFY(RasterJobs::statistics().value("peakQueued").toInt()<=RasterJobs::maximumQueued);
        one->hide();one->releaseResources();
        auto *page=visualItem(one->contentItem(),"pdfPage0");QVERIFY(page);QTRY_VERIFY(!page->property("loaded").toBool());
        two->hide();two->releaseResources();
        QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong(),0,10000);
        QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("textureBytes").toLongLong(),0,10000);
        one->show();QTRY_VERIFY_WITH_TIMEOUT(ready(one),15000);QVERIFY(!one->grabWindow().isNull());
    }
    void deepZoomRefinesVisibleTilesWithoutSeamsAndSharesTheCacheBudget() {
        ReaderController reader;QQmlApplicationEngine engine;
        engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/alpha-crop.pdf"));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTest::qWait(150); // Let the initial layout and saved-position restore finish.
        auto *view=window->findChild<QObject *>("pageList");QVERIFY(view);
        window->setProperty("fitting",false);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,3.7),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QTest::qWait(100);
        view->setProperty("contentX",1200.0);view->setProperty("contentY",640.0);
        QTRY_COMPARE(view->property("contentX").toDouble(),1200.0);
        const auto refined=[&] {const auto *page=visualItem(window->contentItem(),"pdfPage0");return page && page->property("refined").toBool() && page->property("loadedTileCount").toInt()>0;};
        QTRY_VERIFY_WITH_TIMEOUT(refined(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingRasters(),0,10000);QTest::qWait(100);
        auto *page=visualItem(window->contentItem(),"pdfPage0");QVERIFY(page);
        const double zoom=window->property("zoom").toDouble();
        const double native=zoom*window->effectiveDevicePixelRatio();const int level=int(std::ceil(std::log2(native)*4));
        const auto tiles=reader.requestTiles(1,0,level,QRectF(400,180,130,70),{});QVERIFY(!tiles.isEmpty());
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingRasters(),0,10000);
        // One sample border per edge; irrational density tiers may ceil one extra pixel.
        for(const auto &tile:tiles){const auto image=reader.cachedTile(tile.key);QVERIFY(!image.isNull());QVERIFY(image.width()<=515 && image.height()<=515);QVERIFY(image.sizeInBytes()<=515*515*4);QVERIFY(tile.scale>=native);}
        reader.clearTileDemand(1);
        const auto checkBlack=[&](const QImage &frame,const QColor &expected) {
            const double sx=double(frame.width())/window->width(),sy=double(frame.height())/window->height();
            int count=0;
            for(int x=416;x<=520;x+=2){const auto p=page->mapToScene(QPointF(x*zoom,200*zoom));const int px=qRound(p.x()*sx),py=qRound(p.y()*sy);if(px<0 || py<0 || px>=frame.width() || py>=frame.height())continue;const auto color=frame.pixelColor(px,py);if(qAbs(color.red()-expected.red())>3 || qAbs(color.green()-expected.green())>3 || qAbs(color.blue()-expected.blue())>3)return false;++count;}
            return count>=10;
        };
        const auto original=window->grabWindow();QVERIFY2(checkBlack(original,QColor(0,0,0)),"The black patch must stay solid across tile boundaries");
        const auto completed=reader.completedRasters();window->setProperty("paperAppearance","night");QTest::qWait(150);
        QVERIFY(checkBlack(window->grabWindow(),QColor(201,197,189)));QCOMPARE(reader.completedRasters(),completed);
        for(int i=0;i<8;++i){view->setProperty("contentX",double(i*80));view->setProperty("contentY",double(500+i*100));}
        QTRY_VERIFY_WITH_TIMEOUT(refined(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingRasters(),0,10000);
        QVERIFY(ReaderController::cpuCacheKiB()<=96*1024);
        ReaderController another,third;
        const auto longPdf=QUrl::fromLocalFile(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf");
        another.openFile(longPdf);third.openFile(longPdf);QTRY_COMPARE_WITH_TIMEOUT(another.pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(third.pageCount(),9,10000);
        for(int i=0;i<9;++i){another.requestPage(i,4);third.requestPage(i,4);}
        QTRY_COMPARE_WITH_TIMEOUT(another.pendingRasters(),0,15000);QTRY_COMPARE_WITH_TIMEOUT(third.pendingRasters(),0,15000);
        QVERIFY(ReaderController::cpuCacheKiB()<=96*1024);QVERIFY(refined());
        const auto snapshots=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!snapshots.isEmpty())QVERIFY(window->grabWindow().save(snapshots+"/lyrareader-deep-zoom.png"));
    }
    void referencesFiguresAndSectionsUseRealAsynchronousPreviews() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        for(const auto &name:{"numeric-citations.pdf","cross-references.pdf","section-references.pdf"})
            QVERIFY(QFile::copy(root+"/tests/fixtures/"+name,scratch.path()+"/"+name));
        WorkspaceController workspace;QQmlApplicationEngine engine;
        engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);
        engine.rootContext()->setContextProperty("reader",workspace.activeReader());
        engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        auto *preview=workspace.preview();
        workspace.openFile(QUrl::fromLocalFile(scratch.path()+"/numeric-citations.pdf"));
        auto *reader=workspace.activeReader();QTRY_VERIFY_WITH_TIMEOUT(reader->pageCount()>1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("citations",{{"page",0}});
        QTRY_VERIFY_WITH_TIMEOUT(reader->data().contains("citations"),10000);
        QVariantMap group;
        for(const auto &value:reader->data().value("citations").toList())if(value.toMap().value("labels").toList().size()>1){group=value.toMap();break;}
        QVERIFY(!group.isEmpty());
        auto click=[&](const QVariantMap &hit) {
            const double x=hit.value("x_pt").toDouble()+hit.value("width_pt").toDouble()/2;
            const double y=hit.value("y_pt").toDouble()+hit.value("height_pt").toDouble()/2;
            return QMetaObject::invokeMethod(window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,x),Q_ARG(QVariant,y),Q_ARG(QVariant,320),Q_ARG(QVariant,200));
        };
        const auto offset=window->property("pageList").value<QObject *>()->property("contentY").toDouble();
        QVERIFY(click(group));QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);
        QCOMPARE(preview->model().value("kind").toString(),QString("reference"));
        QCOMPARE(preview->model().value("entries").toList().size(),group.value("labels").toList().size());
        QCOMPARE(preview->model().value("page").toInt(),1); // The bibliography, not the source citation page.
        for(const auto &entry:preview->model().value("entries").toList())QVERIFY(!entry.toMap().value("text").toString().isEmpty());
        QCOMPARE(window->property("pageList").value<QObject *>()->property("contentY").toDouble(),offset);
        auto *status=window->findChild<QObject *>("operationStatusLabel");QVERIFY(status);window->setProperty("operationStatus","Earlier export completed");
        preview->togglePin();const auto pinned=preview->model();preview->openAt(reader,0,10,10,100,100,1);QCOMPARE(preview->model(),pinned);
        QVERIFY(status->property("text").toString().contains("pinned"));QCOMPARE(window->property("operationStatus").toString(),QString("Earlier export completed"));
        window->setProperty("operationStatus","A newer export completed");QCOMPARE(status->property("text").toString(),QString("A newer export completed"));
        preview->togglePin();QCOMPARE(status->property("text").toString(),QString("A newer export completed"));preview->showEntry(0);
        const auto ready=[&] {const auto *image=visualItem(window->contentItem(),"referencePreviewImage");return image && image->property("status").toInt()==1;};
        QTRY_VERIFY_WITH_TIMEOUT(ready(),10000);
        const auto cropFrame=window->grabWindow();auto *crop=visualItem(window->contentItem(),"referencePreviewImage");QVERIFY(crop);
        const auto bounds=crop->mapRectToScene(QRectF(0,0,crop->width(),crop->height()));
        const double cropDprX=double(cropFrame.width())/window->width(),cropDprY=double(cropFrame.height())/window->height();
        const auto area=QRectF(bounds.x()*cropDprX,bounds.y()*cropDprY,bounds.width()*cropDprX,bounds.height()*cropDprY).toAlignedRect().intersected(cropFrame.rect());
        int black=0,white=0;for(int y=area.top();y<area.bottom();++y)for(int x=area.left();x<area.right();++x){const auto c=cropFrame.pixelColor(x,y);if(c.red()<80 && c.green()<80 && c.blue()<80)++black;if(c.red()>245 && c.green()>245 && c.blue()>245)++white;}
        QVERIFY2(black>20 && white>100,"The budgeted region must render real bibliography ink and paper");
        const auto firstSource=crop->property("source").toUrl();preview->showEntry(1);
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"referencePreviewImage") && visualItem(window->contentItem(),"referencePreviewImage")->property("source").toUrl()!=firstSource,10000);
        QTRY_VERIFY_WITH_TIMEOUT(ready(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingRasters(),0,10000);QTest::qWait(100);
        const auto beforePaperJobs=RasterJobs::statistics().value("completed").toLongLong();
        window->setProperty("paperAppearance","warm");QTest::qWait(200);
        QCOMPARE(RasterJobs::statistics().value("completed").toLongLong(),beforePaperJobs);
        window->setProperty("paperAppearance","original");QTest::qWait(50);
        QVERIFY(!preview->imageUrl(450,1.5,"original").isEmpty());
        const auto snapshotDirectory=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");
        if(!snapshotDirectory.isEmpty())QVERIFY(window->grabWindow().save(snapshotDirectory+"/lyrareader-preview.png"));
        preview->jump();QTRY_VERIFY(window->property("canGoBack").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"goBack"));
        QTRY_VERIFY(qAbs(window->property("pageList").value<QObject *>()->property("contentY").toDouble()-offset)<.1);
        QSignalSpy newWindow(&workspace,&WorkspaceController::newWindowRequested);preview->openWindow();QCOMPARE(newWindow.size(),1);
        QCOMPARE(newWindow.first().at(2).toDouble(),preview->model().value("region").toMap().value("y_pt").toDouble());
        workspace.openFile(QUrl::fromLocalFile(scratch.path()+"/cross-references.pdf"));
        QVERIFY(!preview->visible());reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);
        reader->submit("caption_mentions",{{"page",0}});QTRY_VERIFY_WITH_TIMEOUT(reader->data().contains("caption_mentions"),10000);
        const auto mentions=reader->data().value("caption_mentions").toList();QVERIFY(!mentions.isEmpty());
        for(const auto &mention:mentions) {
            QVERIFY(click(mention.toMap()));QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);
            QCOMPARE(preview->model().value("kind").toString(),QString("figure"));
            QTRY_VERIFY_WITH_TIMEOUT(ready(),10000);
            QVERIFY(!preview->model().value("caption").toString().isEmpty());preview->close();
        }
        workspace.openFile(QUrl::fromLocalFile(scratch.path()+"/section-references.pdf"));reader=workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);reader->submit("links",{{"page",0}});
        QTRY_VERIFY_WITH_TIMEOUT(reader->data().contains("links"),10000);
        const auto links=reader->data().value("links").toList();QCOMPARE(links.size(),2);
        for(int i=0;i<links.size();++i) {
            QVERIFY(click(links.at(i).toMap()));QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);
            QCOMPARE(preview->model().value("kind").toString(),QString("section"));
            if(i==0)QCOMPARE(preview->model().value("section_title").toString(),QString("2 Method"));
            else QVERIFY(preview->model().value("section_title").toString().isEmpty());
            preview->close();
        }
    }
    void tabsRetainDocumentsAndSharedSearchAndMarksWork(){
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto firstPath=scratch.path()+"/first.pdf",secondPath=scratch.path()+"/second.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",firstPath));
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",secondPath));
        WorkspaceController workspace;
        QQmlApplicationEngine engine;
        engine.addImageProvider(QStringLiteral("lyrapreview"),new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);
        engine.rootContext()->setContextProperty("reader",workspace.activeReader());
        engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(firstPath));
        auto *first=workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(first->pageCount(),1,10000);
        QTRY_VERIFY_WITH_TIMEOUT(first->data().contains("marks"),10000);
        const auto textRequest=first->submit("text",{{"page",0}});
        Q_UNUSED(textRequest);
        QTRY_VERIFY_WITH_TIMEOUT(first->textPages().contains("0"),10000);
        QSignalSpy reopened(first,&ReaderController::openFinished);
        workspace.openFile(QUrl::fromLocalFile(secondPath));
        auto *second=workspace.activeReader();
        QVERIFY(second!=first);
        QTRY_VERIFY_WITH_TIMEOUT(second->pageCount()>1,10000);
        workspace.selectTab(0);
        QCOMPARE(workspace.activeReader(),first);
        QCOMPARE(reopened.count(),0);
        QVERIFY(window->setProperty("searchQuery",QString("LyraReader")));
        QVERIFY(QMetaObject::invokeMethod(window,"runSearch"));
        QTRY_VERIFY_WITH_TIMEOUT(!window->property("searchResults").toList().isEmpty(),10000);
        QVERIFY(QMetaObject::invokeMethod(window,"addBookmark"));
        QTRY_COMPARE_WITH_TIMEOUT(first->data().value("marks").toMap().value("bookmarks").toList().size(),1,10000);
        window->setProperty("selection",QVariantMap{{"page",0},{"start",0},{"end",3}});
        QVERIFY(QMetaObject::invokeMethod(window,"markSelection",Q_ARG(QVariant,"highlight")));
        QTRY_COMPARE_WITH_TIMEOUT(first->data().value("marks").toMap().value("annotations").toList().size(),1,10000);
        const auto other=second->data().value("marks").toMap().value("annotations").toList();
        QVERIFY(other.isEmpty());
        first->submit("marks_undo");
        QTRY_COMPARE_WITH_TIMEOUT(first->data().value("marks").toMap().value("annotations").toList().size(),0,10000);
        first->submit("marks_redo");
        QTRY_COMPARE_WITH_TIMEOUT(first->data().value("marks").toMap().value("annotations").toList().size(),1,10000);
        const auto note=first->data().value("marks").toMap().value("annotations").toList().first();
        QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,note),Q_ARG(QVariant,true)));
        auto *editor=window->findChild<QObject *>("annotationEditor");
        auto *noteField=window->findChild<QObject *>("annotationNoteText");
        QVERIFY(editor);QVERIFY(noteField);
        QTRY_VERIFY(editor->property("opened").toBool());
        QVERIFY(noteField->setProperty("text",QString("Saved while switching tabs 中文")));
        QVERIFY(!first->noteDrafts().isEmpty());
        workspace.selectTab(1); // Flush before the debounce timer fires.
        QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        QVERIFY(first->noteDrafts().isEmpty());
        QCOMPARE(first->data().value("marks").toMap().value("annotations").toList().first().toMap().value("note").toString(),QString("Saved while switching tabs 中文"));
        window->setProperty("overviewVisible",true);
        const QVariant operation=QVariantMap{{"Delete",QVariantMap{{"pages",QVariantList{1}}}}};
        QVERIFY(QMetaObject::invokeMethod(window,"pageOperation",Q_ARG(QVariant,operation)));
        QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),2,10000);
        QVERIFY(second->data().value("marks").toMap().value("page_pending").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"undo"));
        QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),3,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"redo"));
        QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),2,10000);
        QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);
        workspace.closeTab(1);
        QCOMPARE(workspace.tabs().size(),2);
        auto *closeDialog=window->findChild<QObject *>("closeChangesConfirmation");
        QVERIFY(closeDialog);
        QTRY_VERIFY(closeDialog->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(closeDialog,"reject"));
        second->submit("page_discard");
        QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),3,10000);
        QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);
        // Two edits can complete on the worker before the GUI receives the first result.
        second->submit("page_stage",{{"operation",operation}});
        second->submit("page_undo");
        QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);
        QCOMPARE(second->pageCount(),3);
        QVERIFY(!second->data().value("marks").toMap().value("page_pending").toBool());
        workspace.closeTab(1);
        QCOMPARE(workspace.tabs().size(),1);
    }
};

int main(int argc, char **argv) {
    QApplication application(argc, argv);
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/LyraReaderSansSC-Regular.ttf"));
    QCoreApplication::setOrganizationName("LyraReaderChecks");
    QCoreApplication::setApplicationName("LyraReaderChecks");
    QTemporaryDir settingsDirectory;
    if(!settingsDirectory.isValid())return 2;
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat,QSettings::UserScope,settingsDirectory.path());
    QQuickStyle::setStyle("Fusion");
    if (argc < 2) return 2;
    ReaderChecks checks;
    checks.root = QDir(QString::fromLocal8Bit(argv[1])).absolutePath();
    // Remove the fixture root; preserve QTest's optional function/filter arguments.
    QList<char *> testArguments{argv[0]};
    for(int i=2;i<argc;++i)testArguments.append(argv[i]);
    return QTest::qExec(&checks,int(testArguments.size()),testArguments.data());
}
#include "ReaderChecks.moc"
