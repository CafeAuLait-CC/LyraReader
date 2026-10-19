#include "ReaderController.h"
#include "PageItem.h"
#include "PaperAppearance.h"
#include "PdfPrintJob.h"
#include <QPrinter>
#include "AnnotationOverlay.h"
#include "WorkspaceController.h"
#include <QApplication>
#include <QFontDatabase>
#include <QDir>
#include <QSignalSpy>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSettings>
#include <QTemporaryDir>
#include <QtTest>
#include <functional>

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
        qmlRegisterType<AnnotationOverlay>("LyraReader",1,0,"PdfAnnotations");
    }
    void wholeWindowSurvivesTextureReplacementAndPageJump() {
        ReaderController reader;
        QQmlApplicationEngine engine;
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
        QTRY_VERIFY_WITH_TIMEOUT(!reader.cachedPage(0,window->property("zoom").toDouble()*window->effectiveDevicePixelRatio()).isNull(),10000);
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
    void tabsRetainDocumentsAndSharedSearchAndMarksWork(){
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto firstPath=scratch.path()+"/first.pdf",secondPath=scratch.path()+"/second.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",firstPath));
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",secondPath));
        WorkspaceController workspace;
        QQmlApplicationEngine engine;
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
        QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,note)));
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
    // The root argument belongs to this harness, not QTest's test-function selection.
    int testArgc = 1;
    return QTest::qExec(&checks, testArgc, argv);
}
#include "ReaderChecks.moc"
