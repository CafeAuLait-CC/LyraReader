#include "DisplayCalibration.h"
#include "AuditController.h"
#include "NavigationController.h"
#include "FileDialogNavigation.h"
#include "AuxiliaryWindowPolicy.h"
#include "ReaderController.h"
#include "PageItem.h"
#include "CropItem.h"
#include "ContentDragItem.h"
#include "PaperAppearance.h"
#include "PdfPrintJob.h"
#include "NativeRaster.h"
#include "PreviewController.h"
#include "MockChatServer.h"
#include "PerformanceRecorder.h"
#include "NativeCorpusChecks.h"
#include <QJsonDocument>
#include <QCryptographicHash>
#include <QSaveFile>
#include <QSysInfo>
#include <QUuid>
#include <QPrinter>
#include <QPainter>
#include <QPdfWriter>
#include <QScopeGuard>
#include <QSemaphore>
#include <QThreadPool>
#include <QtConcurrentRun>
#include "RasterCache.h"
#include "AnnotationOverlay.h"
#include "WorkspaceController.h"
#include <QApplication>
#include <QClipboard>
#include <QBuffer>
#include <QAccessible>
#include <QFontDatabase>
#include <QDir>
#include <QDirIterator>
#include <QSignalSpy>
#include <QQmlApplicationEngine>
#include <QQmlError>
#include <QQmlContext>
#include <QJSValue>
#include <QUrlQuery>
#include <QInputMethodEvent>
#include <QQmlExpression>
#include <QProcess>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QQuickItemGrabResult>
#include <QRegularExpression>
#include <QQmlProperty>
#include <QSGRendererInterface>
#include <QSettings>
#include <QTemporaryDir>
#include <QtTest>
#include <functional>
#include <thread>
#include <vector>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdlib>

// Exercise the production copy command without reading or replacing a user's clipboard.
class RecordingClipboardWorkspace final : public WorkspaceController {
public:
    QString copied;
    int copies=0;
    void copyText(const QString &text) override {copied=text;++copies;}
};

class FakeCredentialStore final : public CredentialStore {
public:
    struct Request { VaultOperation operation; QString key,secret; Completion complete; };
    QList<Request> requests;
    void reply(int index,const QString &secret={},const QString &error={}) {
        auto completion=std::move(requests[index].complete);completion(secret,error);
    }
protected:
    void startVault(VaultOperation operation,const QString &key,const QString &secret,Completion completion) override {
        requests.append({operation,key,secret,std::move(completion)});
    }
};

static void registerReaderTypes() {
    qmlRegisterUncreatableType<ReaderController>("LyraReader",1,0,"ReaderController","Created by host");
    qmlRegisterType<AuditController>("LyraReader",1,0,"AuditController");
    qmlRegisterType<NavigationController>("LyraReader",1,0,"NavigationController");
    qmlRegisterType<FileDialogNavigation>("LyraReader",1,0,"FileDialogNavigation");
    qmlRegisterType<DisplayCalibration>("LyraReader",1,0,"DisplayCalibration");
    qmlRegisterType<AuxiliaryWindowPolicy>("LyraReader",1,0,"AuxiliaryWindowPolicy");
    qmlRegisterType<PageItem>("LyraReader",1,0,"PdfPage");
    qmlRegisterType<CropItem>("LyraReader",1,0,"PdfCrop");
    qmlRegisterType<ContentDragItem>("LyraReader",1,0,"ContentDragPreview");
    qmlRegisterType<AnnotationOverlay>("LyraReader",1,0,"PdfAnnotations");
}

// Reserve a real raster admission slot without starting a worker. Cleanup balances the
// counters even when a test assertion returns before it explicitly releases the slot.
struct HeldRasterAdmission {
    RasterJobs::Handle ticket=RasterJobs::enqueue();
    void release(){if(ticket){RasterJobs::Run completed(std::move(ticket));}}
    ~HeldRasterAdmission(){release();}
};

// A real process boundary: no QObject destructors or cleanup can retire the crash fixture.
static int quitRecoveryChild(int argc,char **argv) {
    if(argc!=5)return 2;
    const auto mode=QString::fromLocal8Bit(argv[2]),path=QString::fromLocal8Bit(argv[3]),cache=QString::fromLocal8Bit(argv[4]);
    qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());
    QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
    int count=1;QApplication application(count,argv);application.setQuitOnLastWindowClosed(false);
    QCoreApplication::setOrganizationName("LyraReaderChecks");QCoreApplication::setApplicationName("LyraReaderQuitChild");
    QSettings::setDefaultFormat(QSettings::IniFormat);QSettings::setPath(QSettings::IniFormat,QSettings::UserScope,cache+"/settings");
    QQuickStyle::setStyle("Fusion");registerReaderTypes();
    auto wait=[](const std::function<bool()> &ready){QElapsedTimer timer;timer.start();while(!ready() && timer.elapsed()<15000){QCoreApplication::processEvents(QEventLoop::AllEvents,10);QThread::msleep(1);}return ready();};
    NativeCorpus::Viewer view;if(!view.window)return 3;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
    if(!wait([&]{return reader->pageCount()==3 && !reader->loading() && reader->pendingCommands()==0;}))return 4;
    reader->submit("bookmark_create",{{"page",0},{"title","Process-boundary bookmark"},{"yPt",20}});
    if(!wait([&]{return reader->pendingCommands()==0 && reader->hasUnsavedChanges();}))return 5;
    reader->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{1}},{"quarter_turns",1}}}}}});
    if(!wait([&]{return reader->pendingCommands()==0 && reader->data().value("marks").toMap().value("page_pending").toBool();}))return 6;
    if(mode=="crash")std::_Exit(9);
    const auto decision=mode=="discard-event"?QString("discard"):mode;
    if(decision!="save" && decision!="discard")return 7;
    auto *quit=view.workspace.quitCoordinator();int accepted=0;QObject::connect(quit,&QuitCoordinator::accepted,&application,[&]{++accepted;});
    if(mode=="discard-event")application.installEventFilter(quit);
    view.workspace.requestQuit();if(!wait([&]{return quit->phase()=="prompt";}))return 8;
    quit->decide(decision);if(!wait([&]{return !quit->busy();}) || accepted!=1 || view.window->isVisible()){qWarning()<<quit->message();return 10;}
    if(mode=="discard-event") {
        QCoreApplication::processEvents(QEventLoop::AllEvents,50);
        QEvent event(QEvent::Quit);QCoreApplication::sendEvent(&application,&event);
        QCoreApplication::processEvents(QEventLoop::AllEvents,50);
        if(quit->busy() || accepted!=1 || view.window->isVisible()){qWarning()<<"Accepted quit restarted the closed editors"<<quit->phase()<<accepted;return 11;}
    }
    std::_Exit(9);
}

// This headless worker exits while HTTP is still in flight, without destructors,
// cancellation or an explicit Save. Only the already completed timer write survives.
static int regionAutosaveCrashChild(int argc,char **argv) {
    if(argc!=4)return 2;
    const auto path=QString::fromLocal8Bit(argv[2]),cache=QString::fromLocal8Bit(argv[3]);qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());
    int count=1;QApplication application(count,argv);application.setQuitOnLastWindowClosed(false);
    auto wait=[](const std::function<bool()> &ready){QElapsedTimer timer;timer.start();while(!ready() && timer.elapsed()<15000){QCoreApplication::processEvents(QEventLoop::AllEvents,10);QThread::msleep(1);}return ready();};
    MockChatServer server;if(!server.listen())return 3;server.responses.append({{MockChatServer::delta({{"content","RECOVERED_PARTIAL"}}),QByteArray("data: [DONE]\n\n")},50,200,true});
    ReaderController reader;reader.openFile(QUrl::fromLocalFile(path));if(!wait([&]{return reader.pageCount()==1 && !reader.loading() && !reader.pendingCommands();}))return 4;
    if(!reader.captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1) || !wait([&]{return reader.aiRegion().contains("image_png");}))return 5;
    reader.setAiRegionQuestion("SENT_BEFORE_ABRUPT_EXIT");if(!wait([&]{return !reader.hasUnsavedReadingNotes();}))return 6;
    reader.prepareAiRegion({{"baseUrl",server.baseUrl()},{"model","synthetic-crash-autosave"},{"imageInput",false}});if(!wait([&]{return !reader.aiState().value("plan").toMap().isEmpty() && !reader.pendingCommands();}))return 7;
    if(!reader.startAi("local",reader.aiState().value("plan").toMap()) || !wait([&]{return reader.aiState().value("output").toString().contains("RECOVERED_PARTIAL") && reader.aiState().value("running").toBool() && reader.aiRegion().value("saved").toBool() && !reader.pendingCommands();}))return 8;
    const QJsonObject proof{{"id",reader.aiRegion().value("history_id").toString()},{"turn",reader.aiState().value("regionTurn").toString()},{"png_sha256",QString::fromLatin1(QCryptographicHash::hash(QByteArray::fromBase64(reader.aiRegion().value("image_png").toByteArray()),QCryptographicHash::Sha256).toHex())},{"requests",server.requests.size()}};
    QFile receipt(cache+"/autosave-child-receipt.json");const auto bytes=QJsonDocument(proof).toJson(QJsonDocument::Compact);if(!receipt.open(QIODevice::WriteOnly) || receipt.write(bytes)!=bytes.size() || !receipt.flush())return 10;
    std::_Exit(9);
}

static QQuickItem *visualItem(QQuickItem *root,const QString &name) {
    if(root->objectName()==name)return root;
    for(auto *child:root->childItems())if(auto *found=visualItem(child,name))return found;
    return nullptr;
}
static bool clickDialogButton(QQuickWindow *window,QObject *dialog,const QString &text) {
    auto *footer=qvariant_cast<QQuickItem *>(dialog->property("footer"));
    if(!footer)return false;
    for(auto *button:footer->findChildren<QQuickItem *>())if(button->property("text").toString()==text &&
        button->metaObject()->indexOfSignal("clicked()")>=0 && button->isVisible() && button->isEnabled()) {
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,button->mapToScene(QPointF(button->width()/2,button->height()/2)).toPoint());
        return true;
    }
    return false;
}

static QStringList qmlBindingLoops(const QSignalSpy &warnings) {
    QStringList result;
    for(const auto &arguments:warnings)for(const auto &error:qvariant_cast<QList<QQmlError>>(arguments.first()))
        if(error.description().contains("Binding loop"))result.append(error.toString());
    return result;
}

// A native compositor can acknowledge a different initial size after engine data
// is ready. Drain that configuration and the viewport's queued fit before input.
static bool settleReaderViewport(QQuickWindow *window) {
    QElapsedTimer timer;timer.start();QVariantList previous;int stable=0;
    while(timer.elapsed()<5000) {
        QTest::qWait(40);auto *list=visualItem(window->contentItem(),"pageList");if(!list)return false;
        const QVariantList current{window->width(),window->height(),window->effectiveDevicePixelRatio(),window->property("calibrationFactor"),window->property("zoom"),list->width(),list->height(),list->property("contentWidth"),list->property("contentHeight"),list->property("contentX"),list->property("contentY")};
        if(current==previous && !window->property("positionRestoring").toBool())++stable;else stable=0;
        if(stable>=3)return true;previous=current;
    }
    return false;
}

// Wait for the native layout and its clipping bounds before injecting a pointer.
// A fully enabled control can still lie outside an unfolding or newly resized card.
static bool settleRegionControl(QQuickWindow *window,QQuickItem *card,QQuickItem *control,ReaderController *reader) {
    QElapsedTimer timer;timer.start();QRectF previous;int stable=0;
    while(timer.elapsed()<5000) {
        QTest::qWait(40);const auto rect=control->mapRectToScene(QRectF(0,0,control->width(),control->height()));
        auto *viewport=card->parentItem();
        const bool inside=viewport && control->isVisible() && control->isEnabled()
            && card->contains(control->mapToItem(card,QPointF(0,0))) && card->contains(control->mapToItem(card,QPointF(control->width(),control->height())))
            && viewport->contains(control->mapToItem(viewport,QPointF(0,0))) && viewport->contains(control->mapToItem(viewport,QPointF(control->width(),control->height())));
        if(inside && window->isVisible() && !card->property("motionActive").toBool() && !reader->aiRegionPaper().value("loading").toBool()
                && qAbs(rect.x()-previous.x())<.01 && qAbs(rect.y()-previous.y())<.01 && rect.size()==previous.size())++stable;else stable=0;
        if(stable>=3)return true;previous=rect;
    }
    return false;
}

static bool settleRasterWork(ReaderController *reader) {
    QElapsedTimer elapsed;elapsed.start();int idleMs=0;
    while(elapsed.elapsed()<5000) {
        QTest::qWait(20);const auto jobs=RasterJobs::statistics();
        if(reader->pendingRasters()==0 && jobs.value("queued").toInt()==0 && jobs.value("running").toInt()==0)idleMs+=20;else idleMs=0;
        // Span both the surface debounce and delayed budget retry. Work planned before
        // motion is allowed to finish; it must not be counted as a new geometry demand.
        if(idleMs>=240)return true;
    }
    return false;
}

class ReaderChecks : public QObject {
    Q_OBJECT
public:
    QString root;
    QString graphicsBackend;
private slots:
    void initTestCase() {
        QCOMPARE(lyra_reader_desktop_abi_version(),LYRA_READER_DESKTOP_ABI_VERSION);
        qInfo() << "Qt test platform:" << QGuiApplication::platformName() << "requested graphics:" << graphicsBackend;
        if (qEnvironmentVariableIsSet("LYRA_READER_REQUIRE_NATIVE_QT")) {
            QVERIFY(QGuiApplication::platformName() == "wayland" || QGuiApplication::platformName() == "xcb");
        }
        registerReaderTypes();
    }
    void objectDragKeepsTheColourBehindTransparentPixels() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("alpha-drag.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->setProperty("paperAppearance","original");view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(!reader->loading() && reader->pageCount()==1 && !reader->pendingCommands());QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));const auto model=reader->data().value("content_objects").toMap();QVariantMap title;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());const auto b=title.value("bounds").toMap();const QRectF bounds(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble());auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");auto *pointer=visualItem(window->contentItem(),"contentPointer0");QVERIFY(drag && pointer);const auto colour=[&]{const auto image=window->grabWindow();if(image.isNull())return QColor();const auto p=pointer->mapToScene(QPointF(371,261)*window->property("zoom").toDouble());return image.pixelColor(qRound(p.x()*image.width()/window->width()),qRound(p.y()*image.height()/window->height()));};QTRY_VERIFY(colour().red()>100 && colour().green()<150);const auto original=colour();drag->prepare(0,title.value("id").toString(),model.value("revision").toString(),bounds);const auto region=bounds.adjusted(-2,-2,2,2);drag->setOffset(QPointF(370-region.x(),260-region.y()));QTRY_COMPARE_WITH_TIMEOUT(drag->status(),1,15000);QTest::qWait(100);const auto painted=colour();qInfo()<<"Transparent drag sample"<<original<<painted;QVERIFY2(qAbs(painted.red()-original.red())<6 && qAbs(painted.green()-original.green())<6 && qAbs(painted.blue()-original.blue())<6,"Transparent margins must preserve the coloured page below the dragged object");drag->cancel();QVERIFY(!reader->hasUnsavedChanges());
    }
    void copiedSelectionsExcludeMarginCountersWithoutChangingRawText_data() {
        QTest::addColumn<QString>("fixture");QTest::newRow("counters")<<QString("two-column-line-numbers.pdf");
        QTest::newRow("discretionary")<<QString("selection-discretionary-hyphens.pdf");
    }
    void copiedSelectionsExcludeMarginCountersWithoutChangingRawText() {
        QFETCH(QString,fixture);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("selection.pdf");
        QVERIFY(QFile::copy(root+"/tests/fixtures/"+fixture,path));QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto before=source.readAll();source.close();
        RecordingClipboardWorkspace workspace;QQmlApplicationEngine engine;
        engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.rootContext()->setContextProperty("workspace",&workspace);
        engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));
        reader->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(reader->textPages().contains("0"));
        const auto page=reader->textPages().value("0").toMap();const auto chars=page.value("chars").toList();QVERIFY(!chars.isEmpty());QCOMPARE(page.value("selection_excluded_indices").toList().size(),60);
        QVERIFY(page.value("text").toString().contains("001"));QVERIFY(page.value("text").toString().contains("020"));
        const int last=int(chars.size())-1;
        const auto cached=reader->selectionText(0,last,0);QVERIFY(cached.value("ready").toBool());QVERIFY(!cached.contains("error"));
        const QString raw=cached.value("text").toString();QVERIFY(!raw.contains("001") && !raw.contains("020"));if(!fixture.startsWith("selection-discretionary"))QVERIFY(raw.contains("42") && raw.contains("[12]"));
        auto selectAll=[&]{return window->setProperty("selection",QVariantMap{{"page",0},{"start",last},{"end",0}});};
        QVERIFY(selectAll());QVariant selected;QVERIFY(QMetaObject::invokeMethod(window,"selectedText",Q_RETURN_ARG(QVariant,selected)));QCOMPARE(selected.toString(),raw);
        QVERIFY(QMetaObject::invokeMethod(window,"copySelection"));QCOMPARE(workspace.copies,1);
        const auto copied=workspace.copied;QVERIFY(!copied.contains(QChar(2)) && !copied.contains(QChar(0xad)));
        if(fixture.startsWith("selection-discretionary")){QVERIFY(raw.contains(QChar(2)));QVERIFY(copied.contains("conditioning") && copied.contains("ordinary"));QVERIFY(copied.contains("fine-grained") && copied.contains("Time-Aware"));}
        QVERIFY(QMetaObject::invokeMethod(window,"selectedText",Q_RETURN_ARG(QVariant,selected)));QCOMPARE(selected.toString(),raw);QCOMPARE(reader->textPages().value("0").toMap().value("text"),page.value("text"));
        // Missing text and a counter-only empty range must not erase a prior copy.
        QVERIFY(window->setProperty("selection",QVariantMap{{"page",999},{"start",0},{"end",1}}));
        QVERIFY(QMetaObject::invokeMethod(window,"copySelection"));QCOMPARE(workspace.copies,1);QCOMPARE(workspace.copied,copied);
        const int excluded=page.value("selection_excluded_indices").toList().first().toInt();
        QVERIFY(window->setProperty("selection",QVariantMap{{"page",0},{"start",excluded},{"end",excluded}}));
        QVERIFY(QMetaObject::invokeMethod(window,"copySelection"));QCOMPARE(workspace.copies,1);QCOMPARE(workspace.copied,copied);QVERIFY(selectAll());
        // A frozen reader has no editable-document handle. Its loaded text fallback
        // must use the same original-index exclusions as the prepared shared cache.
        const auto frozen=reader->renderSource();QVERIFY(frozen);workspace.newTab();auto *snapshot=workspace.activeReader();QVERIFY(snapshot!=reader);
        QVERIFY(snapshot->openSnapshot(frozen,QUrl::fromLocalFile(path),"Frozen selection"));QTRY_COMPARE_WITH_TIMEOUT(snapshot->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(snapshot->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));
        snapshot->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(snapshot->pendingCommands(),0,10000);QTRY_VERIFY(snapshot->textPages().contains("0"));QVERIFY(!snapshot->selectionText(0,0,last).value("ready").toBool());
        QVERIFY(selectAll());QVERIFY(QMetaObject::invokeMethod(window,"selectedText",Q_RETURN_ARG(QVariant,selected)));QCOMPARE(selected.toString(),raw);
        QVERIFY(QMetaObject::invokeMethod(window,"copySelection"));QCOMPARE(workspace.copies,2);QCOMPARE(workspace.copied,copied);
        workspace.selectTab(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));QVERIFY(selectAll());
        QVERIFY(QMetaObject::invokeMethod(window,"markSelection",Q_ARG(QVariant,"highlight")));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto marks=reader->data().value("marks").toMap().value("annotations").toList();QCOMPARE(marks.size(),1);
        const auto quads=marks.first().toMap().value("quads").toList();QVERIFY(!quads.isEmpty());
        for(const auto &q:quads){const auto box=q.toMap();QVERIFY(box.value("x_pt").toDouble()>=59);QVERIFY(box.value("x_pt").toDouble()+box.value("width_pt").toDouble()<565);}
        QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedChanges(),10000);QVERIFY(settleReaderViewport(window));
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);
        reopened.submit("annotations");reopened.requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);const auto fileMarks=reopened.data().value("annotations").toList();QCOMPARE(fileMarks.size(),1);
        const auto savedQuads=fileMarks.first().toMap().value("quads").toList();QVERIFY(!savedQuads.isEmpty());
        for(const auto &q:savedQuads){const auto box=q.toMap();QVERIFY(box.value("x_pt").toDouble()>=59);QVERIFY(box.value("x_pt").toDouble()+box.value("width_pt").toDouble()<565);}
        QVERIFY(reopened.textPages().value("0").toMap().value("text").toString().contains("001"));
        QFile original(root+"/tests/fixtures/"+fixture);QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),before);
    }
    void selectionFallbackKeepsUnicodeScalarsAndOriginalIndices() {
        QFile script(":/qml/ReaderLogic.js");QVERIFY(script.open(QIODevice::ReadOnly));auto code=script.readAll();code=code.mid(code.indexOf('\n')+1);QJSEngine engine;QVERIFY(!engine.evaluate(QString::fromUtf8(code)).isError());
        const auto chars=engine.evaluate("[{unicode:0,x_pt:60,y_pt:20,width_pt:1,height_pt:10},{unicode:49,x_pt:10,y_pt:20,width_pt:4,height_pt:10},{unicode:65,x_pt:64,y_pt:20,width_pt:4,height_pt:10},{unicode:55296},{unicode:128512},{unicode:1114112}]");
        auto selected=engine.globalObject().property("selectedText").call({chars,0,5,engine.evaluate("[1]")});QVERIFY(!selected.isError());
        QString expected(QChar(0));expected+="A";expected+=QString::fromUtf8("😀");QCOMPARE(selected.toString(),expected);
        auto hit=engine.globalObject().property("nearestCharacter").call({chars,10,20,engine.evaluate("[1]")});QVERIFY(!hit.isError());QVERIFY(hit.toInt()!=1);
        const auto quads=engine.globalObject().property("quads").call({chars,0,5,engine.evaluate("[1]")}).toVariant().toList();QVERIFY(!quads.isEmpty());for(const auto &q:quads)QVERIFY(q.toMap().value("x").toDouble()>=60);
    }
    void snapshotRastersIncludePdfAnnotationsWithoutATextureOverlay() {
        ReaderController original;original.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/annotated.pdf"));QTRY_COMPARE_WITH_TIMEOUT(original.pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(original.pendingCommands(),0,10000);QString error;const auto source=NativeRasterSource::prepare(original.documentHandle(),false,&error);QVERIFY2(source,qPrintable(error));ReaderController frozen;QVERIFY(frozen.openSnapshot(source,original.fileUrl(),"Synthetic snapshot"));QTRY_COMPARE_WITH_TIMEOUT(frozen.pageCount(),2,10000);frozen.requestPage(0,1);QTRY_VERIFY_WITH_TIMEOUT(!frozen.cachedPage(0,1).isNull(),10000);const auto page=frozen.pages().first().toMap();const QRectF region(0,0,page.value("width").toDouble(),page.value("height").toDouble());const auto marked=source->crop(0,region,1,true,false,&error),bare=source->crop(0,region,1,false,false,&error);QVERIFY2(error.isEmpty(),qPrintable(error));QCOMPARE(frozen.cachedPage(0,1),marked);QVERIFY(marked!=bare);
    }
    void pdfPreviewFreezesTheWorkingRevisionAndKeepsTilesAndTextAfterSave() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/snapshot.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/numeric-citations.pdf",path));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("page_stage",{{"operation",QVariantMap{{"InsertBlank",QVariantMap{{"index",0}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->pageCount(),3);reader->submit("citations",{{"page",1}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto citations=reader->data().value("citations").toList();QVERIFY(!citations.isEmpty());const auto hit=citations.first().toMap();auto *preview=workspace.preview();preview->openAt(reader,1,hit.value("x_pt").toDouble()+hit.value("width_pt").toDouble()/2,hit.value("y_pt").toDouble()+hit.value("height_pt").toDouble()/2,320,200,1);QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);const auto target=preview->model();preview->openWindow();
        QPointer<QQuickWindow> auxiliary=window->findChild<QQuickWindow *>("pdfPreviewWindow");QVERIFY(auxiliary);QTRY_VERIFY(auxiliary->isVisible());QCOMPARE(auxiliary->transientParent(),window);QCOMPARE(auxiliary->type(),Qt::Dialog);QVERIFY(auxiliary->minimumWidth()<auxiliary->maximumWidth());QVERIFY(!preview->visible());
        auto *frozen=qobject_cast<ReaderController *>(auxiliary->property("previewReader").value<QObject *>());QVERIFY(frozen);QVERIFY(frozen->snapshotReadOnly());QVERIFY(!frozen->documentHandle());QTRY_COMPARE_WITH_TIMEOUT(frozen->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(frozen->pendingCommands(),0,10000);QTRY_COMPARE(auxiliary->property("page").toInt(),target.value("page").toInt());
        auto *pdf=visualItem(auxiliary->contentItem(),"pdfPreviewPage");auto *view=visualItem(auxiliary->contentItem(),"pdfPreviewViewport");QVERIFY(pdf && view);QTRY_VERIFY_WITH_TIMEOUT(pdf->property("texturesReady").toBool(),10000);QTRY_VERIFY(qAbs(view->property("contentY").toDouble()-qBound(0.0,pdf->y()+target.value("region").toMap().value("y_pt").toDouble()*auxiliary->property("zoom").toDouble()-16,qMax(0.0,view->property("contentHeight").toDouble()-view->height())))<2);
        const auto evidence=qEnvironmentVariable("LYRA_READER_PDF_PREVIEW_SNAPSHOT");if(!evidence.isEmpty()){QTest::qWait(100);QVERIFY(auxiliary->grabWindow().save(evidence));}
        reader->submit("page_stage",{{"operation",QVariantMap{{"InsertBlank",QVariantMap{{"index",0}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->pageCount(),4);QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QCOMPARE(frozen->pageCount(),3);
        frozen->requestText(target.value("page").toInt());QTRY_COMPARE_WITH_TIMEOUT(frozen->pendingCommands(),0,10000);const auto snapshotText=frozen->textPages().value(QString::number(target.value("page").toInt())).toMap().value("text").toString();QVERIFY(!snapshotText.trimmed().isEmpty());
        QFile saved(path);QVERIFY(saved.open(QIODevice::ReadOnly));const auto bytes=saved.readAll();saved.close();frozen->submit("document_discard");QTRY_VERIFY(!frozen->error().isEmpty());QVERIFY(frozen->error().contains("read-only"));QVERIFY(saved.open(QIODevice::ReadOnly));QCOMPARE(saved.readAll(),bytes);saved.close();frozen->dismissError();
        QVERIFY(QMetaObject::invokeMethod(auxiliary,"changeZoom",Q_ARG(QVariant,4.0),Q_ARG(QVariant,200),Q_ARG(QVariant,200)));QTRY_VERIFY_WITH_TIMEOUT(pdf->property("refined").toBool() && pdf->property("loadedTileCount").toInt()>0 && pdf->property("texturesReady").toBool(),15000);QVERIFY(QMetaObject::invokeMethod(auxiliary,"readText"));QTRY_VERIFY(!visualItem(auxiliary->contentItem(),"pdfPreviewText")->property("text").toString().isEmpty());
        // QQuickTextEdit exposes CRLF paragraphs as LF; the controller and explicit page copy
        // retain the exact engine string rather than changing the frozen text in place.
        QCOMPARE(visualItem(auxiliary->contentItem(),"pdfPreviewText")->property("text").toString(),QString(snapshotText).replace("\r\n","\n"));QCOMPARE(frozen->textPages().value(QString::number(target.value("page").toInt())).toMap().value("text").toString(),snapshotText);
        if(QGuiApplication::platformName()=="offscreen"){QVERIFY(QMetaObject::invokeMethod(auxiliary,"copyPageText"));QCOMPARE(QGuiApplication::clipboard()->text(),snapshotText);}

        workspace.newTab();QPointer<ReaderController> closedTab=reader;workspace.closeTab(0);QTRY_VERIFY_WITH_TIMEOUT(closedTab.isNull(),10000);QVERIFY(auxiliary->isVisible());QCOMPARE(frozen->pageCount(),3);QVERIFY(QMetaObject::invokeMethod(auxiliary,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTRY_COMPARE(auxiliary->property("page").toInt(),0);QTRY_VERIFY_WITH_TIMEOUT(frozen->textPages().contains("0"),10000);std::weak_ptr<NativeRasterSource> lifetime=frozen->renderSource();window->hide();QTRY_VERIFY_WITH_TIMEOUT(auxiliary.isNull(),10000);QTRY_VERIFY_WITH_TIMEOUT(lifetime.expired(),10000);
    }
    void independentPdfPreviewsKeepOwnersDarkNarrowLayoutAndClosePendingReads() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/auxiliary-lifetime.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/numeric-citations.pdf",path));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("citations",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto hits=reader->data().value("citations").toList();QVERIFY(!hits.isEmpty());const auto hit=hits.first().toMap();auto *preview=workspace.preview();QList<QPointer<QQuickWindow>> children;
        for(int i=0;i<2;++i){preview->openAt(reader,0,hit.value("x_pt").toDouble()+hit.value("width_pt").toDouble()/2,hit.value("y_pt").toDouble()+hit.value("height_pt").toDouble()/2,320,200,1);QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);preview->openWindow();QQuickWindow *created=nullptr;for(auto *candidate:window->findChildren<QQuickWindow *>("pdfPreviewWindow"))if(!children.contains(candidate))created=candidate;QVERIFY(created);children.append(created);QTRY_VERIFY(created->isVisible());QCOMPARE(created->transientParent(),window);auto *snapshot=qobject_cast<ReaderController *>(created->property("previewReader").value<QObject *>());QVERIFY(snapshot);QTRY_COMPARE_WITH_TIMEOUT(snapshot->pageCount(),2,10000);}
        window->setProperty("appearance","dark");children[0]->resize(360,400);QTRY_COMPARE(children[0]->color(),window->color());auto *more=visualItem(children[0]->contentItem(),"previewMoreButton");QVERIFY(more);QTRY_VERIFY(more->isVisible());QTRY_VERIFY_WITH_TIMEOUT(more->mapRectToScene(QRectF(0,0,more->width(),more->height())).left()>=0 && more->mapRectToScene(QRectF(0,0,more->width(),more->height())).right()<=children[0]->width(),10000);auto *pdf=visualItem(children[0]->contentItem(),"pdfPreviewPage");QVERIFY(pdf);QTRY_VERIFY_WITH_TIMEOUT(pdf->property("texturesReady").toBool(),10000);
        const auto evidence=qEnvironmentVariable("LYRA_READER_PDF_PREVIEW_DARK_SNAPSHOT");if(!evidence.isEmpty()){QTest::qWait(100);QVERIFY(children[0]->grabWindow().save(evidence));}
        QVERIFY(children[0]->close());QTRY_VERIFY_WITH_TIMEOUT(children[0].isNull(),10000);QVERIFY(children[1]->isVisible());
        auto *snapshot=qobject_cast<ReaderController *>(children[1]->property("previewReader").value<QObject *>());QVERIFY(snapshot);std::weak_ptr<NativeRasterSource> lifetime=snapshot->renderSource();snapshot->requestText(0);QVERIFY(snapshot->pendingCommands()>0);window->hide();QTRY_VERIFY_WITH_TIMEOUT(children[1].isNull(),10000);
        // The main reader intentionally owns the same immutable source. Closing its
        // children releases their leases; reopening the last owner must release the source.
        QCOMPARE(lifetime.lock(),reader->renderSource());reader->openFile(reader->fileUrl());
        QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && reader->pageCount()==2 && reader->pendingCommands()==0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(lifetime.expired(),10000);
    }
    void nativeTabsReorderAfterHalfTheirWidthAndKeepReaderOwnership() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        QList<ReaderController *> readers;for(const auto &name:{"first","second","third"}){const auto path=scratch.path()+"/"+name+".pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));workspace.openFile(QUrl::fromLocalFile(path));readers.append(workspace.activeReader());QTRY_COMPARE_WITH_TIMEOUT(readers.last()->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(readers.last()->pendingCommands(),0,10000);}
        QTRY_VERIFY(!window->property("positionRestoring").toBool());QTest::qWait(120);auto order=[&]{QList<ReaderController *> result;for(const auto &tab:workspace.tabs())result.append(tab.toMap().value("reader").value<ReaderController *>());return result;};
        auto drag=[&](int index,double grab,double distance,bool escape){auto *surface=visualItem(window->contentItem(),"tabSurface"+QString::number(index));if(!surface)return false;const auto start=surface->mapToScene(QPointF(grab,15)).toPoint();QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,start);QTest::mouseMove(window,start+QPoint(qRound(distance),0),20);if(distance>surface->parentItem()->width()/2 && qEnvironmentVariableIsSet("LYRA_READER_TAB_SNAPSHOT")){QTest::qWait(40);if(!window->grabWindow().save(qEnvironmentVariable("LYRA_READER_TAB_SNAPSHOT")))return false;}if(escape)QTest::keyClick(window,Qt::Key_Escape);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,start+QPoint(qRound(distance),0));return true;};
        auto *first=visualItem(window->contentItem(),"readerTab0");QVERIFY(first);const auto half=first->width()/2;QVERIFY(drag(0,5,half-2,false));QCOMPARE(order(),readers);QCOMPARE(workspace.activeReader(),readers[2]);
        QVERIFY(drag(0,5,half+2,false));QTRY_COMPARE(order(),QList<ReaderController *>({readers[1],readers[0],readers[2]}));QCOMPARE(workspace.activeReader(),readers[0]);QTRY_COMPARE_WITH_TIMEOUT(readers[0]->pendingCommands(),0,10000);QTRY_VERIFY(!window->property("positionRestoring").toBool());QTest::qWait(160);
        auto *surface=visualItem(window->contentItem(),"tabSurface1");QVERIFY(surface);QVERIFY(drag(1,surface->width()-5,-half-2,false));QTRY_COMPARE(order(),readers);QCOMPARE(workspace.activeReader(),readers[0]);
        QVERIFY(drag(2,5,-half-2,true));QCOMPARE(visualItem(window->contentItem(),"tabSurface2")->property("cursorShape").toInt(),int(Qt::ArrowCursor));QCOMPARE(order(),readers);QCOMPARE(workspace.activeReader(),readers[0]);
        auto *keyboard=visualItem(window->contentItem(),"tabSurface0");QVERIFY(keyboard);keyboard->forceActiveFocus();QTest::keyClick(window,Qt::Key_Right,Qt::AltModifier|Qt::ShiftModifier);QTRY_COMPARE(order(),QList<ReaderController *>({readers[1],readers[0],readers[2]}));QCOMPARE(workspace.activeReader(),readers[0]);
        readers[0]->submit("bookmark_create",{{"page",0},{"title","Retained while reordered"},{"yPt",24}});QTRY_COMPARE_WITH_TIMEOUT(readers[0]->pendingCommands(),0,10000);QVERIFY(readers[0]->hasUnsavedChanges());workspace.saveViewState(readers[0],{{"page",0},{"zoom",1.5},{"y",71}});QVERIFY(workspace.moveTab(readers[0],nullptr));QCOMPARE(workspace.activeReader(),readers[0]);QVERIFY(readers[0]->hasUnsavedChanges());QCOMPARE(workspace.viewState(readers[0]).value("y").toInt(),71);QCOMPARE(readers[0]->data().value("marks").toMap().value("bookmarks").toList().first().toMap().value("title").toString(),QString("Retained while reordered"));QVERIFY(!workspace.moveTab(readers[0],nullptr));QVERIFY(!workspace.moveTab(nullptr,readers[0]));
    }
    void contentDraftAppliesBeforeAnInactiveTabIsReordered() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        QList<ReaderController *> readers;for(const auto &name:{"first","second"}){const auto path=scratch.path()+"/"+name+".pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));workspace.openFile(QUrl::fromLocalFile(path));readers.append(workspace.activeReader());QTRY_COMPARE_WITH_TIMEOUT(readers.last()->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(readers.last()->pendingCommands(),0,10000);}workspace.selectTab(0);
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(readers[0]->pendingCommands(),0,10000);QVariantMap item;for(const auto &value:readers[0]->data().value("content_objects").toMap().value("items").toList())if(value.toMap().value("can_edit_text").toBool()){item=value.toMap();break;}QVERIFY(!item.isEmpty());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);
        QVERIFY(QMetaObject::invokeMethod(editor,"editText",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(editor,"changeText",Q_ARG(QVariant,"Reorder draft")));const QVariant font=QVariantMap{{"font","Helvetica"},{"size",12}};QVERIFY(QMetaObject::invokeMethod(editor,"changeStyle",Q_ARG(QVariant,font)));QVERIFY(readers[0]->hasEditDrafts());
        const auto source=QVariant::fromValue(readers[1]),before=QVariant::fromValue(readers[0]);QVERIFY(QMetaObject::invokeMethod(window,"reorderReaderTab",Q_ARG(QVariant,source),Q_ARG(QVariant,before),Q_ARG(QVariant,false)));QCOMPARE(workspace.activeReader(),readers[0]);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader(),readers[1],15000);QCOMPARE(workspace.tabs().first().toMap().value("reader").value<ReaderController *>(),readers[1]);QTRY_COMPARE_WITH_TIMEOUT(readers[0]->pendingCommands(),0,10000);QVERIFY(!readers[0]->hasEditDrafts());QVERIFY(readers[0]->hasUnsavedChanges());readers[0]->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(readers[0]->pendingCommands(),0,10000);QVERIFY(readers[0]->textPages().value("0").toMap().value("text").toString().contains("Reorder draft"));
    }
    void qmlPreferencesPersistAsValuesAcrossAProcessRestart() {
        WorkspaceController workspace;
        if(qEnvironmentVariableIsSet("LYRA_READER_CHECK_PREF_CHILD")) {
            const auto value=workspace.preference("syntheticPreference").toMap();QCOMPARE(value.value("width").toInt(),580);QCOMPARE(value.value("height").toInt(),620);QCOMPARE(value.value("nested").toMap().value("values").toList(),QVariantList({1,2}));return;
        }
        QJSEngine js;const auto value=js.evaluate("({width:580,height:620,nested:{values:[1,2]}})");QVERIFY(!value.isError());workspace.setPreference("syntheticPreference",QVariant::fromValue(value));QSettings settings;settings.sync();QCOMPARE(settings.status(),QSettings::NoError);
        auto directory=QFileInfo(settings.fileName()).absoluteDir();QVERIFY(directory.cdUp());auto env=QProcessEnvironment::systemEnvironment();env.insert("LYRA_READER_CHECK_PREF_CHILD","1");env.insert("LYRA_READER_CHECK_SETTINGS_ROOT",directory.absolutePath());QProcess child;child.setProcessEnvironment(env);child.start(QCoreApplication::applicationFilePath(),{root,"qmlPreferencesPersistAsValuesAcrossAProcessRestart"});QVERIFY(child.waitForFinished(10000));QCOMPARE(child.exitStatus(),QProcess::NormalExit);QVERIFY2(child.exitCode()==0,child.readAllStandardOutput().constData());
    }
    void auxiliaryGeometryClampsBeforeConvertingSavedValues() {
        QCOMPARE(AuxiliaryWindowPolicy::boundedSize({560,650},{0,0,1920,1080}),QSize(560,650));
        QCOMPARE(AuxiliaryWindowPolicy::boundedSize({3000,2000},{-1200,0,1200,800}),QSize(1168,768));
        QCOMPARE(AuxiliaryWindowPolicy::boundedSize({1e300,1e300},{0,0,1200,800}),QSize(560,650));
        QCOMPARE(AuxiliaryWindowPolicy::boundedSize({qQNaN(),-1},{0,0,800,600}),QSize(560,568));
        QCOMPARE(AuxiliaryWindowPolicy::boundedSize({1,1},{0,0,100,90}),QSize(68,58));
        QVERIFY(AuxiliaryWindowPolicy::boundedSize({560,650},{}).isEmpty());
    }
    void preferencesKeysOpenSettingsWithoutADocumentAndYieldToItsWindow() {
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        auto *settings=window->findChild<QQuickWindow *>("settingsWindow");QVERIFY(settings);QVERIFY(!settings->isVisible());
        const auto preferences=QKeySequence::fromString(QStringLiteral("Ctrl+,"),QKeySequence::PortableText);QVERIFY(!preferences.isEmpty());
        qInfo()<<"Platform Preferences key"<<preferences.toString(QKeySequence::PortableText);
        window->requestActivate();QVERIFY(QTest::qWaitForWindowActive(window,5000));QTRY_VERIFY(window->property("readerKeyboardEnabled").toBool());
        QTest::keySequence(window,preferences);QTRY_VERIFY(settings->isVisible());
        settings->requestActivate();QVERIFY(QTest::qWaitForWindowActive(settings,5000));QTRY_VERIFY(QGuiApplication::focusWindow()==settings);
        QCOMPARE(view.workspace.activeReader()->pageCount(),0);QCOMPARE(view.workspace.tabs().size(),1);
        auto *action=window->findChild<QObject *>("settingsAction"),*menu=window->findChild<QObject *>("settingsMenuItem");QVERIFY(action && menu);
        QCOMPARE(menu->property("action").value<QObject *>(),action);
        QTRY_VERIFY(!window->property("readerKeyboardEnabled").toBool());QVERIFY(action->property("shortcut").toString().isEmpty());
        QSignalSpy triggered(action,SIGNAL(triggered(QObject*)));QVERIFY(triggered.isValid());
        QTest::keySequence(settings,preferences);QTest::qWait(40);QVERIFY(triggered.isEmpty());QVERIFY(settings->isVisible());
        QTest::keyClick(settings,Qt::Key_Escape);QTRY_VERIFY(!settings->isVisible());QTRY_VERIFY(window->isActive());
        QTRY_VERIFY(window->property("readerKeyboardEnabled").toBool());
        QTest::keySequence(window,preferences);QTRY_VERIFY(settings->isVisible());QCOMPARE(triggered.size(),1);
        settings->requestActivate();QVERIFY(QTest::qWaitForWindowActive(settings,5000));QTRY_VERIFY(QGuiApplication::focusWindow()==settings);QTest::keyClick(settings,Qt::Key_Escape);QTRY_VERIFY(!settings->isVisible());
        QTRY_VERIFY(window->isActive());QTRY_VERIFY(window->property("readerKeyboardEnabled").toBool());QVERIFY(QMetaObject::invokeMethod(action,"trigger"));QTRY_VERIFY(settings->isVisible());
        QCOMPARE(triggered.size(),2);QVERIFY(settings->close());
        QCOMPARE(view.workspace.activeReader()->pageCount(),0);QVERIFY(!view.workspace.activeReader()->hasUnsavedChanges());
    }
    void settingsAreIndependentTransientWindowsWithSafeReopenAndOwnerLifetime() {
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        const auto oldMotion=window->property("reduceMotion");auto restoreMotion=qScopeGuard([&]{window->setProperty("reduceMotion",oldMotion);});
        auto *settings=window->findChild<QQuickWindow *>("settingsWindow");QVERIFY(settings);QVERIFY(!settings->isVisible());bool preparedAtFirstShow=false;
        connect(settings,&QWindow::visibleChanged,this,[&](bool shown){if(shown)preparedAtFirstShow=settings->transientParent()==window && settings->type()==Qt::Dialog && settings->modality()==Qt::NonModal;});
        workspace.setPreference("auxiliarySettingsGeometry",QVariantMap{{"width",1e300},{"height",-10},{"x",-1e300},{"y",1e300}});
        QVERIFY(QMetaObject::invokeMethod(window,"showSettings"));QTRY_VERIFY(settings->isVisible());QVERIFY(preparedAtFirstShow);QVERIFY(settings->minimumWidth()<settings->maximumWidth());QVERIFY(settings->minimumHeight()<settings->maximumHeight());
        const auto available=settings->screen()->availableGeometry();QVERIFY(settings->width()<=available.width());QVERIFY(settings->height()<=available.height());QVERIFY(!(settings->flags() & Qt::WindowStaysOnTopHint));
        if(qEnvironmentVariableIsSet("LYRA_READER_CHECK_AUX_OBSERVE"))QTest::qWait(1800);
        if(qEnvironmentVariableIsSet("LYRA_READER_CHECK_AUX_SNAPSHOT")){QTest::qWait(80);QVERIFY(settings->grabWindow().save(qEnvironmentVariable("LYRA_READER_CHECK_AUX_SNAPSHOT")));}
        auto *motion=settings->findChild<QObject *>("settingsReduceMotion");QVERIFY(motion);QCOMPARE(motion->property("checked").toBool(),oldMotion.toBool());motion->setProperty("checked",!oldMotion.toBool());
        auto *url=settings->findChild<QObject *>("settingsBaseUrl");auto *key=settings->findChild<QObject *>("settingsApiKey");QVERIFY(url && key);url->setProperty("text","http://127.0.0.1:1/cancelled");key->setProperty("text","synthetic-local-draft");QVERIFY(settings->close());QTRY_VERIFY(!settings->isVisible());QVERIFY(key->property("text").toString().isEmpty());QCOMPARE(window->property("reduceMotion"),oldMotion);
        QVERIFY(QMetaObject::invokeMethod(window,"showSettings"));QTRY_VERIFY(settings->isVisible());QVERIFY(url->property("text").toString()!="http://127.0.0.1:1/cancelled");
        const auto newSize=QSize(qMax(settings->minimumWidth(),settings->width()-40),qMax(settings->minimumHeight(),settings->height()-30));settings->resize(newSize);QTRY_COMPARE(settings->size(),newSize);QVERIFY(settings->close());
        QVERIFY(QMetaObject::invokeMethod(window,"showSettings"));QTRY_VERIFY(settings->isVisible());QCOMPARE(settings->size(),newSize);QCOMPARE(motion->property("checked").toBool(),oldMotion.toBool());motion->setProperty("checked",!oldMotion.toBool());url->setProperty("text","http://127.0.0.1:1/saved");QVERIFY(QMetaObject::invokeMethod(settings,"save"));QTRY_VERIFY(!settings->isVisible());QCOMPARE(workspace.preference("ai").toMap().value("baseUrl").toString(),QString("http://127.0.0.1:1/saved"));QCOMPARE(workspace.preference("reduceMotion").toBool(),!oldMotion.toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"showSettings"));QTRY_VERIFY(settings->isVisible());window->hide();QTRY_VERIFY(!settings->isVisible());
    }
    void displayCalibrationValidatesPhysicalMetrics() {
        const auto normal=DisplayCalibration::resolve(1920,508);
        QVERIFY(normal.fallbackReason.isEmpty());QVERIFY(std::abs(normal.factor-4.0/3)<1e-9);
        const auto retina=DisplayCalibration::resolve(960,508);
        QVERIFY(retina.fallbackReason.isEmpty());QVERIFY(std::abs(retina.factor-2.0/3)<1e-9);
        for (const auto &metrics : std::vector<std::pair<double,double>>{{0,508},{1920,0},{1920,24},{1920,3001},{100000,508},{1,508},{qQNaN(),508},{1920,qInf()}}) {
            const auto bad=DisplayCalibration::resolve(metrics.first,metrics.second);
            QCOMPARE(bad.factor,1.0);QVERIFY(!bad.fallbackReason.isEmpty());
        }
        DisplayCalibration calibration;QQuickWindow window;
        calibration.setWindow(&window);QVERIFY(window.screen());
        const auto expected=DisplayCalibration::resolve(window.screen()->geometry().width(),window.screen()->physicalSize().width());
        QCOMPARE(calibration.factor(),expected.factor);
        calibration.setWindow(nullptr);QCOMPARE(calibration.factor(),1.0);QVERIFY(!calibration.fallbackReason().isEmpty());
        auto *closing=new QQuickWindow;calibration.setWindow(closing);QSignalSpy changes(&calibration,&DisplayCalibration::calibrationChanged);
        delete closing;QCOMPARE(changes.size(),0);QVERIFY(!calibration.window());QCOMPARE(calibration.factor(),1.0);
    }
    void calibratedActualSizeAndFitPresetsPreservePageAndState() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/zoom.pdf";
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));
        WorkspaceController workspace;auto *reader=workspace.activeReader();QQmlApplicationEngine engine;
        engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",reader);engine.rootContext()->setContextProperty("workspace",&workspace);
        engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,0)));QTRY_COMPARE(window->property("currentPage").toInt(),6);
        QVERIFY(QMetaObject::invokeMethod(window,"actualSize"));const auto factor=window->property("calibrationFactor").toDouble();
        QVERIFY(std::abs(window->property("zoom").toDouble()-factor)<1e-9);QVERIFY(std::abs(window->property("zoomPercent").toDouble()-100)<1e-9);
        QVERIFY(QMetaObject::invokeMethod(window,"zoomBy",Q_ARG(QVariant,1.2)));QVERIFY(std::abs(window->property("zoomPercent").toDouble()-110)<1e-9);
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));QVERIFY(std::abs(workspace.viewState(reader).value("zoomPercent").toDouble()-110)<1e-9);
        // Centre-anchored zoom may legitimately put a preceding page under the
        // viewport's reading probe. Select the fit target explicitly.
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"fitPage"));QTRY_COMPARE(window->property("currentPage").toInt(),6);QCOMPARE(window->property("fitPreset").toString(),QStringLiteral("page"));
        const double fit=window->property("zoom").toDouble();auto *view=visualItem(window->contentItem(),"pageList");QVERIFY(view);
        const auto page=reader->pages().at(6).toMap();QVERIFY(page.value("height").toDouble()*fit<=view->height()-16+.01);
        QVERIFY(QMetaObject::invokeMethod(window,"fitPage"));QCOMPARE(window->property("zoom").toDouble(),fit);QCOMPARE(window->property("currentPage").toInt(),6);
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto saved=workspace.viewState(reader);QCOMPARE(saved.value("fitPreset").toString(),QStringLiteral("page"));
        const auto spacing=reader->fitPresentation();QVERIFY(!spacing.isEmpty());
        workspace.newTab();workspace.selectTab(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!window->property("positionRestoring").toBool());
        QCOMPARE(reader->fitPresentation(),spacing);
        auto *restored=visualItem(window->contentItem(),"pdfPage6");QVERIFY(restored);
        QTRY_VERIFY(std::abs(restored->mapToItem(view,QPointF(0,0)).y()-(view->height()-restored->height())/2)<1);
        QCOMPARE(window->property("fitPreset").toString(),QStringLiteral("page"));QCOMPARE(window->property("currentPage").toInt(),6);
        QVERIFY(QMetaObject::invokeMethod(window,"fitWidth"));QCOMPARE(window->property("fitPreset").toString(),QStringLiteral("width"));
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,QStringLiteral("Facing"))));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"fitWidth"));
        const auto placements=reader->pages();const double top=placements.at(6).toMap().value("top").toDouble();double left=1e9,right=-1e9;
        for(const auto &entry:placements){const auto p=entry.toMap();if(std::abs(p.value("top").toDouble()-top)<.01){left=std::min(left,p.value("left").toDouble());right=std::max(right,p.value("left").toDouble()+p.value("width").toDouble());}}
        QVERIFY((right-left)*window->property("zoom").toDouble()<=view->width()-64+.01);
    }
    void singlePageFitsOnlyAfterARealViewportHeightChange() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/single-page.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        window->resize(1100,640);view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTRY_VERIFY(!window->property("positionRestoring").toBool());
        auto *list=visualItem(window->contentItem(),"pageList");QVERIFY(list);
        QVERIFY(settleReaderViewport(window));
        // The tool row changes the real viewport even when a tiling compositor
        // owns the top-level height and declines application resize requests.
        QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"annotate")));QVERIFY(settleReaderViewport(window));
        const double calibration=window->property("calibrationFactor").toDouble();
        auto choose=[&](double percent){window->setProperty("fitting",false);return QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,percent/100*calibration),Q_ARG(QVariant,0),Q_ARG(QVariant,0));};
        QVERIFY(choose(25));window->resize(window->width()+40,window->height());QVERIFY(settleReaderViewport(window));
        QCOMPARE(window->property("zoomPercent").toDouble(),25.0);
        QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"annotate")));
        const auto pageHeight=reader->pages().first().toMap().value("height").toDouble();
        const auto pageWidth=reader->pages().first().toMap().value("width").toDouble();
        const auto fit=[&]{return std::clamp(std::floor(std::min((list->height()-16)/pageHeight,(list->width()-64)/pageWidth)/calibration*100),25.0,400.0);};
        QTRY_VERIFY(std::abs(window->property("zoomPercent").toDouble()-fit())<1e-7);
        QVERIFY(fit()>25);QCOMPARE(window->property("currentPage").toInt(),0);
        auto *page=visualItem(window->contentItem(),"pdfPage0");QVERIFY(page);
        QTRY_VERIFY(page->mapToItem(list,QPointF(0,0)).y()>=7.9);
        QTRY_VERIFY(std::abs(page->mapToItem(list,QPointF(0,0)).y()-(list->height()-page->height())/2)<1);
        const auto snapshot=qEnvironmentVariable("LYRA_READER_VIEWPORT_SNAPSHOT");
        if(!snapshot.isEmpty()){QTRY_VERIFY(page->property("texturesReady").toBool());QVERIFY(window->grabWindow().save(snapshot+"-single.png"));}
        QVERIFY(choose(25));QTest::qWait(120);
        QCOMPARE(window->property("zoomPercent").toDouble(),25.0);
        const auto height=list->height();window->setProperty("sidebarVisible",!window->property("sidebarVisible").toBool());QTest::qWait(120);
        QCOMPARE(list->height(),height);QCOMPARE(window->property("zoomPercent").toDouble(),25.0);
        QVERIFY(choose(300));QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"annotate")));QVERIFY(settleReaderViewport(window));
        QVERIFY(std::abs(window->property("zoomPercent").toDouble()-300)<1e-7);
    }
    void fittedPagesUseBalancedContentSpacingAndCanonicalPositions() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/multi-page.pdf";
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        window->resize(1100,640);view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));
        auto *list=visualItem(window->contentItem(),"pageList");QVERIFY(list);
        auto *canvas=visualItem(window->contentItem(),"documentCanvas");QVERIFY(canvas);
        for(const auto &layout:{QString("Continuous"),QString("Facing")}) {
            window->setProperty("pageGap",0);
            QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,layout)));
            QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
            QVERIFY(settleReaderViewport(window));
            const auto originalPages=reader->pages(),originalRows=reader->layoutRows();
            for(const int index:{0,4,8}) {
                QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,index),Q_ARG(QVariant,0)));
                QVERIFY(QMetaObject::invokeMethod(window,"fitPage"));QVERIFY(settleReaderViewport(window));
                auto *page=visualItem(window->contentItem(),"pdfPage"+QString::number(index));QVERIFY(page);
                const double expected=(list->height()-page->height())/2;
                QTRY_VERIFY2(std::abs(page->mapToItem(list,QPointF(0,0)).y()-expected)<1,qPrintable(QString("page %1 top %2 expected %3 origin %4 content %5").arg(index).arg(page->mapToItem(list,QPointF(0,0)).y()).arg(expected).arg(list->property("originY").toDouble()).arg(list->property("contentY").toDouble())));
                QCOMPARE(reader->pages(),originalPages);QCOMPARE(reader->layoutRows(),originalRows);
                QVERIFY(list->property("contentY").toDouble()>=list->property("originY").toDouble()-.1);
                QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
                const auto saved=view.workspace.viewState(reader);
                QVERIFY(saved.value("viewportAnchor").toMap().contains("y"));
                QVERIFY2(std::abs(saved.value("viewportAnchor").toMap().value("y").toDouble())<.01,qPrintable(QString("%1 page %2 anchor %3 y %4 inset %5 content %6").arg(layout).arg(index).arg(saved.value("viewportAnchor").toMap().value("page").toInt()).arg(saved.value("viewportAnchor").toMap().value("y").toDouble()).arg(reader->fitPresentation().value("inset").toDouble()).arg(list->property("contentY").toDouble())));
                const int anchorPage=saved.value("viewportAnchor").toMap().value("page").toInt();
                QCOMPARE(reader->pages().at(anchorPage).toMap().value("top"),reader->pages().at(index).toMap().value("top"));
                QVERIFY(!saved.contains("fitPresentation"));
                // Adjacent rows cannot intrude into the fitted row's blank space.
                for(const int adjacent:{index-2,index-1,index+1,index+2}) {
                    if(adjacent<0 || adjacent>=reader->pageCount())continue;
                    auto *other=visualItem(window->contentItem(),"pdfPage"+QString::number(adjacent));
                    if(!other)continue;
                    const auto y=other->mapToItem(list,QPointF(0,0)).y();
                    const auto row=reader->pages().at(adjacent).toMap().value("top");
                    if(row==reader->pages().at(index).toMap().value("top"))continue;
                    QVERIFY(y>=list->height()-.5 || y+other->height()<=.5);
                }
            }
            const double calibrated=window->property("calibrationFactor").toDouble();
            QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,.25*calibrated),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
            QVERIFY(reader->fitPresentation().isEmpty());
            QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"annotate")));QVERIFY(settleReaderViewport(window));
            QVERIFY(window->property("zoomPercent").toDouble()>25);QVERIFY(!reader->fitPresentation().isEmpty());
            const double fitted=window->property("zoomPercent").toDouble();
            window->setProperty("sidebarVisible",!window->property("sidebarVisible").toBool());QTest::qWait(80);
            QCOMPARE(window->property("zoomPercent").toDouble(),fitted);
            QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,3*calibrated),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
            QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"annotate")));QVERIFY(settleReaderViewport(window));
            QCOMPARE(window->property("zoomPercent").toDouble(),300.0);
        }
    }
    void toolbarMenusAnchorAndOwnTheirKeyboard_data() {
        QTest::addColumn<QString>("buttonName");QTest::addColumn<QString>("menuName");QTest::addColumn<QString>("theme");QTest::addColumn<int>("width");
        for(const auto &kind:{QString("more"),QString("view"),QString("zoom")})for(const auto &theme:{QString("light"),QString("dark")}) {
            const auto button=kind=="more"?QString("moreCommands"):kind=="view"?QString("viewMenuButton"):QString("zoomMenuButton");
            const auto menu=kind=="more"?QString("moreCommandsMenu"):kind=="view"?QString("viewSettingsMenu"):QString("zoomPresetMenu");
            QTest::newRow(qPrintable(kind+"-"+theme))<<button<<menu<<theme<<(theme=="dark"?700:1100);
        }
    }
    void toolbarMenusAnchorAndOwnTheirKeyboard() {
        QFETCH(QString,buttonName);QFETCH(QString,menuName);QFETCH(QString,theme);QFETCH(int,width);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("toolbar-menus.pdf");QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->resize(width,700);window->setProperty("appearance",theme);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==9 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"actualSize"));QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,2),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));
        auto *button=visualItem(window->contentItem(),buttonName);auto *menu=window->findChild<QObject *>(menuName);QVERIFY(button && menu);
        window->requestActivate();button->forceActiveFocus(Qt::TabFocusReason);QTRY_VERIFY(button->hasActiveFocus());
        QTest::keyClick(window,Qt::Key_Space);QTRY_VERIFY(menu->property("visible").toBool());QTest::qWait(40);
        auto *body=menu->property("contentItem").value<QQuickItem *>();QVERIFY(body);
        const auto actual=body->mapToGlobal(QPointF(-menu->property("leftPadding").toDouble(),-menu->property("topPadding").toDouble()));const auto expected=button->mapToGlobal(QPointF(0,button->height()));
        qInfo()<<"Toolbar popup anchor"<<buttonName<<actual<<expected<<"window"<<window->size();
        QVERIFY2(QLineF(actual,expected).length()<2,"The menu must open below its own toolbar button");
        QTRY_VERIFY(menu->property("activeFocus").toBool());
        const auto page=window->property("currentPage");QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);QTest::qWait(40);QCOMPARE(window->property("currentPage"),page);
        QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY(!menu->property("visible").toBool());QTRY_VERIFY(button->hasActiveFocus());
        QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);QTRY_COMPARE(window->property("currentPage").toInt(),8);
        if(buttonName=="moreCommands") {
            button->forceActiveFocus(Qt::TabFocusReason);QTest::keyClick(window,Qt::Key_Space);QTRY_VERIFY(menu->property("visible").toBool());
            bool selectedSettings=false;
            for(int step=0;step<menu->property("count").toInt()+2;++step) {
                const auto *item=body->property("currentItem").value<QQuickItem *>();
                qInfo()<<"Toolbar keyboard selection"<<menu->property("currentIndex")<<(item?item->property("text"):QVariant());
                if(item && item->property("text").toString()==QString::fromUtf8("Settings…")){selectedSettings=true;break;}
                QTest::keyClick(window,Qt::Key_Down);QTest::qWait(5);
            }
            QVERIFY2(selectedSettings,"Arrow navigation must reach the actual Settings command");QTest::keyClick(window,Qt::Key_Return);
            QQuickWindow *settings=nullptr;QTRY_VERIFY((settings=window->findChild<QQuickWindow *>("settingsWindow")) && settings->isVisible());
            QTRY_COMPARE(QGuiApplication::focusWindow(),settings);QTest::keyClick(settings,Qt::Key_Escape);QTRY_VERIFY(!settings->isVisible());QTRY_COMPARE(QGuiApplication::focusWindow(),window);
        }
        QVERIFY(!reader->hasUnsavedChanges());
    }
    void ordinaryDocumentEdgesUseSharedSpacingAndCanonicalAnchors_data() {
        QTest::addColumn<QString>("layout");QTest::addColumn<double>("percent");
        for(const auto &layout:{QString("Continuous"),QString("Facing")})
            for(double percent:{25.0,100.0,250.0})QTest::newRow(qPrintable(layout+QString::number(percent)))<<layout<<percent;
    }
    void ordinaryDocumentEdgesUseSharedSpacingAndCanonicalAnchors() {
        QFETCH(QString,layout);QFETCH(double,percent);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("edge-spacing.pdf");
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,layout)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));
        window->setProperty("fitting",false);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,percent/100*window->property("calibrationFactor").toDouble()),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(settleReaderViewport(window));
        auto *list=visualItem(window->contentItem(),"pageList"),*canvas=visualItem(window->contentItem(),"documentCanvas");QVERIFY(list && canvas);
        auto *first=visualItem(window->contentItem(),"pdfPage0");QVERIFY(first);
        QTRY_VERIFY2(std::abs(first->mapToItem(list,QPointF()).y()-8)<.2,"Ordinary zoom must retain the shared eight-point screen inset");
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
        const auto start=view.workspace.viewState(reader).value("viewportAnchor").toMap();
        QCOMPARE(start.value("page").toInt(),0);QVERIFY(std::abs(start.value("y").toDouble())<.01);
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,2),Q_ARG(QVariant,120.0)));
        QVERIFY(settleReaderViewport(window));QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
        const auto saved=view.workspace.viewState(reader).value("viewportAnchor").toMap();
        const double expected=reader->pages().at(2).toMap().value("top").toDouble()+120;
        const auto savedPage=saved.value("page").toInt();
        const double canonical=reader->pages().at(savedPage).toMap().value("top").toDouble()+saved.value("y").toDouble();
        qInfo()<<"Ordinary edge anchor"<<percent<<layout<<saved<<"canonical"<<canonical<<"expected"<<expected<<"scroll"<<list->property("contentY")<<"origin"<<list->property("originY")<<"zoom"<<window->property("zoom");
        // ListView pixel-aligns scroll at small zoom. Keep the existing one-device-pixel
        // anchor contract instead of requiring a fraction of a screen pixel in PDF space.
        QVERIFY(std::abs(canonical-expected)*window->property("zoom").toDouble()*window->effectiveDevicePixelRatio()<1);
        view.workspace.newTab();view.workspace.selectTab(0);QVERIFY(settleReaderViewport(window));
        QVariant anchor;QVERIFY(QMetaObject::invokeMethod(canvas,"viewportAnchor",Q_RETURN_ARG(QVariant,anchor),Q_ARG(QVariant,0)));
        const auto restored=anchor.value<QJSValue>().toVariant().toMap();QCOMPARE(restored.value("page"),saved.value("page"));
        const auto stableAnchor=[&](const QVariantMap &value){return std::abs(value.value("y").toDouble()-saved.value("y").toDouble())*window->property("zoom").toDouble()*window->effectiveDevicePixelRatio()<1;};
        qInfo()<<"Restored canonical edge anchor"<<saved<<restored;
        QVERIFY(stableAnchor(restored));
        for(int repeat=0;repeat<10;++repeat) {
            view.workspace.selectTab(1);view.workspace.selectTab(0);QVERIFY(settleReaderViewport(window));
            QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
            const auto current=view.workspace.viewState(reader).value("viewportAnchor").toMap();
            QCOMPARE(current.value("page"),saved.value("page"));QVERIFY2(stableAnchor(current),"Repeated tab restoration must not accumulate reading drift");
        }
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,8),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));
        list->setProperty("contentY",list->property("originY").toDouble()+std::max(0.0,list->property("contentHeight").toDouble()-list->height()));
        QTest::qWait(30);auto *last=visualItem(window->contentItem(),"pdfPage8");QVERIFY(last);
        const double trailing=list->height()-last->mapToItem(list,QPointF(0,last->height())).y();
        QVERIFY2(trailing>=7.8,qPrintable(QString("Trailing inset: %1").arg(trailing)));
        const auto directory=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");
        if(!directory.isEmpty() && layout=="Continuous" && percent==100)QVERIFY(window->grabWindow().save(directory+"/ordinary-edge-spacing.png"));
    }
    void nightNeutralEdgesMatchTheSharedCoverageGolden() {
        const std::array<int,6> levels{0,64,128,192,204,255};
        const std::array<QColor,6> expected{QColor(201,197,189),QColor(187,183,176),QColor(166,162,156),QColor(130,127,121),QColor(120,117,112),QColor(36,34,30)};
        QImage image(6,1,QImage::Format_ARGB32);
        for(int i=0;i<6;++i) {
            const auto source=QColor(levels[i],levels[i],levels[i],137);image.setPixelColor(i,0,source);
            const auto actual=PaperAppearance::displayColor(source,2);
            QVERIFY2(std::abs(actual.red()-expected[i].red())<=1 && std::abs(actual.green()-expected[i].green())<=1 && std::abs(actual.blue()-expected[i].blue())<=1,qPrintable(actual.name()+" expected "+expected[i].name()));
            QCOMPARE(actual.alpha(),137);
        }
        const auto converted=PaperAppearance::displayImage(image,2);
        for(int i=0;i<6;++i){const auto actual=converted.pixelColor(i,0);QVERIFY(std::abs(actual.red()-expected[i].red())<=1);QVERIFY(std::abs(actual.green()-expected[i].green())<=1);QVERIFY(std::abs(actual.blue()-expected[i].blue())<=1);QCOMPARE(actual.alpha(),137);}
        QCOMPARE(image.pixelColor(2,0),QColor(128,128,128,137));
    }
    void scientificCpuFastPathsMatchGrayAlphaAndNearNeutralColours_data() {
        QTest::addColumn<int>("format");QTest::newRow("straight")<<int(QImage::Format_ARGB32);QTest::newRow("premultiplied")<<int(QImage::Format_RGBA8888_Premultiplied);
    }
    void scientificCpuFastPathsMatchGrayAlphaAndNearNeutralColours() {
        QFETCH(int,format);QImage source(256,768,QImage::Format_ARGB32);
        for(int y=0;y<768;++y)for(int x=0;x<256;++x) {
            const auto colour=y<256 ? QColor(x,x,x,y) : y<512 ? QColor(x,qBound(0,x+(y%9)-4,255),qBound(0,x+(y%13)-6,255),(x+y*19)%256) : QColor(x,(x+y)%256,(x*13+y*17)%256,y%256);
            source.setPixelColor(x,y,colour);
        }
        const auto input=source.convertToFormat(QImage::Format(format));const auto original=QCryptographicHash::hash(QByteArray::fromRawData(reinterpret_cast<const char *>(input.constBits()),input.sizeInBytes()),QCryptographicHash::Sha256);
        const auto normalized=input.convertToFormat(QImage::Format_ARGB32),output=PaperAppearance::displayImage(input,3);QCOMPARE(output.size(),input.size());
        for(int y=0;y<input.height();++y)for(int x=0;x<input.width();++x) {
            const auto expected=PaperAppearance::displayColor(normalized.pixelColor(x,y),3).rgba();
            QVERIFY2(output.pixel(x,y)==expected,qPrintable(QString("CPU colour mismatch at %1,%2: %3 expected %4").arg(x).arg(y).arg(output.pixel(x,y),8,16).arg(expected,8,16)));
        }
        QCOMPARE(QCryptographicHash::hash(QByteArray::fromRawData(reinterpret_cast<const char *>(input.constBits()),input.sizeInBytes()),QCryptographicHash::Sha256),original);
    }
    void scientificCropColoursFollowThemeWithoutAnotherRaster() {
        QImage source(88,8,QImage::Format_ARGB32);
        const std::array<QColor,11> colours{QColor(0,0,0),QColor(64,64,64),QColor(128,128,128),QColor(192,192,192),QColor(255,255,255),QColor(255,0,0),QColor(0,0,16),QColor(16,0,0),QColor(0,0,0,128),QColor(255,0,0,128),QColor(128,64,0,64)};
        for(int i=0;i<11;++i)for(int y=0;y<8;++y)for(int x=0;x<8;++x)source.setPixelColor(i*8+x,y,colours[i]);
        QByteArray bytes;QBuffer buffer(&bytes);QVERIFY(buffer.open(QIODevice::WriteOnly));QVERIFY(source.save(&buffer,"PNG"));
        const QUrl url("data:image/png;base64,"+QString::fromLatin1(bytes.toBase64()));
        QQuickWindow window;window.resize(720,240);window.setColor(Qt::white);
        auto *crop=new CropItem(window.contentItem());crop->setSize(window.size());
        connect(&window,&QQuickWindow::widthChanged,crop,[&]{crop->setWidth(window.width());});
        connect(&window,&QQuickWindow::heightChanged,crop,[&]{crop->setHeight(window.height());});
        crop->setSource(url);window.show();QTRY_COMPARE_WITH_TIMEOUT(crop->status(),1,10000);QTest::qWait(120);
        const auto sample=[&](int i){const auto frame=window.grabWindow();return frame.isNull()?QColor():frame.pixelColor(int((i+.5)*frame.width()/11),frame.height()/2);};
        const auto light=sample(8);QVERIFY2(std::abs(light.red()-127)<=2,qPrintable(QString("Encoded alpha-over must match PDFium: %1").arg(light.name())));
        for(int i:{8,9,10}) {
            const auto c=sample(i),raw=colours[i];const double alpha=raw.alphaF();
            QVERIFY(std::abs(c.red()-qRound(raw.red()*alpha+255*(1-alpha)))<=2);
            QVERIFY(std::abs(c.green()-qRound(raw.green()*alpha+255*(1-alpha)))<=2);
            QVERIFY(std::abs(c.blue()-qRound(raw.blue()*alpha+255*(1-alpha)))<=2);
        }
        const auto jobs=RasterJobs::statistics().value("completed");const auto pixels=crop->pixelSize();
        window.setColor(QColor(40,37,31));crop->setPaperAppearance("dark-figure");QTest::qWait(120);
        const auto black=sample(0),white=sample(4),blue=sample(6),red=sample(7);
        QVERIFY2(std::abs(black.red()-200)<=2 && std::abs(black.green()-191)<=2 && std::abs(black.blue()-175)<=2,qPrintable("Dark neutral ink: "+black.name()));
        QCOMPARE(white,QColor(40,37,31));QVERIFY(std::abs(blue.blue()-16)<=2 && blue.red()<3 && blue.green()<3);QVERIFY(std::abs(red.red()-16)<=2 && red.green()<3 && red.blue()<3);
        const auto gray=sample(2);QVERIFY(gray.red()<black.red() && gray.red()>white.red());
        const auto directory=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!directory.isEmpty())QVERIFY(window.grabWindow().save(directory+"/scientific-crop-dark.png"));
        crop->setPaperAppearance("night");QTest::qWait(120);
        for(int i=0;i<4;++i) {
            const std::array<QColor,4> expected{QColor(201,197,189),QColor(187,183,176),QColor(166,162,156),QColor(130,127,121)};
            const auto c=sample(i);QVERIFY2(std::abs(c.red()-expected[i].red())<=2 && std::abs(c.green()-expected[i].green())<=2 && std::abs(c.blue()-expected[i].blue())<=2,qPrintable(c.name()+" expected "+expected[i].name()));
        }
        QCOMPARE(crop->source(),url);QCOMPARE(crop->pixelSize(),pixels);QCOMPARE(RasterJobs::statistics().value("completed"),jobs);
        crop->setPaperAppearance("original");window.setColor(Qt::white);QTest::qWait(120);QVERIFY(std::abs(sample(8).red()-127)<=2);const auto saturated=sample(5);QVERIFY(std::abs(saturated.red()-255)<=1 && saturated.green()<=1 && saturated.blue()<=1);
        QVERIFY(window.close());
    }
    void referencePreviewAutoSizingUsesBodyAndHonoursManualSize() {
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        auto *panel=window->findChild<QObject *>("referencePreviewPanel");QVERIFY(panel);
        QQmlComponent component(&view.engine);component.setData(R"(
            import QtQuick
            QtObject {
                property var model: ({})
                property bool visible: true
                property bool pinned: false
                property rect anchor: Qt.rect(20,20,10,10)
                signal changed()
                function imageSegments(width,dpr,paper) { return []; }
            })",QUrl());
        auto *controller=component.create();QVERIFY2(controller,qPrintable(component.errorString()));controller->setParent(&view.engine);
        QVERIFY(QQmlProperty::write(panel,"controller",QVariant::fromValue(controller)));
        const auto entry=[](int index,const QString &text){return QVariantMap{{"label",QString::number(index)},{"page",0},{"text",text}};};
        const auto show=[&](const QVariantList &entries,const QString &title){controller->setProperty("model",QVariantMap{{"kind","reference"},{"title",title},{"page",0},{"entries",entries}});return QMetaObject::invokeMethod(controller,"changed");};
        auto literal=entry(1,"A short citation.");literal.insert("label","<b>1</b>");
        QVERIFY(show({literal},"One"));QTRY_VERIFY(panel->property("opened").toBool());QTest::qWait(50);
        auto *heading=visualItem(window->contentItem(),"referenceEntryHeading0");QVERIFY(heading);QCOMPARE(heading->property("textFormat").toInt(),int(Qt::PlainText));QVERIFY(heading->property("text").toString().contains("<b>1</b>"));
        const double shortHeight=panel->property("height").toDouble();QVERIFY2(shortHeight>=120 && shortHeight<200,qPrintable(QString("Short citation height %1").arg(shortHeight)));
        QVERIFY(show({entry(1,"First entry."),entry(2,"Second entry."),entry(3,"Third entry.")},"Three"));QTest::qWait(60);
        QVERIFY(panel->property("height").toDouble()>shortHeight+40);
        panel->setProperty("preferredHeight",240);panel->setProperty("manuallySized",true);QTest::qWait(30);
        const double manual=panel->property("height").toDouble();QVERIFY(QMetaObject::invokeMethod(controller,"changed"));QTest::qWait(30);QCOMPARE(panel->property("height").toDouble(),manual);
        QVERIFY(show({entry(1,QString("Long citation body with preserved words. ").repeated(500))},"Long"));QTest::qWait(60);
        QVERIFY(!panel->property("manuallySized").toBool());QVERIFY(panel->property("height").toDouble()<=window->height()*.8+.1);QVERIFY(panel->property("height").toDouble()>shortHeight);
        const auto directory=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!directory.isEmpty())QVERIFY(window->grabWindow().save(directory+"/preview-long-text.png"));
        controller->setProperty("visible",false);QVERIFY(QMetaObject::invokeMethod(controller,"changed"));QTRY_VERIFY(!panel->property("visible").toBool());
    }
    void previewImageWidthKeepsSubpointLayoutAndRejectsStaleSources() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("preview-density.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/booktabs-bounds.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->setProperty("appearance","light");
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *preview=view.workspace.preview();const double y=reader->pages().first().toMap().value("height").toDouble()-693.5;
        preview->openAt(reader,0,125,y,320,200,1);QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);QCOMPARE(preview->model().value("kind").toString(),QString("figure"));
        auto *panel=window->findChild<QObject *>("referencePreviewPanel");QVERIFY(panel);QTRY_VERIFY_WITH_TIMEOUT(view.cropReady(),10000);
        auto *crop=visualItem(window->contentItem(),"referencePreviewImage");QVERIFY(crop);const auto before=crop->property("source").toUrl();
        QVERIFY(preview->imageSegments(500,std::numeric_limits<double>::quiet_NaN(),"original").isEmpty());QVERIFY(preview->imageSegments(500,0,"original").isEmpty());
        const double width=panel->property("preferredWidth").toDouble(),rasterWidth=panel->property("rasterWidth").toDouble(),actualWidth=crop->width();
        panel->setProperty("preferredWidth",width+.5);QTest::qWait(120);
        QCOMPARE(panel->property("rasterWidth").toDouble(),rasterWidth);QCOMPARE(crop->property("source").toUrl(),before);QVERIFY(std::abs(crop->width()-actualWidth-.5)<.1);
        QPointer<QQuickItem> oldCrop=crop;
        panel->setProperty("preferredWidth",width+70);QTRY_VERIFY(oldCrop.isNull());
        QTRY_VERIFY(visualItem(window->contentItem(),"referencePreviewImage") && visualItem(window->contentItem(),"referencePreviewImage")->property("source").toUrl()!=before);
        QTRY_VERIFY_WITH_TIMEOUT(view.cropReady(),10000);crop=visualItem(window->contentItem(),"referencePreviewImage");QVERIFY(crop);
        const auto source=crop->property("source").toUrl();QCOMPARE(QUrlQuery(source).queryItemValue("transparent"),QString("1"));
        QTest::qWait(150);const auto jobs=RasterJobs::statistics().value("completed");const auto size=crop->property("pixelSize");window->setProperty("appearance","dark");QTest::qWait(120);
        QCOMPARE(crop->property("paperAppearance").toString(),QString("dark-figure"));QCOMPARE(crop->property("source").toUrl(),source);QCOMPARE(crop->property("pixelSize"),size);QCOMPARE(RasterJobs::statistics().value("completed"),jobs);
        preview->close();QTRY_VERIFY(!panel->property("visible").toBool());QTRY_VERIFY(!visualItem(window->contentItem(),"referencePreviewImage"));
        QVERIFY(preview->imageSegments(500,1,"original").isEmpty());
        preview->openAt(reader,0,125,y,320,200,1);preview->close();preview->openAt(reader,0,125,y+15,320,200,1);
        QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);QTRY_VERIFY_WITH_TIMEOUT(view.cropReady(),10000);
        QVERIFY(preview->model().value("title").toString().contains("6"));
        preview->showFullPage();QTRY_VERIFY_WITH_TIMEOUT(view.cropReady(),10000);crop=visualItem(window->contentItem(),"referencePreviewImage");QVERIFY(crop);QCOMPARE(crop->property("paperAppearance").toString(),window->property("paperAppearance").toString());
        preview->close();QTRY_VERIFY(!panel->property("visible").toBool());
    }
    void cropReplacementsRejectQueuedPixelsAndReleaseClosedResources() {
        QTRY_VERIFY_WITH_TIMEOUT(RasterJobs::statistics().value("queued").toInt()==0 && RasterJobs::statistics().value("running").toInt()==0,10000);
        auto entered=std::make_shared<QSemaphore>(),release=std::make_shared<QSemaphore>();auto *pool=RasterJobs::pool();const int count=pool->maxThreadCount();
        for(int i=0;i<count;++i)(void)QtConcurrent::run(pool,[entered,release]{entered->release();release->acquire();});
        auto unblock=qScopeGuard([&]{release->release(count);pool->waitForDone(10000);});QTRY_COMPARE(entered->available(),count);
        const auto url=[](const QSize &size,const QColor &color){QImage image(size,QImage::Format_ARGB32);image.fill(color);QByteArray bytes;QBuffer b(&bytes);if(!b.open(QIODevice::WriteOnly) || !image.save(&b,"PNG"))return QUrl{};return QUrl("data:image/png;base64,"+QString::fromLatin1(bytes.toBase64()));};
        QQuickWindow window;window.resize(320,160);auto *crop=new CropItem(window.contentItem());crop->setSize(window.size());
        const auto first=url({8,8},Qt::red),second=url({16,8},Qt::green),latest=url({24,8},Qt::blue);QVERIFY(!first.isEmpty() && !second.isEmpty() && !latest.isEmpty());
        crop->setSource(first);window.show();QTRY_VERIFY(RasterJobs::statistics().value("queued").toInt()>=1);
        crop->setSource(second);QTRY_VERIFY(RasterJobs::statistics().value("queued").toInt()>=2);
        crop->setSource(latest);QTRY_VERIFY(RasterJobs::statistics().value("queued").toInt()>=3);
        const auto cancelled=RasterJobs::statistics().value("cancelled").toLongLong();release->release(count);unblock.dismiss();
        QTRY_COMPARE_WITH_TIMEOUT(crop->status(),1,10000);QCOMPARE(crop->source(),latest);QCOMPARE(crop->pixelSize(),QSize(24,8));
        QTRY_VERIFY(RasterJobs::statistics().value("cancelled").toLongLong()>=cancelled+2);
        window.hide();QTRY_COMPARE(crop->status(),0);QVERIFY(crop->pixelSize().isEmpty());
        const auto completed=RasterJobs::statistics().value("completed");QTest::qWait(120);QCOMPARE(RasterJobs::statistics().value("completed"),completed);
        window.show();QTRY_COMPARE_WITH_TIMEOUT(crop->status(),1,10000);QCOMPARE(crop->pixelSize(),QSize(24,8));QVERIFY(window.close());
    }
    void singlePageOrdinaryZoomKeepsBothDocumentEdges_data() {
        QTest::addColumn<double>("percent");for(double percent:{25.0,100.0,250.0})QTest::newRow(qPrintable(QString::number(percent)))<<percent;
    }
    void singlePageOrdinaryZoomKeepsBothDocumentEdges() {
        QFETCH(double,percent);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("single-edges.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));window->setProperty("fitting",false);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,percent/100*window->property("calibrationFactor").toDouble()),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));
        auto *list=visualItem(window->contentItem(),"pageList"),*page=visualItem(window->contentItem(),"pdfPage0");QVERIFY(list && page);QTRY_VERIFY(std::abs(page->mapToItem(list,QPointF()).y()-8)<.2);
        list->setProperty("contentY",list->property("originY").toDouble()+std::max(0.0,list->property("contentHeight").toDouble()-list->height()));QTest::qWait(30);QVERIFY(list->height()-page->mapToItem(list,QPointF(0,page->height())).y()>=7.8);
    }
    void fittedPresentationSurvivesHistorySaveAndPointerZoom_data() {
        QTest::addColumn<QString>("layout");QTest::newRow("continuous")<<QString("Continuous");QTest::newRow("facing")<<QString("Facing");
    }
    void fittedPresentationSurvivesHistorySaveAndPointerZoom() {
        QFETCH(QString,layout);const int pageIndex=layout=="Facing" ? 3 : 4;
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/fitted-history.pdf";
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,layout)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));
        auto *canvas=visualItem(window->contentItem(),"documentCanvas"),*list=visualItem(window->contentItem(),"pageList");QVERIFY(canvas && list);
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,pageIndex),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"fitPage"));QVERIFY(settleReaderViewport(window));
        const auto spacing=reader->fitPresentation();QVERIFY(!spacing.isEmpty());
        QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,7),Q_ARG(QVariant,120.0)));
        QVERIFY(QMetaObject::invokeMethod(window,"actualSize"));QVERIFY(reader->fitPresentation().isEmpty());
        QVERIFY(QMetaObject::invokeMethod(window,"goBack"));QVERIFY(settleReaderViewport(window));
        QCOMPARE(window->property("currentPage").toInt(),pageIndex);QCOMPARE(reader->fitPresentation(),spacing);
        auto *page=visualItem(window->contentItem(),"pdfPage"+QString::number(pageIndex));QVERIFY(page);
        QTRY_VERIFY(std::abs(page->mapToItem(list,QPointF(0,0)).y()-(list->height()-page->height())/2)<1);
        reader->submit("bookmark_create",{{"page",pageIndex},{"title","Fit anchor"},{"yPt",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedChanges(),10000);
        QVERIFY(settleReaderViewport(window));QCOMPARE(reader->fitPresentation(),spacing);
        page=visualItem(window->contentItem(),"pdfPage"+QString::number(pageIndex));QVERIFY(page);
        QTRY_VERIFY(std::abs(page->mapToItem(list,QPointF(0,0)).y()-(list->height()-page->height())/2)<1);
        const double probe=list->height()/2;
        QVariant result;QVERIFY(QMetaObject::invokeMethod(canvas,"viewportAnchor",Q_RETURN_ARG(QVariant,result),Q_ARG(QVariant,probe)));
        const auto before=result.value<QJSValue>().toVariant().toMap();QVERIFY(before.contains("page"));
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,window->property("zoom").toDouble()*1.25),Q_ARG(QVariant,list->width()/2),Q_ARG(QVariant,probe)));
        QVERIFY(reader->fitPresentation().isEmpty());
        QVERIFY(QMetaObject::invokeMethod(canvas,"viewportAnchor",Q_RETURN_ARG(QVariant,result),Q_ARG(QVariant,probe)));
        const auto after=result.value<QJSValue>().toVariant().toMap();QCOMPARE(after.value("page"),before.value("page"));
        QVERIFY(std::abs(after.value("y").toDouble()-before.value("y").toDouble())*window->property("zoom").toDouble()*window->effectiveDevicePixelRatio()<1);
    }
    void fittedUnequalSpreadsKeepABoundedVisibleSetAndDiscardStalePadding() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/unequal-sixty-pages.pdf";
        {
            QPdfWriter writer(path);writer.setResolution(72);writer.setPageSize(QPageSize(QSizeF(595,842),QPageSize::Point));
            QPainter painter(&writer);QVERIFY(painter.isActive());
            for(int i=0;i<60;++i) {
                if(i){writer.setPageSize(QPageSize(QSizeF(595,i%2 ? 720 : 910),QPageSize::Point));QVERIFY(writer.newPage());}
                painter.drawText(QPointF(70,70),QString("Synthetic fit page %1").arg(i+1));
            }
        }
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->resize(1600,800);
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),60,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));window->setProperty("pageGap",0);
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,"Facing")));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));
        auto *list=visualItem(window->contentItem(),"pageList");QVERIFY(list);
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,29),Q_ARG(QVariant,0)));
        QVERIFY(settleReaderViewport(window));const auto before=reader->completedRasters();
        QVERIFY(QMetaObject::invokeMethod(window,"fitPage"));QVERIFY(settleReaderViewport(window));
        const auto first=reader->pages().at(29).toMap(),second=reader->pages().at(30).toMap();
        QVERIFY(first.value("height")!=second.value("height"));QCOMPARE(first.value("top"),second.value("top"));
        const double zoom=window->property("zoom").toDouble();
        const double expected=(list->height()-std::max(first.value("height").toDouble(),second.value("height").toDouble())*zoom)/2;
        for(const int index:{29,30}) {
            auto *page=visualItem(window->contentItem(),"pdfPage"+QString::number(index));QVERIFY(page);
            QTRY_VERIFY(std::abs(page->mapToItem(list,QPointF(0,0)).y()-expected)<1);
            QVERIFY(page->mapToItem(list,QPointF(0,page->height())).y()<=list->height()-7.5);
        }
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingRasters(),0,10000);QVERIFY(reader->completedRasters()-before<16);
        // Reducing the real viewport keeps an above-fit percentage and removes old padding.
        const double percent=window->property("zoomPercent").toDouble();
        QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"annotate")));QVERIFY(settleReaderViewport(window));
        QCOMPARE(window->property("zoomPercent").toDouble(),percent);
        const double rowHeight=std::max(first.value("height").toDouble(),second.value("height").toDouble());
        const double rowWidth=second.value("left").toDouble()+second.value("width").toDouble()-first.value("left").toDouble();
        const auto nextFit=reader->fitPercent(true,rowWidth,rowHeight,list->width()-48,list->height(),window->property("calibrationFactor").toDouble());
        auto *page=visualItem(window->contentItem(),"pdfPage29");QVERIFY(page);
        if(percent>nextFit) {
            QVERIFY(reader->fitPresentation().isEmpty());
            QVERIFY2(std::abs(page->mapToItem(list,QPointF(0,0)).y())<1,qPrintable(QString("Stale padding after height change: %1").arg(page->mapToItem(list,QPointF(0,0)).y())));
        } else {
            // A tiling compositor may supply a narrow width where width remains limiting.
            QVERIFY(!reader->fitPresentation().isEmpty());
            QVERIFY(std::abs(page->mapToItem(list,QPointF(0,0)).y()-(list->height()-rowHeight*zoom)/2)<1);
        }
    }
    void viewportResizeRejectsOldTabsAndPreservesRestoredPercent() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto single=scratch.path()+"/single.pdf",multi=scratch.path()+"/multi.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",single));
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",multi));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        window->resize(1100,640);view.workspace.openFile(QUrl::fromLocalFile(single));
        auto *first=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(first->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        QTRY_VERIFY(!window->property("positionRestoring").toBool());
        const double calibration=window->property("calibrationFactor").toDouble();
        window->setProperty("fitting",false);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,.375*calibration),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
        // Queue a real height change, then switch documents before the settle callback.
        window->resize(1100,820);view.workspace.newTab();view.workspace.openFile(QUrl::fromLocalFile(multi));
        auto *second=view.workspace.activeReader();QVERIFY(second!=first);
        QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),9,10000);
        QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);
        QTRY_VERIFY(!window->property("positionRestoring").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"actualSize"));QTest::qWait(120);
        QVERIFY(std::abs(window->property("zoomPercent").toDouble()-100)<1e-7);
        view.workspace.selectTab(0);
        QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        QTRY_VERIFY(!window->property("positionRestoring").toBool());QTest::qWait(120);
        QVERIFY(std::abs(window->property("zoomPercent").toDouble()-37.5)<1e-7);
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
        QCOMPARE(view.workspace.viewState(first).value("zoomPercent").toDouble(),37.5);
        // Restoring a low percentage is not itself a viewport change. The next real one is.
        window->resize(1100,840);QTRY_VERIFY(window->property("zoomPercent").toDouble()>37.5);
    }
    void layoutChangesKeepTheChosenPercentageAndPageAnchor() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/layout-anchor.pdf";
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();auto *window=view.window;
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTRY_VERIFY(!window->property("positionRestoring").toBool());
        const double scale=1.75*window->property("calibrationFactor").toDouble();window->setProperty("fitting",false);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,scale),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,150.0)));
        auto *list=visualItem(window->contentItem(),"pageList");QVERIFY(list);
        for(const auto &layout:{QString("Facing"),QString("Continuous")}) {
            QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,layout)));
            QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
            QCOMPARE(window->property("zoom").toDouble(),scale);
            QTRY_VERIFY(visualItem(window->contentItem(),"pdfPage6"));
            const auto atAnchor=[&]{auto *page=visualItem(window->contentItem(),"pdfPage6");return page && std::abs(page->mapToItem(list,QPointF(0,0)).y()+150*scale)<1;};
            QTRY_VERIFY(atAnchor());QTest::qWait(60);QVERIFY(atAnchor());
        }
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,"Invalid synthetic layout")));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->error().isEmpty());
        const auto pending=window->property("pendingLayoutPosition");
        QVERIFY(pending.isNull() || pending.value<QJSValue>().isNull());
    }
    void cooperativeIndexesYieldCancelAndPublishOnlyCompletedCollections() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto narrative=scratch.path()+"/narrative.pdf",figures=scratch.path()+"/figures.pdf",longer=scratch.path()+"/nine.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/narrative-citation.pdf",narrative));
        QVERIFY(QFile::copy(root+"/tests/fixtures/booktabs-bounds.pdf",figures));
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",longer));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(narrative));
        auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto source=reader->renderSource();QVERIFY(source);HeldRasterAdmission held;QVERIFY(held.ticket);
        auto cancelled=std::make_shared<std::atomic_bool>(false);
        auto waiting=QtConcurrent::run([source,cancelled]{QString error;const auto records=source->query({{"op","references"}},&error,cancelled);return QVariantMap{{"error",error},{"records",records}};});
        QTRY_VERIFY(source->indexStatistics().value("rasterDeferrals").toULongLong()>0);
        cancelled->store(true);QTRY_VERIFY_WITH_TIMEOUT(waiting.isFinished(),10000);
        QVERIFY(waiting.result().value("error").toString().contains("cancelled"));QVERIFY(!waiting.result().value("records").isValid());
        QVERIFY(!reader->data().contains("references"));held.release();
        reader->submit("references");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("references").toList().size(),8);
        const auto steps=source->indexStatistics().value("referenceSteps").toULongLong();QVERIFY(steps>1);
        reader->submit("references");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(source->indexStatistics().value("referenceSteps").toULongLong(),steps);
        view.workspace.openFile(QUrl::fromLocalFile(figures));reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("figures");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->data().value("figures").toList().size()>=2);
        view.workspace.openFile(QUrl::fromLocalFile(longer));reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto nine=reader->renderSource();HeldRasterAdmission second;QVERIFY(second.ticket);
        reader->submit("figures");QTRY_VERIFY(nine->indexStatistics().value("rasterDeferrals").toULongLong()>0);
        QVERIFY(!reader->data().contains("figures"));second.release();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->data().contains("figures"));QVERIFY(reader->data().value("figures").toList().isEmpty());
        QCOMPARE(nine->indexStatistics().value("figureSteps").toULongLong(),qulonglong(3));
    }
    void coldCitationQueriesUseTheCooperativeReferenceGate() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/citation.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/narrative-citation.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto source=reader->renderSource();reader->submit("citations",{{"page",0}});
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(!reader->data().value("citations").toList().isEmpty());
        const auto steps=source->indexStatistics().value("referenceSteps").toULongLong();QVERIFY(steps>1);
        reader->submit("references");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("references").toList().size(),8);QCOMPARE(source->indexStatistics().value("referenceSteps").toULongLong(),steps);
    }
    void indexQueriesCancelOnTabSwitchTabCloseAndGlobalQuit() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/index-close.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/narrative-citation.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto source=reader->renderSource();HeldRasterAdmission held;QVERIFY(held.ticket);
        reader->submit("references");view.workspace.newTab();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->data().contains("references"));QVERIFY(reader->error().isEmpty());
        view.workspace.selectTab(0);QTRY_VERIFY(!view.window->property("positionRestoring").toBool());
        reader->submit("references");QPointer<ReaderController> old=reader;
        QVERIFY(QMetaObject::invokeMethod(view.window,"requestCloseTab",Q_ARG(QVariant,0)));
        QTRY_COMPARE_WITH_TIMEOUT(view.workspace.tabs().size(),1,10000);QTRY_VERIFY(old.isNull());
        QVERIFY(source->indexStatistics().value("cancelledQueries").toULongLong()>0);
        view.workspace.openFile(QUrl::fromLocalFile(path));reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("references");QSignalSpy accepted(view.workspace.quitCoordinator(),&QuitCoordinator::accepted);
        view.workspace.requestQuit();QTRY_COMPARE_WITH_TIMEOUT(accepted.count(),1,10000);
        QVERIFY(!view.window->isVisible());held.release();
    }
    void previewIndexesShareTheFrozenSourceAndKeepIndependentCancellation() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/preview-index.pdf",other=scratch.path()+"/other.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/narrative-citation.pdf",path));QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",other));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto source=reader->renderSource();auto *preview=view.workspace.preview();const double y=reader->pages().first().toMap().value("height").toDouble()-694;
        HeldRasterAdmission held;QVERIFY(held.ticket);preview->openAt(reader,0,144,y,320,200,1);
        QTRY_VERIFY(source->indexStatistics().value("rasterDeferrals").toULongLong()>0);preview->close();
        QTRY_VERIFY(source->indexStatistics().value("cancelledQueries").toULongLong()>0);QVERIFY(!preview->visible() && !preview->loading());held.release();
        reader->submit("references");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->error().isEmpty());
        const auto steps=source->indexStatistics().value("referenceSteps").toULongLong();
        preview->openAt(reader,0,144,y,320,200,1);QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);
        QCOMPARE(preview->model().value("kind").toString(),QString("reference"));QCOMPARE(source->indexStatistics().value("referenceSteps").toULongLong(),steps);
        QObject owner;auto *frozen=preview->createWindowReader(&owner);QVERIFY(frozen);QCOMPARE(frozen->renderSource(),source);
        QTRY_COMPARE_WITH_TIMEOUT(frozen->pendingCommands(),0,10000);reader->openFile(QUrl::fromLocalFile(other));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(!preview->visible());QCOMPARE(frozen->pageCount(),2);frozen->submit("references");
        QTRY_COMPARE_WITH_TIMEOUT(frozen->pendingCommands(),0,10000);QCOMPARE(frozen->data().value("references").toList().size(),8);
    }
    void sharedNavigationControllerKeepsFullPayloadAndTheTwentyEntryPolicy() {
        NavigationController navigation;QCOMPARE(navigation.state().value("limit").toInt(),20);
        const auto location=[](int page){return QVariantMap{{"page",page},{"anchor",QVariantMap{{"page",page},{"y",73.25}}},{"offsetPt",975.5},{"xPt",-43.125},{"zoomPercent",137.5},{"fitting",false},{"fitPreset","page"},{"selection",QVariantMap{{"page",page},{"start",19},{"end",4}}}};};
        for(int page=0;page<25;++page)QVERIFY(navigation.record(location(page)));
        QCOMPARE(navigation.state().value("back").toList().size(),20);QCOMPARE(navigation.state().value("back").toList().first().toMap().value("page").toInt(),5);
        const auto target=navigation.back(location(30));QCOMPARE(target,location(24));QCOMPARE(navigation.forward(target),location(30));
        const auto before=navigation.state();auto bad=location(2);bad["zoomPercent"]=qQNaN();QVERIFY(!navigation.record(bad));QVERIFY(!navigation.error().isEmpty());QCOMPARE(navigation.state(),before);
        navigation.clear();QVERIFY(navigation.error().isEmpty());QVERIFY(navigation.state().value("back").toList().isEmpty());QVERIFY(navigation.back(location(0)).isEmpty());
    }
    void readingBackForwardRestoresSelectionFractionalZoomAndBothLayoutAnchors_data() {
        QTest::addColumn<QString>("layout");QTest::newRow("continuous")<<QString("Continuous");QTest::newRow("facing")<<QString("Facing");
    }
    void readingBackForwardRestoresSelectionFractionalZoomAndBothLayoutAnchors() {
        QFETCH(QString,layout);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/navigation.pdf";
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *window=view.window;auto *reader=view.workspace.activeReader();
        if(qEnvironmentVariableIsSet("LYRA_READER_NAVIGATION_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(700,600);}
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!window->property("positionRestoring").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,layout)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));
        window->setProperty("fitting",false);const double scale=1.375*window->property("calibrationFactor").toDouble();
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,scale),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,150.0)));
        auto *list=visualItem(window->contentItem(),"pageList");QVERIFY(list);list->setProperty("contentX",std::min(75.0,std::max(0.0,list->property("contentWidth").toDouble()-list->width())));
        window->setProperty("selection",QVariantMap{{"page",6},{"start",19},{"end",4}});
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto saved=view.workspace.viewState(reader);
        QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,2),Q_ARG(QVariant,80.0)));
        QCOMPARE(window->property("currentPage").toInt(),2);QVERIFY(window->property("canGoBack").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"goBack"));
        // Restoration is synchronous; no queued callback may later target another document.
        QCOMPARE(window->property("currentPage").toInt(),6);QVERIFY(std::abs(window->property("zoomPercent").toDouble()-137.5)<1e-8);
        auto *navigation=window->findChild<NavigationController *>("navigationController");QVERIFY(navigation);
        const auto restored=navigation->state().value("forward").toList();QCOMPARE(restored.size(),1);
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto after=view.workspace.viewState(reader);
        const auto originalAnchor=saved.value("viewportAnchor").toMap();
        const auto anchorError=[&](const QVariantMap &state){return std::abs(state.value("viewportAnchor").toMap().value("y").toDouble()-originalAnchor.value("y").toDouble())*window->property("zoom").toDouble()*window->devicePixelRatio();};
        QCOMPARE(after.value("viewportAnchor").toMap().value("page"),originalAnchor.value("page"));
        // ListView can quantize its virtual row origin at fractional scale. Preserve
        // the page and stay within one device pixel, including repeated round trips.
        QVERIFY2(anchorError(after)<1,qPrintable(QString("Anchor error: %1 device pixels").arg(anchorError(after),0,'g',17)));
        QVERIFY(std::abs(after.value("documentX").toDouble()-saved.value("documentX").toDouble())<.5);
        for(int i=0;i<20;++i){
            QVERIFY(QMetaObject::invokeMethod(window,"goForward"));QVERIFY(QMetaObject::invokeMethod(window,"goBack"));
            QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto repeated=view.workspace.viewState(reader);
            QCOMPARE(repeated.value("viewportAnchor").toMap().value("page"),originalAnchor.value("page"));
            QVERIFY2(anchorError(repeated)<1,qPrintable(QString("Round trip %1 anchor error: %2 device pixels").arg(i).arg(anchorError(repeated),0,'g',17)));
        }
        QVariant location;QVERIFY(QMetaObject::invokeMethod(window,"currentNavigationLocation",Q_RETURN_ARG(QVariant,location)));
        const auto payload=location.metaType().id()==qMetaTypeId<QJSValue>()?location.value<QJSValue>().toVariant().toMap():location.toMap();
        QCOMPARE(payload.value("selection").toMap().value("start").toInt(),19);QCOMPARE(payload.value("selection").toMap().value("end").toInt(),4);
        QVERIFY(QMetaObject::invokeMethod(window,"goForward"));QCOMPARE(window->property("currentPage").toInt(),2);
        QVERIFY(QMetaObject::invokeMethod(window,"goBack"));QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,3),Q_ARG(QVariant,40.0)));QVERIFY(!window->property("canGoForward").toBool());
        const auto count=navigation->state().value("back").toList().size();QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,4),Q_ARG(QVariant,0.0)));QCOMPARE(navigation->state().value("back").toList().size(),count);
        QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,-1),Q_ARG(QVariant,0)));QCOMPARE(navigation->state().value("back").toList().size(),count);QCOMPARE(window->property("currentPage").toInt(),4);
        QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,5),Q_ARG(QVariant,20.0)));QVERIFY(QMetaObject::invokeMethod(window,"goBack"));
        auto *back=visualItem(window->contentItem(),"navigationBack"),*forward=visualItem(window->contentItem(),"navigationForward");QVERIFY(back && forward);QTRY_VERIFY(back->isVisible() && forward->isVisible());
        QVERIFY(forward->mapRectToScene(forward->boundingRect()).right()<=window->width());
        QVERIFY(QMetaObject::invokeMethod(forward,"clicked"));QCOMPARE(window->property("currentPage").toInt(),5);QVERIFY(QMetaObject::invokeMethod(back,"clicked"));QCOMPARE(window->property("currentPage").toInt(),4);
        const auto snapshot=qEnvironmentVariable("LYRA_READER_NAVIGATION_SNAPSHOT");if(!snapshot.isEmpty()){QTest::qWait(80);QVERIFY(window->grabWindow().save(snapshot+"-"+layout+".png"));}
        view.workspace.newTab();QTest::qWait(60);QVERIFY(!window->property("canGoBack").toBool() && !window->property("canGoForward").toBool());
        view.workspace.selectTab(0);QTRY_VERIFY(!window->property("positionRestoring").toBool());QVERIFY(!window->property("canGoBack").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,2),Q_ARG(QVariant,20.0)));reader->openFile(reader->fileUrl());
        QTRY_VERIFY(!reader->loading() && reader->pendingCommands()==0 && !window->property("positionRestoring").toBool());QVERIFY(!window->property("canGoBack").toBool());
    }
    void readerShortcutsDoNotCaptureKeysFromTheNativeOpenDialog() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/reader.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        view.workspace.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(view.workspace.activeReader()->pageCount()==1 && !view.workspace.activeReader()->loading() && view.workspace.activeReader()->pendingCommands()==0);
        QVERIFY(settleReaderViewport(window));window->requestActivate();QTRY_COMPARE(QGuiApplication::focusWindow(),window);QVERIFY(window->property("readerKeyboardEnabled").toBool());
        auto *picker=window->findChild<QObject *>("documentOpenDialog");QVERIFY(picker);QVERIFY(picker->setProperty("currentFolder",QUrl::fromLocalFile(scratch.path())));
        const auto closePicker=qScopeGuard([&]{picker->setProperty("visible",false);});QVERIFY(QMetaObject::invokeMethod(window,"openDialog"));QTRY_VERIFY(picker->property("visible").toBool());
        QTRY_VERIFY(QGuiApplication::focusWindow()!=window);QVERIFY(!window->property("readerKeyboardEnabled").toBool());
        auto *dialog=QGuiApplication::focusWindow();if(!dialog)QSKIP("The platform file picker is outside this process; real keyboard acceptance remains required.");
        QTest::keyClick(dialog,Qt::Key_Escape);QTRY_VERIFY(!picker->property("visible").toBool());window->requestActivate();QTRY_COMPARE(QGuiApplication::focusWindow(),window);QVERIFY(window->property("readerKeyboardEnabled").toBool());
    }
    void filePickerKeepsKeyboardSelectionValidAfterEnteringASmallerFolder() {
        QTemporaryDir scratch,empty;QVERIFY(scratch.isValid() && empty.isValid());QDir directory(scratch.path());
        for(int i=0;i<90;++i)QVERIFY(directory.mkdir(QString("directory-%1").arg(i,3,10,QChar('0'))));
        const auto child=directory.filePath("directory-080");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",child+"/first.pdf"));QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",child+"/second.pdf"));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *picker=view.window->findChild<QObject *>("documentOpenDialog");QVERIFY(picker);QVERIFY(picker->setProperty("currentFolder",QUrl::fromLocalFile(empty.path())));
        QQmlExpression fallback(qmlContext(picker),picker,QStringLiteral("FileDialog.DontUseNativeDialog"));const auto options=fallback.evaluate();QVERIFY2(!fallback.hasError(),qPrintable(fallback.error().toString()));QVERIFY(picker->setProperty("options",options));
        const auto closePicker=qScopeGuard([&]{picker->setProperty("visible",false);});QVERIFY(QMetaObject::invokeMethod(view.window,"openDialog"));QTRY_VERIFY(picker->property("visible").toBool());QTRY_VERIFY(QGuiApplication::focusWindow()!=view.window);
        QPointer<QQuickWindow> dialog;QPointer<QQuickItem> list;
        const auto locate=[&]{for(auto *window:QGuiApplication::allWindows())if(auto *quick=qobject_cast<QQuickWindow *>(window))if(quick->isVisible())if(auto *found=visualItem(quick->contentItem(),"fileDialogListView"))if(found->isVisible() && found->window()){list=found;dialog=found->window();return true;}return false;};
        QTRY_VERIFY_WITH_TIMEOUT(locate(),5000);
        QTRY_COMPARE_WITH_TIMEOUT(list->property("count").toInt(),0,5000);
        // Follow the actual location editor path; do not inject a private delegate state.
        dialog->requestActivate();QTRY_COMPARE_WITH_TIMEOUT(QGuiApplication::focusWindow(),dialog.data(),5000);QTest::keyClick(dialog,Qt::Key_L,Qt::ControlModifier);QTRY_VERIFY_WITH_TIMEOUT(dialog->activeFocusItem() && dialog->activeFocusItem()->property("selectedText").isValid(),3000);QInputMethodEvent location;location.setCommitString(scratch.path());QCoreApplication::sendEvent(dialog->activeFocusItem(),&location);QCOMPARE(dialog->activeFocusItem()->property("text").toString(),scratch.path());QTest::keyClick(dialog,Qt::Key_Return);
        QTRY_COMPARE_WITH_TIMEOUT(picker->property("currentFolder").toUrl(),QUrl::fromLocalFile(scratch.path()),5000);QTRY_COMPARE_WITH_TIMEOUT(list->property("count").toInt(),90,5000);QTRY_COMPARE_WITH_TIMEOUT(list->property("currentIndex").toInt(),0,3000);
        QTRY_VERIFY(visualItem(dialog->contentItem(),"fileDialogDelegate0"));
        const auto focusInList=[&]{for(auto *item=dialog->activeFocusItem();item;item=item->parentItem())if(item==list)return true;return false;};
        const auto filterFocused=[&]{for(auto *item=dialog->activeFocusItem();item;item=item->parentItem())if(item->inherits("QQuickComboBox"))return true;return false;};
        // Qt's fallback links backward Tab from the filter to its current file delegate.
        for(int step=0;step<32 && !filterFocused();++step)QTest::keyClick(dialog,Qt::Key_Tab);
        QVERIFY(filterFocused());QTest::keyClick(dialog,Qt::Key_Backtab,Qt::ShiftModifier);QVERIFY2(focusInList(),"Backward Tab from the filter must reach the nonempty file view");
        for(int i=0;i<82 && list->property("currentIndex").toInt()!=80;++i)QTest::keyClick(dialog,Qt::Key_Down);
        QCOMPARE(list->property("currentIndex").toInt(),80);QTest::keyClick(dialog,Qt::Key_Return);
        QTRY_COMPARE_WITH_TIMEOUT(picker->property("currentFolder").toUrl(),QUrl::fromLocalFile(child),5000);QTRY_COMPARE_WITH_TIMEOUT(list->property("count").toInt(),2,5000);QTRY_COMPARE_WITH_TIMEOUT(list->property("currentIndex").toInt(),0,5000);
        QTest::keyClick(dialog,Qt::Key_Down);QTRY_COMPARE(list->property("currentIndex").toInt(),1);QTest::qWait(20);QCOMPARE(list->property("currentIndex").toInt(),1);
        QTest::keyClick(dialog,Qt::Key_Up);QTest::keyClick(dialog,Qt::Key_Return);QTRY_VERIFY(!picker->property("visible").toBool());QTRY_COMPARE_WITH_TIMEOUT(view.workspace.activeReader()->pageCount(),1,10000);QCOMPARE(view.workspace.activeReader()->fileUrl(),QUrl::fromLocalFile(child+"/first.pdf"));
    }
    void navigationKeysBelongToTheFocusedReaderInsteadOfTransientAncestors() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/navigation-keys.pdf";
        QVERIFY(QFile::copy(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *window=view.window;auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==9 && !reader->loading() && reader->pendingCommands()==0 && !window->property("positionRestoring").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,100.0)));QVERIFY(QMetaObject::invokeMethod(window,"jumpFromPreview",Q_ARG(QVariant,2),Q_ARG(QVariant,20.0)));
        auto *navigation=window->findChild<NavigationController *>("navigationController");QVERIFY(navigation);window->requestActivate();QTRY_VERIFY(navigation->keyboardFocus());
        QTest::keyClick(window,Qt::Key_PageDown);QTRY_COMPARE_WITH_TIMEOUT(window->property("currentPage").toInt(),3,3000);
        QTest::keyClick(window,Qt::Key_PageUp);QTRY_COMPARE_WITH_TIMEOUT(window->property("currentPage").toInt(),2,3000);
        auto *pageNumber=visualItem(window->contentItem(),"pageNumber");QVERIFY(pageNumber);pageNumber->forceActiveFocus();QTRY_VERIFY(pageNumber->hasActiveFocus());
        QTest::keyClick(window,Qt::Key_PageDown);QCOMPARE(window->property("currentPage").toInt(),2);
        QTest::keyClick(window,Qt::Key_PageUp);QCOMPARE(window->property("currentPage").toInt(),2);
        QTest::keyClick(window,Qt::Key_Home,Qt::ControlModifier);QCOMPARE(window->property("currentPage").toInt(),2);
        QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);QCOMPARE(window->property("currentPage").toInt(),2);
        QVERIFY(QMetaObject::invokeMethod(window,"focusReadingView"));
        QTest::keyClick(window,Qt::Key_Left,Qt::AltModifier);QCOMPARE(window->property("currentPage").toInt(),6);QVERIFY(window->property("canGoForward").toBool());
        QQuickWindow auxiliary;auxiliary.setTransientParent(window);auxiliary.setFlag(Qt::Dialog);auxiliary.show();auxiliary.requestActivate();QTRY_COMPARE(QGuiApplication::focusWindow(),&auxiliary);QVERIFY(!navigation->keyboardFocus());
        QTest::keyClick(&auxiliary,Qt::Key_Right,Qt::AltModifier);QCOMPARE(window->property("currentPage").toInt(),6);QVERIFY(window->property("canGoForward").toBool());
        QTest::keyClick(&auxiliary,Qt::Key_PageDown);QCOMPARE(window->property("currentPage").toInt(),6);
        QVERIFY(auxiliary.close());window->requestActivate();QTRY_VERIFY(navigation->keyboardFocus());QTest::keyClick(window,Qt::Key_Right,Qt::AltModifier);QCOMPARE(window->property("currentPage").toInt(),2);
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
            auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
            window->setProperty("requestedPage",6);window->setProperty("requestedY",150.0);workspace.openFile(url);
            QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
            auto *view=window->findChild<QQuickItem *>("pageList");QVERIFY(view);
            // Wait for the requested opening region, so an initial deferred
            // saved-position restore cannot race the first simulated interaction.
            QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage6") && visualItem(window->contentItem(),"pdfPage6")->property("texturesReady").toBool(),10000);
            if(facing) {
                QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,"Facing")));
                QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
                // Layout changes preserve the percentage. This anchor fixture explicitly
                // fits both pages before zooming, instead of relying on a sticky preset.
                QVERIFY(QMetaObject::invokeMethod(window,"fitWidth"));
            }
            QVERIFY(settleReaderViewport(window));
            window->setProperty("fitting",false);
            // Start at the loop's minimum scale so the chosen anchor remains
            // representable: zoom-out clamping is exercised by separate cases.
            QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,2.7),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
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
                QVERIFY2(QLineF(point,actual).length()<0.5,qPrintable(QString("Zoom anchor drift: %1 pt step=%2 initial=(%3,%4) actual=(%5,%6) zoom=%7 width=%8").arg(QLineF(point,actual).length()).arg(step).arg(point.x()).arg(point.y()).arg(actual.x()).arg(actual.y()).arg(window->property("zoom").toDouble()).arg(view->width())));
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
            auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
            // Force the startup autosave ordering seen on XWayland before the
            // asynchronous layout/position restore has completed.
            connect(workspace.activeReader(),&ReaderController::openFinished,window,[window](bool success){if(success)QMetaObject::invokeMethod(window,"saveReadingPosition");});
            workspace.openFile(url);
            QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),9,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);
            auto *view=window->findChild<QQuickItem *>("pageList");QVERIFY(view);
            const auto page=[&]{return visualItem(window->contentItem(),"pdfPage6");};
            QTimer::singleShot(2000,window,[window,view,&workspace,saved] {
                auto *target=visualItem(window->contentItem(),"pdfPage6");
                QVariantMap state{{"expected",saved},{"stored",workspace.viewState(workspace.activeReader())},{"page",window->property("currentPage")},{"zoom",window->property("zoom")},{"pendingPosition",window->property("pendingPosition")},{"contentY",view->property("contentY")},{"originY",view->property("originY")},{"pageExists",bool(target)}};
                if(target){state.insert("sceneY",target->mapToItem(view,QPointF(0,0)).y());state.insert("texturesReady",target->property("texturesReady"));}
                qInfo().noquote()<<"lyra-reader-restore-pending:"<<QJsonDocument::fromVariant(state).toJson(QJsonDocument::Compact);
            });
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
        auto *more=window->findChild<QQuickItem *>("moreCommands");auto *search=window->findChild<QQuickItem *>("searchButton");
        auto *sidebar=window->findChild<QQuickItem *>("readerSidebar");auto *area=window->findChild<QQuickItem *>("readingArea");
        QVERIFY(more && search && sidebar && area);QTRY_VERIFY(search->isVisible());QTest::qWait(150);
        const auto moreBounds=more->mapRectToScene(QRectF(0,0,more->width(),more->height()));
        const auto searchBounds=search->mapRectToScene(QRectF(0,0,search->width(),search->height()));
        QVERIFY(moreBounds.right()<=searchBounds.left());QVERIFY(searchBounds.right()<=window->width());
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,moreBounds.center().toPoint());
        auto *menu=window->findChild<QObject *>("moreCommandsMenu");QVERIFY(menu);QTRY_VERIFY(menu->property("visible").toBool());
        QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY(!menu->property("visible").toBool());
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,searchBounds.center().toPoint());QTRY_VERIFY(window->property("searchVisible").toBool());auto *query=visualItem(window->contentItem(),"panelSearchField");QVERIFY(query);QTRY_VERIFY(query->hasActiveFocus());
        window->setProperty("sidebarVisible",true);
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
        QTRY_VERIFY_WITH_TIMEOUT(window->isSceneGraphInitialized(),10000);
        qInfo()<<"Qt test actual graphics:"<<window->rendererInterface()->graphicsApi();
        if(graphicsBackend=="vulkan" || (graphicsBackend.isEmpty() && qEnvironmentVariable("QSG_RHI_BACKEND")=="vulkan"))
            QCOMPARE(window->rendererInterface()->graphicsApi(),QSGRendererInterface::Vulkan);
        else if(graphicsBackend=="opengl")QCOMPARE(window->rendererInterface()->graphicsApi(),QSGRendererInterface::OpenGL);
        else if(graphicsBackend=="software")QCOMPARE(window->rendererInterface()->graphicsApi(),QSGRendererInterface::Software);
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
    void typedSignaturesUseInstalledFontsAndOnlyPlaceAfterConfirmation() {
        ReaderController renderer;const auto fonts=renderer.signatureFonts();QVERIFY(!fonts.isEmpty());
        QVERIFY(renderer.typedSignatureImage(" ",fonts.first()).contains("error"));
        QVERIFY(renderer.typedSignatureImage(QString(257,'a'),fonts.first()).contains("error"));
        QVERIFY(renderer.typedSignatureImage("A\nB",fonts.first()).contains("error"));
        QVERIFY(renderer.typedSignatureImage("A","NoSuchSignatureFont").contains("error"));
        const auto artwork=renderer.typedSignatureImage("Dana Example",fonts.first());QVERIFY2(!artwork.contains("error"),qPrintable(artwork.value("error").toString()));
        QImage expected;QVERIFY(expected.loadFromData(QByteArray::fromBase64(artwork.value("image").toByteArray())));QVERIFY(expected.width()<=2048 && expected.height()<=512);int ink=0,clear=0;for(int y=0;y<expected.height();++y)for(int x=0;x<expected.width();++x){const auto c=expected.pixelColor(x,y);if(c.alpha()==0)++clear;else if(c.red()<80 && c.green()<80 && c.blue()<80)++ink;}QVERIFY(ink>10 && clear>10);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/typed-signature.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);if(qEnvironmentVariableIsSet("LYRA_READER_TYPED_SIGNATURE_DARK"))window->setProperty("appearance","dark");workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"setFillTool",Q_ARG(QVariant,"signature")));auto *typeButton=visualItem(window->contentItem(),"typeSignatureButton");QVERIFY(typeButton);QTRY_VERIFY(typeButton->isVisible());QVERIFY(QMetaObject::invokeMethod(typeButton,"clicked"));auto *dialog=window->findChild<QObject *>("typedSignatureDialog");QVERIFY(dialog);QTRY_VERIFY(dialog->property("opened").toBool());auto *name=window->findChild<QObject *>("typedSignatureName");auto *place=visualItem(window->contentItem(),"placeTypedSignature");QVERIFY(name && place);QVERIFY(!place->isEnabled());name->setProperty("text","Dana Example");QTRY_VERIFY(dialog->property("canPlace").toBool());name->setProperty("text","Dana Changed");QVERIFY(!dialog->property("canPlace").toBool());QVERIFY(!place->isEnabled());name->setProperty("text","Dana Example");auto *fontChoice=window->findChild<QObject *>("typedSignatureFont");QVERIFY(fontChoice);if(fonts.size()>1){fontChoice->setProperty("currentIndex",1);QVERIFY(!dialog->property("canPlace").toBool());fontChoice->setProperty("currentIndex",0);}QTRY_VERIFY(dialog->property("canPlace").toBool());QVERIFY(!reader->hasUnsavedChanges());
        const auto evidence=qEnvironmentVariable("LYRA_READER_TYPED_SIGNATURE_SNAPSHOT");if(!evidence.isEmpty()){QTest::qWait(100);QVERIFY(window->grabWindow().save(evidence));}
        QVERIFY(QMetaObject::invokeMethod(place,"clicked"));QTRY_VERIFY(!dialog->property("visible").toBool());QTRY_COMPARE(window->property("annotationTool").toString(),QString("signature"));
        const auto map=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>() ? v.value<QJSValue>().toVariant().toMap() : v.toMap();};const auto pending=map(window->property("pendingSignatureImage"));QCOMPARE(pending.value("image"),artwork.value("image"));QVERIFY(!reader->hasUnsavedChanges());
        // Cancelling a later chooser keeps the signature that was already armed.
        QVERIFY(QMetaObject::invokeMethod(typeButton,"clicked"));QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(QMetaObject::invokeMethod(dialog,"reject"));QTRY_VERIFY(!dialog->property("visible").toBool());QCOMPARE(map(window->property("pendingSignatureImage")).value("image"),pending.value("image"));
        QVERIFY(QMetaObject::invokeMethod(window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200),Q_ARG(QVariant,450),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto entries=[&]{return reader->data().value("marks").toMap().value("annotations").toList();};QTRY_COMPARE(entries().size(),1);QCOMPARE(entries().first().toMap().value("kind").toString(),QString("signature"));QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_COMPARE(entries().size(),0);QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_COMPARE(entries().size(),1);
        QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedChanges(),15000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);const auto saved=reopened.data().value("annotations").toList();QCOMPARE(saved.size(),1);QCOMPARE(saved.first().toMap().value("kind").toString(),QString("stamp"));QImage recovered;QVERIFY(recovered.loadFromData(QByteArray::fromBase64(saved.first().toMap().value("stamp").toMap().value("image").toByteArray())));QCOMPARE(recovered.convertToFormat(QImage::Format_RGBA8888),expected.convertToFormat(QImage::Format_RGBA8888));
        // A late confirmation cannot place the name into a new document reusing this reader.
        QVERIFY(QMetaObject::invokeMethod(window,"clearFillTool"));QVERIFY(QMetaObject::invokeMethod(window,"setFillTool",Q_ARG(QVariant,"signature")));QVERIFY(QMetaObject::invokeMethod(typeButton,"clicked"));QTRY_VERIFY(dialog->property("opened").toBool());name->setProperty("text","Dana Example");QTRY_VERIFY(dialog->property("canPlace").toBool());reader->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!dialog->property("canPlace").toBool());QVERIFY(!place->isEnabled());QVERIFY(QMetaObject::invokeMethod(dialog,"accept"));QTRY_VERIFY(!dialog->property("visible").toBool());QVERIFY(window->property("annotationTool").toString()!="signature");QVERIFY(!reader->hasUnsavedChanges());
    }
    void drawnSignaturesKeepMultipleVectorPathsInOneUndoAndSavedInk() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/drawn.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);
        if(qEnvironmentVariableIsSet("LYRA_READER_DRAWN_DARK_NARROW")){view.window->setProperty("appearance","dark");view.window->resize(700,600);}
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"signature")));
        auto *draw=visualItem(view.window->contentItem(),"drawSignatureButton");QVERIFY(draw);QVERIFY(QMetaObject::invokeMethod(draw,"clicked"));
        auto *dialog=view.window->findChild<QObject *>("drawnSignatureDialog");auto *pad=visualItem(view.window->contentItem(),"signaturePad");auto *pointer=visualItem(view.window->contentItem(),"signaturePadPointer");
        QVERIFY(dialog && pad && pointer);QTRY_VERIFY(dialog->property("opened").toBool());
        const auto point=[&](int x,int y){return pointer->mapToScene(QPointF(x,y)).toPoint();};
        QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,point(20,30));QVERIFY(!dialog->property("canPlace").toBool());
        QTest::mousePress(view.window,Qt::LeftButton,Qt::NoModifier,point(20,30));QTRY_VERIFY(pointer->property("pressed").toBool());
        QTest::mouseMove(view.window,point(100,60),20);QTest::mouseMove(view.window,point(180,25),20);QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,point(180,25),20);QTRY_COMPARE(pad->property("pointCount").toInt(),3);
        QTest::mousePress(view.window,Qt::LeftButton,Qt::NoModifier,point(40,110));QTRY_VERIFY(pointer->property("pressed").toBool());QTest::mouseMove(view.window,point(160,110),20);QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,point(160,110),20);QTRY_COMPARE(pad->property("pointCount").toInt(),5);
        QTRY_VERIFY(dialog->property("canPlace").toBool());
        if(!qEnvironmentVariableIsEmpty("LYRA_READER_DRAWN_SNAPSHOT")){QTest::qWait(50);QVERIFY(view.window->grabWindow().save(qEnvironmentVariable("LYRA_READER_DRAWN_SNAPSHOT")));}
        QVERIFY(QMetaObject::invokeMethod(dialog,"accept"));QTRY_VERIFY(!dialog->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200),Q_ARG(QVariant,400),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto entries=[&]{return reader->data().value("marks").toMap().value("annotations").toList();};
        QTRY_COMPARE(entries().size(),1);const auto ink=entries().first().toMap();const auto paths=ink.value("paths").toList();
        QCOMPARE(ink.value("kind").toString(),QString("ink"));QVERIFY(!ink.contains("image"));QCOMPARE(paths.size(),2);QCOMPARE(paths[0].toList().size(),3);QCOMPARE(paths[1].toList().size(),2);
        const auto rules=reader->data().value("annotation_rules").toMap();QCOMPARE(ink.value("strokeWidth").toDouble(),rules.value("default_stroke_width_pt").toDouble());
        const auto rect=ink.value("rect").toMap();QCOMPARE(rect.value("height").toDouble(),rules.value("default_signature_height_pt").toDouble());
        QVERIFY(paths[0].toList()[1].toMap().value("y").toDouble()>paths[0].toList()[0].toMap().value("y").toDouble());
        QVERIFY(QMetaObject::invokeMethod(view.window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(entries().size(),0);
        QVERIFY(QMetaObject::invokeMethod(view.window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(entries().size(),1);QCOMPARE(entries().first().toMap().value("paths"),ink.value("paths"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedChanges() && reader->pendingCommands()==0,15000);
        ReaderController saved;saved.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(saved.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(saved.pendingCommands(),0,10000);
        const auto annotations=saved.data().value("annotations").toList();QCOMPARE(annotations.size(),1);const auto fileInk=annotations.first().toMap();QCOMPARE(fileInk.value("kind").toString(),QString("ink"));QCOMPARE(fileInk.value("ink_paths").toList().size(),2);
    }
    void drawnSignatureCancelClearAndSameUrlReopenCannotPlaceOldStrokes() {
        NativeCorpus::Viewer view;QVERIFY(view.window);const auto url=QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf");view.workspace.openFile(url);auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"signature")));auto *draw=visualItem(view.window->contentItem(),"drawSignatureButton");QVERIFY(draw);
        QVERIFY(QMetaObject::invokeMethod(draw,"clicked"));auto *dialog=view.window->findChild<QObject *>("drawnSignatureDialog");auto *pointer=visualItem(view.window->contentItem(),"signaturePadPointer");auto *clear=visualItem(view.window->contentItem(),"clearDrawnSignature");QVERIFY(dialog && pointer && clear);QTRY_VERIFY(dialog->property("opened").toBool());
        const auto stroke=[&]{QTest::mousePress(view.window,Qt::LeftButton,Qt::NoModifier,pointer->mapToScene(QPointF(20,50)).toPoint());QTest::mouseMove(view.window,pointer->mapToScene(QPointF(100,50)).toPoint(),20);QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,pointer->mapToScene(QPointF(100,50)).toPoint(),20);};
        auto *pad=visualItem(view.window->contentItem(),"signaturePad");QVERIFY(pad);const auto rules=reader->data().value("annotation_rules").toMap();auto limited=rules;limited["max_ink_points"]=2;limited["max_ink_paths"]=1;QVERIFY(QQmlProperty(pad,"rules").write(limited));QCOMPARE(pad->property("pointLimit").toInt(),2);QCOMPARE(pad->property("pathLimit").toInt(),1);
        stroke();QCOMPARE(pad->property("pointCount").toInt(),2);QCOMPARE(pad->property("pointLimit").toInt(),2);stroke();QVERIFY(pad->property("limitReached").toBool());QCOMPARE(pad->property("pointCount").toInt(),2);QVERIFY(QMetaObject::invokeMethod(clear,"clicked"));
        QTest::mousePress(view.window,Qt::LeftButton,Qt::NoModifier,pointer->mapToScene(QPointF(20,50)).toPoint());QTest::mouseMove(view.window,pointer->mapToScene(QPointF(60,50)).toPoint(),20);QTest::mouseMove(view.window,pointer->mapToScene(QPointF(100,50)).toPoint(),20);QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,pointer->mapToScene(QPointF(100,50)).toPoint(),20);QVERIFY(pad->property("limitReached").toBool());QCOMPARE(pad->property("pointCount").toInt(),2);QVERIFY(QMetaObject::invokeMethod(clear,"clicked"));pad->setProperty("rules",rules);
        stroke();QTRY_VERIFY(dialog->property("canPlace").toBool());QVERIFY(QMetaObject::invokeMethod(clear,"clicked"));QVERIFY(!dialog->property("canPlace").toBool());stroke();QVERIFY(QMetaObject::invokeMethod(dialog,"reject"));QTRY_VERIFY(!dialog->property("visible").toBool());QVERIFY(!reader->hasUnsavedChanges());QVERIFY(view.window->property("pendingDrawnSignature").isNull());
        QVERIFY(QMetaObject::invokeMethod(draw,"clicked"));QTRY_VERIFY(dialog->property("opened").toBool());stroke();QTRY_VERIFY(dialog->property("canPlace").toBool());reader->openFile(url);QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && reader->pendingCommands()==0 && reader->pageCount()==1,10000);QVERIFY(!dialog->property("canPlace").toBool());QVERIFY(QMetaObject::invokeMethod(dialog,"accept"));QVERIFY(view.window->property("pendingDrawnSignature").isNull());
        QVERIFY(QMetaObject::invokeMethod(draw,"clicked"));QTRY_VERIFY(dialog->property("opened").toBool());stroke();QTRY_VERIFY(dialog->property("canPlace").toBool());QVERIFY(QMetaObject::invokeMethod(dialog,"accept"));QTRY_VERIFY(!dialog->property("visible").toBool());reader->openFile(url);QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && reader->pendingCommands()==0 && reader->pageCount()==1,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200),Q_ARG(QVariant,400),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(!reader->hasUnsavedChanges());QVERIFY(view.window->property("pendingDrawnSignature").isNull());
    }
    void pictureSizesUseSharedDefaultsAndStalePickersCannotArmANewGeneration() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/pictures.pdf",imagePath=scratch.path()+"/picture.png";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QImage image(64,32,QImage::Format_RGBA8888);image.fill(QColor(240,20,40,128));QVERIFY(image.save(imagePath));QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto before=original.readAll();original.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);if(qEnvironmentVariableIsSet("LYRA_READER_PICTURE_DARK_NARROW")){view.window->setProperty("appearance","dark");view.window->resize(860,640);}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!view.window->property("positionRestoring").toBool());
        const auto rules=reader->data().value("annotation_rules").toMap();QCOMPARE(rules.value("default_picture_height_pt").toDouble(),140.0);QCOMPARE(rules.value("default_signature_height_pt").toDouble(),64.0);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"fill"),Q_ARG(QVariant,true)));auto *button=visualItem(view.window->contentItem(),"fillToolimage"),*sizes=visualItem(view.window->contentItem(),"fillPictureSize");auto *picker=view.window->findChild<QObject *>("signatureImagePicker");QVERIFY(button && sizes && picker);
        auto entries=[&]{return reader->data().value("marks").toMap().value("annotations").toList();};
        for(int i=0;i<3;++i) {
            QVERIFY(QMetaObject::invokeMethod(button,"clicked"));QTRY_VERIFY(picker->property("visible").toBool());QVERIFY(picker->setProperty("currentFile",QUrl::fromLocalFile(imagePath)));QTRY_COMPARE(picker->property("selectedFile").toUrl(),QUrl::fromLocalFile(imagePath));QVERIFY(QMetaObject::invokeMethod(picker,"accepted"));QVERIFY(QMetaObject::invokeMethod(picker,"close"));QTRY_VERIFY(!picker->property("visible").toBool());QTRY_VERIFY2(view.window->property("annotationTool").toString()=="signature",qPrintable(view.window->property("operationStatus").toString()));QCOMPARE(view.window->property("fillTool").toString(),QString("image"));QTRY_VERIFY(sizes->isVisible());sizes->setProperty("currentIndex",i);QVERIFY(QMetaObject::invokeMethod(sizes,"activated",Q_ARG(int,i)));
            const double height=i==0 ? 80 : i==1 ? rules.value("default_picture_height_pt").toDouble() : 220;
            if(i==2 && !qEnvironmentVariableIsEmpty("LYRA_READER_PICTURE_SNAPSHOT")){auto *preview=visualItem(view.window->contentItem(),"fillPicturePreview");QVERIFY(preview);QTRY_COMPARE(preview->property("status").toInt(),1);QVERIFY(view.window->grabWindow().save(qEnvironmentVariable("LYRA_READER_PICTURE_SNAPSHOT")));}
            QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200),Q_ARG(QVariant,400),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY2(entries().size()==i+1,qPrintable(reader->error()+" | "+view.window->property("operationStatus").toString()));const auto entry=entries()[i].toMap(),rect=entry.value("rect").toMap();QCOMPARE(entry.value("kind").toString(),QString("signature"));QCOMPARE(entry.value("stampStyle").toString(),QString("image"));QCOMPARE(rect.value("height").toDouble(),height);QCOMPARE(rect.value("width").toDouble(),height*2);
        }
        QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),before);original.close();QVERIFY(QMetaObject::invokeMethod(view.window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(entries().size(),2);QVERIFY(QMetaObject::invokeMethod(view.window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(entries().size(),3);
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedChanges(),15000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->data().value("annotation_rules").toMap(),rules);
        ReaderController saved;saved.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(saved.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(saved.pendingCommands(),0,10000);const auto file=saved.data().value("annotations").toList();QCOMPARE(file.size(),3);for(const auto &value:file){QImage pixels;QVERIFY(pixels.loadFromData(QByteArray::fromBase64(value.toMap().value("stamp").toMap().value("image").toByteArray())));QCOMPARE(pixels.size(),image.size());QVERIFY(pixels.pixelColor(0,0).alpha()<255);}
        QVERIFY(QMetaObject::invokeMethod(button,"clicked"));QTRY_VERIFY(picker->property("visible").toBool());const auto epoch=reader->documentGeneration();reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && reader->pendingCommands()==0 && reader->pageCount()==1,10000);QVERIFY(reader->documentGeneration()!=epoch);QVERIFY(picker->setProperty("currentFile",QUrl::fromLocalFile(imagePath)));QVERIFY(QMetaObject::invokeMethod(picker,"accepted"));QVERIFY(QMetaObject::invokeMethod(picker,"close"));QTRY_VERIFY(!picker->property("visible").toBool());QVERIFY(view.window->property("annotationTool").toString()!="signature");QVERIFY(!reader->hasUnsavedChanges());
    }
    void typedSignatureConfirmationIsBoundBeforeOpeningAndRejectsSameUrlReopens() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/typed-reopen.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"signature")));auto *type=visualItem(view.window->contentItem(),"typeSignatureButton");QVERIFY(type);QVERIFY(QMetaObject::invokeMethod(type,"clicked"));auto *dialog=view.window->findChild<QObject *>("typedSignatureDialog"),*name=view.window->findChild<QObject *>("typedSignatureName");QVERIFY(dialog && name);QTRY_VERIFY(dialog->property("opened").toBool());name->setProperty("text","Dana Example");QTRY_VERIFY(dialog->property("canPlace").toBool());const auto epoch=reader->documentGeneration();reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && reader->pendingCommands()==0 && reader->pageCount()==1,10000);QVERIFY(reader->documentGeneration()!=epoch);QTRY_VERIFY(!dialog->property("canPlace").toBool());QVERIFY(QMetaObject::invokeMethod(dialog,"accept"));QVERIFY(view.window->property("annotationTool").toString()!="signature");QVERIFY(!reader->hasUnsavedChanges());
        QVERIFY(QMetaObject::invokeMethod(view.window,"clearFillTool"));QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"signature")));QVERIFY(QMetaObject::invokeMethod(type,"clicked"));reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && reader->pendingCommands()==0 && reader->pageCount()==1,10000);QTRY_VERIFY(dialog->property("opened").toBool());name->setProperty("text","Late name");QVERIFY(!dialog->property("contextMatches").toBool());QVERIFY(QMetaObject::invokeMethod(dialog,"reject"));
    }
    void stampsAndSignaturesUseNativeGesturesAndPreserveTransparentPixels() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/artwork.pdf",imagePath=scratch.path()+"/signature.png",output=scratch.path()+"/saved.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        QImage signature(64,32,QImage::Format_RGBA8888);signature.fill(Qt::transparent);
        for(int y=0;y<32;++y)for(int x=0;x<32;++x)signature.setPixelColor(x,y,QColor(240,20,40,128));
        QVERIFY(signature.save(imagePath));
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
        QVERIFY(settleReaderViewport(window));
        window->setProperty("fitting",false);window->setProperty("paperAppearance","original");
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTest::qWait(150);
        const auto point=[&](double x,double y){return visualItem(window->contentItem(),"pdfPage0")->mapToScene(QPointF(x,y)*window->property("zoom").toDouble()).toPoint();};
        const auto entries=[&]{return reader.data().value("marks").toMap().value("annotations").toList();};
        QVERIFY(QMetaObject::invokeMethod(window,"armStamp",Q_ARG(QVariant,"approved")));QTest::qWait(50);
        QVERIFY(visualItem(window->contentItem(),"stampToolButton"));QVERIFY(visualItem(window->contentItem(),"signatureToolButton"));
        auto *accessible=QAccessible::queryAccessibleInterface(visualItem(window->contentItem(),"signatureToolButton"));QVERIFY(accessible);QVERIFY(!accessible->text(QAccessible::Name).isEmpty());
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point(180,200));QTRY_COMPARE_WITH_TIMEOUT(entries().size(),1,10000);
        QTRY_COMPARE(window->property("annotationTool").toString(),QString("select"));
        QCOMPARE(entries().first().toMap().value("kind").toString(),QString("stamp"));QCOMPARE(entries().first().toMap().value("note").toString(),QString("APPROVED"));
        QVERIFY(window->property("selection").isNull());
        QVERIFY(QMetaObject::invokeMethod(window,"armSignature",Q_ARG(QVariant,QUrl::fromLocalFile(imagePath))));QTest::qWait(100);
        const auto before=window->grabWindow();QVERIFY(!before.isNull());
        const auto sample=[&](const QImage &frame,double x,double y){const auto p=point(x,y);return frame.pixelColor(qRound(p.x()*frame.width()/double(window->width())),qRound(p.y()*frame.height()/double(window->height())));};
        const auto background=sample(before,318,350),transparent=sample(before,382,350);
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point(350,350));QTRY_COMPARE_WITH_TIMEOUT(entries().size(),2,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTRY_COMPARE(window->property("annotationTool").toString(),QString("select"));
        const auto entry=entries().last().toMap();QCOMPARE(entry.value("kind").toString(),QString("signature"));QVERIFY(!entry.value("image").toString().isEmpty());
        const auto cropName="signatureArt"+entry.value("id").toString();
        const auto artworkItem=[&]{return visualItem(visualItem(window->contentItem(),"pdfPage0")->parentItem(),cropName);};
        QTRY_VERIFY_WITH_TIMEOUT(artworkItem() && artworkItem()->property("status").toInt()==1,10000);
        QTest::qWait(100);const auto frame=window->grabWindow();const auto actual=sample(frame,318,350);
        const auto blend=[](int foreground,int background){return qRound((foreground*128+background*127)/255.0);};
        QVERIFY2(qAbs(actual.red()-blend(240,background.red()))<=2,qPrintable(actual.name()));
        QVERIFY2(qAbs(actual.green()-blend(20,background.green()))<=2,qPrintable(actual.name()));
        QVERIFY2(qAbs(actual.blue()-blend(40,background.blue()))<=2,qPrintable(actual.name()));
        QCOMPARE(sample(frame,382,350),transparent);
        QTRY_COMPARE_WITH_TIMEOUT(RasterJobs::statistics().value("running").toInt(),0,10000);QTRY_COMPARE_WITH_TIMEOUT(RasterJobs::statistics().value("queued").toInt(),0,10000);
        const auto jobs=RasterJobs::statistics().value("completed");auto *crop=artworkItem();
        auto draft=entry;auto rect=draft.value("rect").toMap();rect["x"]=rect.value("x").toDouble()+10;draft["rect"]=rect;
        window->setProperty("annotationDraft",draft);QTest::qWait(100);
        QCOMPARE(artworkItem(),crop);QCOMPARE(crop->parentItem()->x(),rect.value("x").toDouble()*window->property("zoom").toDouble());
        QCOMPARE(RasterJobs::statistics().value("completed"),jobs);window->setProperty("annotationDraft",QVariant::fromValue(nullptr));
        window->setProperty("paperAppearance","night");QTest::qWait(100);QVERIFY(!window->grabWindow().isNull());QCOMPARE(RasterJobs::statistics().value("completed"),jobs);
        window->setProperty("paperAppearance","original");
        const auto snapshots=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!snapshots.isEmpty())QVERIFY(window->grabWindow().save(snapshots+"/lyrareader-stamp-signature.png"));
        QVERIFY(reader.signatureImage(QUrl("https://example.invalid/signature.png")).contains("error"));QVERIFY(reader.signatureImage(QUrl::fromLocalFile(path)).contains("error"));
        QVERIFY(QMetaObject::invokeMethod(window,"armStamp",Q_ARG(QVariant,"draft")));QTest::keyClick(window,Qt::Key_Escape);QCOMPARE(window->property("annotationTool").toString(),QString("select"));QCOMPARE(entries().size(),2);
        reader.submit("save_current_annotations",{{"destination",output}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY2(reader.error().isEmpty(),qPrintable(reader.error()));
        QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);
        ReaderController saved;saved.openFile(QUrl::fromLocalFile(output));QTRY_COMPARE_WITH_TIMEOUT(saved.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(saved.pendingCommands(),0,10000);
        const auto file=saved.data().value("annotations").toList();QCOMPARE(file.size(),2);
        int text=0,images=0;for(const auto &value:file){const auto a=value.toMap();QCOMPARE(a.value("kind").toString(),QString("stamp"));const auto stamp=a.value("stamp").toMap();if(!stamp.value("text").toString().isEmpty())++text;if(!stamp.value("image").toString().isEmpty())++images;}
        QCOMPARE(text,1);QCOMPARE(images,1);
        // Reopen into the actual canvas and adopt the PDF-owned image through a click.
        reader.openFile(QUrl::fromLocalFile(output));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
        window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTest::qWait(100);
        QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point(318,350));QTRY_COMPARE_WITH_TIMEOUT(entries().size(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        const auto adopted=entries().first().toMap();QCOMPARE(adopted.value("kind").toString(),QString("signature"));QVERIFY(!adopted.value("fileIdentity").toString().isEmpty());
        const auto oldX=adopted.value("rect").toMap().value("x").toDouble();
        QTest::keyClick(window,Qt::Key_Right);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(entries().first().toMap().value("rect").toMap().value("x").toDouble(),oldX+1);
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(entries().first().toMap().value("rect").toMap().value("x").toDouble(),oldX);
        reader.submit("marks_redo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,entries().first()),Q_ARG(QVariant,true)));
        QTRY_VERIFY(window->findChild<QObject *>("annotationNoteText")->property("readOnly").toBool());
        const auto edited=scratch.path()+"/edited.pdf";reader.submit("save_current_annotations",{{"destination",edited}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY2(reader.error().isEmpty(),qPrintable(reader.error()));
        saved.openFile(QUrl::fromLocalFile(edited));QTRY_COMPARE_WITH_TIMEOUT(saved.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(saved.pendingCommands(),0,10000);QCOMPARE(saved.data().value("annotations").toList().size(),2);
    }
    void partialInkErasurePreviewsCutsCancelsAndProtectsPdfReviewThreads() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/ink.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        const auto ready=[&]{auto *page=visualItem(window->contentItem(),"pdfPage0");return page && page->property("texturesReady").toBool();};
        const auto point=[&](double x,double y){return visualItem(window->contentItem(),"pdfPage0")->mapToScene(QPointF(x,y)).toPoint();};
        const auto state=[&]{return reader.data().value("marks").toMap();};const auto entries=[&]{return state().value("annotations").toList();};
        const auto listProperty=[&](const char *name){const auto value=window->property(name);return value.metaType()==QMetaType::fromType<QJSValue>() ? value.value<QJSValue>().toVariant().toList() : value.toList();};
        const auto preview=[&]{return listProperty("erasePreview");};
        const auto hidden=[&]{return listProperty("eraseDraft");};
        const auto idle=[&]{return reader.pendingCommands()==0 && window->property("eraserToken").toString().isEmpty();};
        reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTRY_VERIFY_WITH_TIMEOUT(ready(),10000);
        window->setProperty("fitting",false);window->setProperty("paperAppearance","original");QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTest::qWait(100);
        reader.submit("mark_create",{{"entry",QVariantMap{{"kind","ink"},{"page",0},{"version",1},{"paths",QVariantList{QVariantList{QVariantMap{{"x",100},{"y",350}},QVariantMap{{"x",150},{"y",350}},QVariantMap{{"x",250},{"y",350}},QVariantMap{{"x",300},{"y",350}}}}},{"strokeWidth",2},{"color","#1B7F3BFF"},{"note","preserve ink note"}}}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(entries().size(),1);
        const auto before=entries().first();QFile sidecar(reader.data().value("marks").toMap().value("path").toString());QVERIFY(sidecar.open(QIODevice::ReadOnly));const auto baseline=sidecar.readAll();sidecar.close();
        window->setProperty("annotationTool","eraser");QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(200,320));QTest::mouseMove(window,point(200,380),30);
        QTRY_COMPARE_WITH_TIMEOUT(preview().size(),2,10000);QCOMPARE(hidden().size(),1);QCOMPARE(entries().first(),before);
        QVERIFY(sidecar.open(QIODevice::ReadOnly));QCOMPARE(sidecar.readAll(),baseline);sidecar.close();
        QImage frame;
        const auto pixel=[&](double x,double y){const auto p=point(x,y);return frame.pixelColor(qRound(p.x()*frame.width()/double(window->width())),qRound(p.y()*frame.height()/double(window->height())));};
        // The preview model can arrive before Canvas paints into the native scene.
        // Wait for the actual clipped pixels, not merely the model or a fixed delay.
        QElapsedTimer previewPaint;previewPaint.start();int frameSamples=0;
        const auto previewPainted=[&]{++frameSamples;frame=window->grabWindow();if(frame.isNull())return false;const auto gap=pixel(200,350),left=pixel(140,350);return gap.red()>245 && gap.green()>245 && gap.blue()>245 && left.green()>left.red()+30;};
        QTRY_VERIFY_WITH_TIMEOUT(previewPainted(),5000);
        qInfo()<<"Ink preview pixels observed after"<<previewPaint.elapsed()<<"ms in"<<frameSamples<<"samples";
        const auto gap=pixel(200,350),left=pixel(140,350);QVERIFY2(gap.red()>245 && gap.green()>245 && gap.blue()>245,qPrintable(gap.name()));QVERIFY2(left.green()>left.red()+30,qPrintable(left.name()));
        QTest::mouseMove(window,point(270,380),30);QTest::mouseMove(window,point(270,320),30);QTRY_COMPARE_WITH_TIMEOUT(preview().size(),3,10000);
        const auto expected=preview();QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(270,320));QTRY_VERIFY_WITH_TIMEOUT(idle(),10000);QCOMPARE(entries().size(),3);
        for(int i=0;i<3;++i){QCOMPARE(entries()[i].toMap().value("paths"),expected[i].toMap().value("paths"));QCOMPARE(entries()[i].toMap().value("note").toString(),QString("preserve ink note"));}
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(entries(),QVariantList{before});QVERIFY(state().value("can_redo").toBool());
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(200,320));QTest::mouseMove(window,point(200,380),30);QTRY_COMPARE_WITH_TIMEOUT(preview().size(),2,10000);QTest::keyClick(window,Qt::Key_Escape);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(200,380));QTRY_VERIFY_WITH_TIMEOUT(idle(),10000);QCOMPARE(entries(),QVariantList{before});QVERIFY(state().value("can_redo").toBool());QVERIFY(preview().isEmpty());
        window->setProperty("annotationTool","eraser");QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(200,320));QTest::mouseMove(window,point(200,380),30);QTRY_COMPARE_WITH_TIMEOUT(preview().size(),2,10000);window->setProperty("annotationTool","select");QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(200,380));QTRY_VERIFY_WITH_TIMEOUT(idle(),10000);QCOMPARE(entries(),QVariantList{before});
        QVERIFY(sidecar.open(QIODevice::ReadOnly));QCOMPARE(sidecar.readAll(),baseline);sidecar.close();QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);source.close();
        const auto reviewPath=scratch.path()+"/review.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/annotated-ink-review.pdf",reviewPath));reader.openFile(QUrl::fromLocalFile(reviewPath));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTRY_VERIFY_WITH_TIMEOUT(ready(),10000);
        window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTest::qWait(100);
        window->setProperty("annotationTool","eraser");QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(250,50));QTest::mouseMove(window,point(250,380),30);QTRY_COMPARE_WITH_TIMEOUT(hidden().size(),1,10000);QCOMPARE(hidden().first().toString(),QString("nm:review-ink-bare"));QCOMPARE(preview().size(),2);QVERIFY(window->property("operationStatus").toString().contains("Protected PDF ink"));
        const auto snapshots=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!snapshots.isEmpty())QVERIFY(window->grabWindow().save(snapshots+"/lyrareader-partial-ink-preview.png"));
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(250,380));QTRY_VERIFY_WITH_TIMEOUT(idle(),10000);QCOMPARE(entries().size(),2);QCOMPARE(state().value("pending_deletions").toInt(),1);QVERIFY(window->property("operationStatus").toString().contains("protected PDF ink"));
        const auto file=state().value("file_annotations").toList();QCOMPARE(file.size(),3);int replies=0;for(const auto &value:file){const auto a=value.toMap();if(a.value("is_reply").toBool()){++replies;QVERIFY(!a.value("visible").toBool());}}
        QCOMPARE(replies,2);
        // Reopening restores the deletion and its pieces together; explicit discard removes both.
        ReaderController discarded;discarded.openFile(QUrl::fromLocalFile(reviewPath));QTRY_COMPARE_WITH_TIMEOUT(discarded.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(discarded.pendingCommands(),0,10000);QCOMPARE(discarded.data().value("marks").toMap().value("annotations").toList().size(),2);QCOMPARE(discarded.data().value("marks").toMap().value("pending_deletions").toInt(),1);QCOMPARE(discarded.data().value("marks").toMap().value("file_annotations").toList().size(),3);QCOMPARE(discarded.data().value("annotations").toList().size(),4);
        const auto output=scratch.path()+"/cut.pdf";reader.submit("save_current_annotations",{{"destination",output}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY2(reader.error().isEmpty(),qPrintable(reader.error()));
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(output));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QCOMPARE(reopened.data().value("annotations").toList().size(),5);
    }
    void partialInkErasureCrossesPageGapsInOneUndo_data() {
        QTest::addColumn<bool>("facing");QTest::newRow("facing")<<true;QTest::newRow("continuous")<<false;
    }
    void partialInkErasureCrossesPageGapsInOneUndo() {
        QFETCH(bool,facing);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/pages.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
        window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,facing ? "Facing" : "Continuous")));QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,facing ? .5 : .25),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTest::qWait(150);
        QTRY_VERIFY(visualItem(window->contentItem(),"pdfPage1"));
        const auto point=[&](int index,double x,double y){return visualItem(window->contentItem(),QString("pdfPage%1").arg(index))->mapToScene(QPointF(x*window->property("zoom").toDouble(),y*window->property("zoom").toDouble())).toPoint();};
        const auto entries=[&]{return reader.data().value("marks").toMap().value("annotations").toList();};
        const auto list=[&](const char *name){const auto v=window->property(name);return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant().toList():v.toList();};
        for(int i=0;i<2;++i)reader.submit("mark_create",{{"entry",QVariantMap{{"kind","ink"},{"page",i},{"version",1},{"paths",QVariantList{QVariantList{QVariantMap{{"x",i ? 20 : 400},{"y",200}},QVariantMap{{"x",i ? 180 : 580},{"y",200}}}}},{"strokeWidth",2},{"color","#1B7F3BFF"},{"note",""}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(entries().size(),2);const auto before=entries();
        window->setProperty("annotationTool","eraser");QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(0,500,200));QTest::mouseMove(window,point(1,100,200),30);
        QTRY_COMPARE_WITH_TIMEOUT(list("eraseDraft").size(),2,10000);const auto expected=list("erasePreview");QVERIFY(expected.size()>=2);QCOMPARE(entries(),before);
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(1,100,200));QTRY_VERIFY_WITH_TIMEOUT(window->property("eraserToken").toString().isEmpty() && reader.pendingCommands()==0,10000);
        QCOMPARE(entries().size(),expected.size());for(int i=0;i<expected.size();++i){QCOMPARE(entries()[i].toMap().value("page"),expected[i].toMap().value("page"));QCOMPARE(entries()[i].toMap().value("paths"),expected[i].toMap().value("paths"));}
        reader.submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(entries(),before);
        reader.submit("marks_redo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QCOMPARE(entries().size(),expected.size());QVERIFY2(reader.error().isEmpty(),qPrintable(reader.error()));
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
        auto *note=window->findChild<QQuickItem *>("annotationNoteBody");QVERIFY(note);QTRY_VERIFY(note->isVisible());QVERIFY(note->property("readOnly").toBool());QCOMPARE(note->property("text").toString(),reply.toMap().value("note").toString());
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(reader.data().value("marks").toMap().value("annotations").toList().isEmpty());
        auto *paper=window->findChild<QObject *>("annotationNotePaperController");QVERIFY(paper);QVERIFY(QMetaObject::invokeMethod(paper,"close"));
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
    void annotationRedactionIsRetiredAndCannotWriteTheSource() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/source.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto bytes=original.readAll();original.close();
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(!window->property("canRedact").toBool());
        for(const auto &op:{"preview_redactions","save_redactions","replace_redactions"}){reader.submit(op,{{"destination",scratch.path()+"/refused.pdf"},{"areas",QVariantList{}}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(reader.error().contains("retired"));reader.dismissError();QVERIFY(!QFile::exists(scratch.path()+"/refused.pdf"));}
        QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),bytes);
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
        const auto reveal=[&](QQuickItem *item){const auto center=item->mapToItem(view,QPointF(item->width()/2,item->height()/2));const double target=view->property("contentY").toDouble()+center.y()-view->height()/2;const double origin=view->property("originY").toDouble();view->setProperty("contentY",origin+reader->clampScroll(target-origin,view->property("contentHeight").toDouble(),view->height()));QTest::qWait(50);};
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
    void aiDockIsIndependentResizableAndKeepsDraftsWhenClosed() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/dock.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        WorkspaceController workspace;auto *reader=workspace.activeReader();QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"bookmarks")));QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"ai")));
        auto *dock=visualItem(window->contentItem(),"aiDock"),*left=visualItem(window->contentItem(),"readerSidebar"),*view=visualItem(window->contentItem(),"pageList");QVERIFY(dock && left && view);QTRY_VERIFY(dock->isVisible());
        QCOMPARE(window->property("sidebarTab").toString(),QStringLiteral("bookmarks"));
        if(window->width()>=1100)QVERIFY(left->isVisible());
        QTRY_VERIFY(dock->mapToScene(QPointF()).x()>=view->mapToScene(QPointF(view->width(),0)).x()-1);
        reader->setAiInput("action",2);reader->setAiInput("question",QStringLiteral("Draft kept while reading"));
        const auto evidence=qEnvironmentVariable("LYRA_READER_AI_EVIDENCE_DIR");
        if(!evidence.isEmpty()){QVERIFY(QDir().mkpath(evidence));QTest::qWait(100);QVERIFY(window->grabWindow().save(evidence+"/ai-dock-wide.png"));}
        auto *panel=window->findChild<QObject *>("aiPanel");QVERIFY(panel);auto *close=window->findChild<QObject *>("closeAiPanel");QVERIFY(close);QVERIFY(QMetaObject::invokeMethod(close,"clicked"));QTRY_VERIFY(!dock->isVisible());
        QCOMPARE(reader->aiState().value("input").toMap().value("question").toString(),QStringLiteral("Draft kept while reading"));
        QVERIFY(QMetaObject::invokeMethod(window,"showAiPanel",Q_ARG(QVariant,true)));QTRY_VERIFY(dock->isVisible());QCOMPARE(window->findChild<QObject *>("aiPanel"),panel);
        QVERIFY(QMetaObject::invokeMethod(window,"resizeAiPanel",Q_ARG(QVariant,360),Q_ARG(QVariant,true)));auto *handle=visualItem(window->contentItem(),"aiPanelResizeHandle");QVERIFY(handle);
        const auto grip=handle->mapToScene(QPointF(3,40)).toPoint();
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,grip);QTest::mouseMove(window,grip-QPoint(40,0),30);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,grip-QPoint(40,0));
        QTRY_COMPARE(window->property("aiPanelWidth").toInt(),400);QCOMPARE(workspace.preference("aiPanelWidth").toInt(),400);
        QVERIFY(QMetaObject::invokeMethod(window,"resizeAiPanel",Q_ARG(QVariant,360),Q_ARG(QVariant,true)));
        handle->forceActiveFocus();QTest::keyClick(window,Qt::Key_Right);QTRY_COMPARE(window->property("aiPanelWidth").toInt(),340);QCOMPARE(workspace.preference("aiPanelWidth").toInt(),340);
        window->resize(700,820);QTest::qWait(50);if(window->width()<1100){QVERIFY(!left->isVisible());QTRY_VERIFY_WITH_TIMEOUT(view->width()>=350,5000);}
        if(!evidence.isEmpty()){QTest::qWait(100);QVERIFY(window->grabWindow().save(evidence+"/ai-dock-narrow.png"));}
        window->setProperty("searchVisible",true);if(window->width()<1200)QTRY_VERIFY(!dock->isVisible());
        QVERIFY(QMetaObject::invokeMethod(window,"showAiPanel",Q_ARG(QVariant,true)));if(window->width()<1200)QVERIFY(!window->property("searchVisible").toBool());
    }
    void optionalDocumentReadingDoesNotBlockQuestionsAndSkipOrStopSendsNoExtraWork() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto previous=qgetenv("LYRA_READER_DOCUMENT_CACHE_DIR");const auto restore=qScopeGuard([&]{qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",previous);});const auto cache=scratch.path()+"/cache";qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());
        MockChatServer server;QVERIFY(server.listen());MockChatServer::Response held;held.holdLast=true;held.chunks={MockChatServer::delta({{"content","PARTIAL_READING_MUST_NOT_BE_CONTEXT"}}),QByteArray("data: [DONE]\n\n")};server.responses.append(held);server.responses.append({{MockChatServer::delta({{"content","Foreground answer while optional reading runs [p.1]"}}),QByteArray("data: [DONE]\n\n")},0,200});
        const auto path=scratch.path()+"/optional.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *reader=view.workspace.activeReader();view.workspace.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(reader->pageCount(),1);QTRY_COMPARE(reader->pendingCommands(),0);
        view.window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","synthetic"}});QVERIFY(QMetaObject::invokeMethod(view.window,"openDocumentReading"));auto *reading=view.window->findChild<QObject *>("documentReadingPopup");QVERIFY(reading);QVERIFY(QMetaObject::invokeMethod(reading,"prepare"));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("preview"));QTRY_COMPARE(reader->pendingCommands(),0);QCOMPARE(server.requests.size(),0);
        auto *skip=view.window->findChild<QObject *>("skipDocumentReading");QVERIFY(skip);QVERIFY(QMetaObject::invokeMethod(skip,"clicked"));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("idle"));QTRY_COMPARE(reader->pendingCommands(),0);QCOMPARE(server.requests.size(),0);
        QVERIFY(QMetaObject::invokeMethod(view.window,"openDocumentReading"));QVERIFY(QMetaObject::invokeMethod(reading,"prepare"));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("preview"));QTRY_COMPARE(reader->pendingCommands(),0);const auto state=reader->documentReading(),plan=state.value("plan").toMap();
        reader->setAiInput("action",0);auto *panel=view.window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE(reader->pendingCommands(),0);const auto foreground=reader->aiState().value("plan").toMap();
        QVERIFY(reader->startDocumentReading("local",plan,state.value("token").toString()));QTRY_COMPARE(server.requests.size(),1);QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("reading"));QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(reader->startAi("local",foreground));QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(server.requests.size(),2);QVERIFY(reader->aiState().value("output").toString().contains("Foreground answer"));QCOMPARE(reader->documentReading().value("phase").toString(),QString("reading"));QVERIFY(!reader->documentReading().value("ready").toBool());
        const auto sent=server.requests[1].mid(server.requests[1].indexOf("\r\n\r\n")+4);QCOMPARE(sent,foreground.value("parts").toList().first().toMap().value("wire_body").toString().toUtf8());QVERIFY(!sent.contains("PARTIAL_READING"));
        const auto other=scratch.path()+"/other-tab.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",other));view.workspace.openFile(QUrl::fromLocalFile(other));QTRY_VERIFY(view.workspace.activeReader()!=reader);QTRY_COMPARE(view.workspace.activeReader()->pageCount(),1);QTRY_COMPARE(view.workspace.activeReader()->pendingCommands(),0);QCOMPARE(reader->documentReading().value("phase").toString(),QString("reading"));QVERIFY(!view.workspace.activeReader()->documentReading().value("ready").toBool());QVERIFY(!reading->property("visible").toBool());
        reader->stopDocumentReading();QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("idle"));QTRY_COMPARE_WITH_TIMEOUT(server.activeConnections(),0,10000);QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(!reader->startDocumentReading("local",plan,state.value("token").toString()));QCOMPARE(server.requests.size(),2);QVERIFY(reader->error().isEmpty());QVERIFY(!reader->hasUnsavedChanges());
        QDirIterator files(cache,{"document-knowledge-v1.json"},QDir::Files,QDirIterator::Subdirectories);QVERIFY(!files.hasNext());
    }
    void documentReadingConsolidatesExactBodiesCachesAndEnrichesOnlyNewPreviews() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto previous=qgetenv("LYRA_READER_DOCUMENT_CACHE_DIR");const auto restore=qScopeGuard([&]{qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",previous);});const auto cache=scratch.path()+"/cache";qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());
        const auto path=scratch.path()+"/synthetic-reading.pdf";
        {QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QPageSize::A4));pdf.setPageMargins(QMarginsF(0,0,0,0));QPainter painter(&pdf);QVERIFY(painter.isActive());painter.setFont(QFont("Sans Serif",8));for(int page=0;page<8;++page){if(page)QVERIFY(pdf.newPage());for(int line=0;line<50;++line)painter.drawText(QPointF(30,36+14*line),QString("PUBLIC_SYNTHETIC_READING_UNIT page %1 line %2: local evidence and bounded requests preserve context.").arg(page+1).arg(line+1));}}
        QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto originalBytes=original.readAll();original.close();MockChatServer server;QVERIFY(server.listen());
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *reader=view.workspace.activeReader();view.workspace.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(reader->pageCount(),8);QTRY_COMPARE(reader->pendingCommands(),0);view.window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","synthetic"}});
        reader->setAiInput("action",0);auto *panel=view.window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE(reader->pendingCommands(),0);const auto frozen=reader->aiState().value("plan").toMap();
        QVERIFY(QMetaObject::invokeMethod(view.window,"openDocumentReading"));auto *reading=view.window->findChild<QObject *>("documentReadingPopup");QVERIFY(reading);QVERIFY(QMetaObject::invokeMethod(reading,"prepare"));QTRY_COMPARE_WITH_TIMEOUT(reader->documentReading().value("phase").toString(),QString("preview"),15000);QTRY_COMPARE(reader->pendingCommands(),0);const auto state=reader->documentReading(),plan=state.value("plan").toMap();const auto parts=plan.value("parts").toList();QVERIFY(parts.size()>1);QCOMPARE(server.requests.size(),0);
        for(qsizetype i=0;i<parts.size();++i)server.responses.append({{MockChatServer::delta({{"content",QString("Synthetic part %1 [p.1]").arg(i+1)}}),QByteArray("data: [DONE]\n\n")},0,200});server.responses.append({{MockChatServer::delta({{"content","COMPLETED_SYNTHETIC_UNDERSTANDING [p.1]"}}),QByteArray("data: [DONE]\n\n")},10,200});
        auto *inspect=view.window->findChild<QObject *>("inspectDocumentReading");QVERIFY(inspect);QVERIFY(QMetaObject::invokeMethod(inspect,"clicked"));auto *payload=view.window->findChild<QObject *>("documentReadingPayload");QVERIFY(payload);QStringList bodies;for(const auto &p:parts)bodies.append(p.toMap().value("wire_body").toString());QCOMPARE(payload->property("body").toString(),bodies.join("\n\n"));QVERIFY(QMetaObject::invokeMethod(payload,"close"));
        auto *start=view.window->findChild<QObject *>("startDocumentReading");QVERIFY(start);QVERIFY(QMetaObject::invokeMethod(start,"clicked"));QTRY_COMPARE_WITH_TIMEOUT(reader->documentReading().value("phase").toString(),QString("ready"),15000);QTRY_COMPARE(reader->pendingCommands(),0);QCOMPARE(server.requests.size(),parts.size()+1);
        for(qsizetype i=0;i<parts.size();++i)QCOMPARE(server.requests[i].mid(server.requests[i].indexOf("\r\n\r\n")+4),bodies[i].toUtf8());const auto merged=reader->documentReading().value("merge_payloads").toStringList();QCOMPARE(merged.size(),1);QCOMPARE(server.requests.last().mid(server.requests.last().indexOf("\r\n\r\n")+4),merged.first().toUtf8());
        QCOMPARE(reader->aiState().value("plan").toMap(),frozen);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().value("plan").toMap()!=frozen);QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(reader->aiState().value("plan").toMap().value("parts").toList().first().toMap().value("wire_body").toString().contains("COMPLETED_SYNTHETIC_UNDERSTANDING"));
        reader->setAiInput("action",3);reader->setAiInput("language","French");view.window->setProperty("selection",QVariantMap{{"page",0},{"start",0},{"end",3}});QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().value("plan").toMap().value("action").toString()=="TranslateSelection");QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(!reader->aiState().value("plan").toMap().value("parts").toList().first().toMap().value("wire_body").toString().contains("COMPLETED_SYNTHETIC_UNDERSTANDING"));
        QDirIterator files(cache,{"document-knowledge-v1.json"},QDir::Files,QDirIterator::Subdirectories);QVERIFY(files.hasNext());const auto cachePath=files.next();QVERIFY(!files.hasNext());QFile saved(cachePath);QVERIFY(saved.open(QIODevice::ReadOnly));const auto bytes=saved.readAll();saved.close();const auto record=QJsonDocument::fromJson(bytes).object();QCOMPARE(record.value("summary").toString(),QString("COMPLETED_SYNTHETIC_UNDERSTANDING [p.1]"));QCOMPARE(record.value("pages").toArray().size(),8);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(reader->error().isEmpty());
        const auto auditPath=cache+"/Audit/ai-requests.jsonl";QFile audit(auditPath);QVERIFY(audit.open(QIODevice::ReadOnly));const auto metadata=audit.readAll();QCOMPARE(metadata.trimmed().split('\n').size(),parts.size()+1);QVERIFY(!metadata.contains("PUBLIC_SYNTHETIC_READING_UNIT"));QVERIFY(!metadata.contains("COMPLETED_SYNTHETIC"));QVERIFY(!metadata.contains("synthetic-reading.pdf"));
        reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(reader->pageCount(),8);QTRY_COMPARE(reader->pendingCommands(),0);QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("ready"));QVERIFY(reader->documentReading().value("plan").toMap().isEmpty());QCOMPARE(server.requests.size(),parts.size()+1);QVERIFY(saved.open(QIODevice::ReadOnly));QCOMPARE(saved.readAll(),bytes);saved.close();QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),originalBytes);
    }
    void documentReadingFailureRetrySettingsAndReopenKeepTheReaderUsable() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto previous=qgetenv("LYRA_READER_DOCUMENT_CACHE_DIR");const auto restore=qScopeGuard([&]{qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",previous);});const auto cache=scratch.path()+"/cache";qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());
        MockChatServer server;QVERIFY(server.listen());server.responses.append({{QByteArray("{\"error\":{\"message\":\"synthetic reading failure\"}}")},0,400});MockChatServer::Response held;held.holdLast=true;held.chunks={MockChatServer::delta({{"content","Late reading must not revive after reopen"}}),QByteArray("data: [DONE]\n\n")};server.responses.append(held);
        const auto path=scratch.path()+"/reading-reopen.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *reader=view.workspace.activeReader();view.workspace.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(reader->pageCount(),1);QTRY_COMPARE(reader->pendingCommands(),0);view.window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","synthetic"}});QVERIFY(QMetaObject::invokeMethod(view.window,"openDocumentReading"));auto *reading=view.window->findChild<QObject *>("documentReadingPopup");QVERIFY(reading);QVERIFY(QMetaObject::invokeMethod(reading,"prepare"));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("preview"));QTRY_COMPARE(reader->pendingCommands(),0);auto state=reader->documentReading();QVERIFY(reader->startDocumentReading("local",state.value("plan").toMap(),state.value("token").toString()));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("failed"));QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(reader->error().isEmpty());QVERIFY(!reader->hasUnsavedChanges());
        const auto evidence=qEnvironmentVariable("LYRA_READER_AI_EVIDENCE_DIR");if(!evidence.isEmpty()){QVERIFY(QDir().mkpath(evidence));view.window->setProperty("appearance","dark");view.window->resize(380,600);QTest::qWait(100);QVERIFY(view.window->grabWindow().save(evidence+"/reading-failure-dark-narrow.png"));}
        QVERIFY(QMetaObject::invokeMethod(reading,"prepare"));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("preview"));QTRY_COMPARE(reader->pendingCommands(),0);state=reader->documentReading();view.window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","changed"}});QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("idle"));QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(!reader->startDocumentReading("local",state.value("plan").toMap(),state.value("token").toString()));QCOMPARE(server.requests.size(),1);
        QVERIFY(QMetaObject::invokeMethod(reading,"prepare"));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("preview"));QTRY_COMPARE(reader->pendingCommands(),0);state=reader->documentReading();QVERIFY(reader->startDocumentReading("local",state.value("plan").toMap(),state.value("token").toString()));QTRY_COMPARE(server.requests.size(),2);QTRY_COMPARE_WITH_TIMEOUT(server.activeConnections(),1,10000);reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(reader->pageCount(),1);QTRY_COMPARE(reader->pendingCommands(),0);QTRY_COMPARE_WITH_TIMEOUT(server.activeConnections(),0,10000);QCOMPARE(reader->documentReading().value("phase").toString(),QString("idle"));QVERIFY(!reader->documentReading().value("ready").toBool());QVERIFY(reader->error().isEmpty());QVERIFY(!reading->property("visible").toBool());
        QDirIterator files(cache,{"document-knowledge-v1.json"},QDir::Files,QDirIterator::Subdirectories);QVERIFY(!files.hasNext());
    }
    void documentReadingPopupKeyboardAndNarrowPayloadStayLocal_data() {
        QTest::addColumn<QString>("theme");QTest::newRow("light")<<QString("light");QTest::newRow("dark")<<QString("dark");
    }
    void documentReadingPopupKeyboardAndNarrowPayloadStayLocal() {
        QFETCH(QString,theme);MockChatServer server;QVERIFY(server.listen());QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/reading-keyboard.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);QSignalSpy qmlWarnings(&view.engine,&QQmlEngine::warnings);auto *window=view.window;window->setProperty("appearance",theme);auto *reader=view.workspace.activeReader();view.workspace.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(reader->pageCount(),1);QTRY_COMPARE(reader->pendingCommands(),0);
        window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","synthetic"}});const QVariantMap selection{{"page",0},{"start",0},{"end",3}};window->setProperty("selection",selection);
        auto *panel=window->findChild<QObject *>("aiPanel");QVERIFY(panel);reader->setAiInput("action",3);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().value("plan").toMap().value("action").toString()=="TranslateSelection");QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(!reader->documentReading().value("choice_pending").toBool());
        reader->setAiInput("action",0);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().value("plan").toMap().value("action").toString()=="SummarizePage");QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(reader->documentReading().value("choice_pending").toBool());auto *skip=view.window->findChild<QObject *>("skipDocumentReadingChoice");QVERIFY(skip);QVERIFY(QMetaObject::invokeMethod(skip,"clicked"));QVERIFY(!reader->documentReading().value("choice_pending").toBool());QCOMPARE(server.requests.size(),0);
        QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(!reader->documentReading().value("choice_pending").toBool());window->requestActivate();QTRY_COMPARE(QGuiApplication::focusWindow(),window);QTest::keyClick(window,Qt::Key_K,Qt::ControlModifier|Qt::ShiftModifier);auto *reading=window->findChild<QObject *>("documentReadingPopup");QVERIFY(reading);QTRY_VERIFY(reading->property("visible").toBool());QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY(!reading->property("visible").toBool());QCOMPARE(window->property("selection").toMap(),selection);QCOMPARE(server.requests.size(),0);
        QVERIFY(QMetaObject::invokeMethod(window,"openDocumentReading"));QVERIFY(QMetaObject::invokeMethod(reading,"prepare"));QTRY_COMPARE(reader->documentReading().value("phase").toString(),QString("preview"));QTRY_COMPARE(reader->pendingCommands(),0);auto *inspect=window->findChild<QObject *>("inspectDocumentReading");QVERIFY(inspect);QVERIFY(QMetaObject::invokeMethod(inspect,"clicked"));auto *payload=window->findChild<QObject *>("documentReadingPayload");QVERIFY(payload);QTRY_VERIFY(payload->property("visible").toBool());QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY(!payload->property("visible").toBool());QVERIFY(reading->property("visible").toBool());QCOMPARE(window->property("selection").toMap(),selection);
        window->resize(380,600);QTest::qWait(100);QVERIFY(reading->property("width").toDouble()<=window->width()-20);QVERIFY(reading->property("height").toDouble()<=window->height()-40);const auto evidenceBase=qEnvironmentVariable("LYRA_READER_AI_EVIDENCE_DIR");const auto evidence=evidenceBase.isEmpty()?QString():evidenceBase+"/"+theme;if(!evidence.isEmpty()){QVERIFY(QDir().mkpath(evidence));QVERIFY(window->grabWindow().save(evidence+"/reading-preview-light-narrow.png"));}QCOMPARE(server.requests.size(),0);reader->stopDocumentReading();QTRY_COMPARE(reader->pendingCommands(),0);
        auto *notice=window->findChild<QObject *>("flattenExportNotice");QVERIFY(notice);
        QVariantList metrics;
        const auto record=[&](const QString &phase) {
            QVariantMap row{{"phase",phase},{"windowWidth",window->width()},{"windowHeight",window->height()}};
            for(const auto *key:{"width","height","implicitWidth","implicitHeight","contentWidth","contentHeight","availableWidth","availableHeight","implicitContentWidth","implicitContentHeight","implicitHeaderHeight","implicitFooterHeight","implicitBackgroundHeight","topPadding","bottomPadding","topInset","bottomInset","spacing","visible"})row.insert(QString::fromLatin1(key),notice->property(key));
            for(const auto *key:{"header","footer","contentItem"})if(auto *item=notice->property(key).value<QQuickItem *>()) {
                QVariantMap sizes{{"type",QString::fromLatin1(item->metaObject()->className())},{"width",item->width()},{"height",item->height()},{"implicitWidth",item->implicitWidth()},{"implicitHeight",item->implicitHeight()},{"visible",item->isVisible()}};
                QVariantList children;for(auto *child:item->childItems())children.append(QVariantMap{{"type",QString::fromLatin1(child->metaObject()->className())},{"x",child->x()},{"y",child->y()},{"width",child->width()},{"height",child->height()},{"implicitHeight",child->implicitHeight()}});sizes.insert("children",children);row.insert(QString::fromLatin1(key),sizes);
            }
            metrics.append(row);qInfo()<<"Flatten intrinsic metrics"<<QJsonDocument::fromVariant(row).toJson(QJsonDocument::Compact);
        };
        record("closed-after-reading-popup");
        QVERIFY(QMetaObject::invokeMethod(reading,"close"));QTRY_VERIFY(!reading->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(notice,"open"));QTRY_VERIFY(notice->property("visible").toBool());QTest::qWait(160);record("open-narrow");
        auto *body=notice->property("contentItem").value<QQuickItem *>();auto *background=notice->property("background").value<QQuickItem *>();auto *header=notice->property("header").value<QQuickItem *>();auto *footer=notice->property("footer").value<QQuickItem *>();QVERIFY(body && background && header && footer);
        const auto validateFrame=[&] {
            const auto frame=background->mapRectToScene(background->boundingRect()).adjusted(-1,-1,1,1);
            const auto content=body->mapRectToScene(body->childrenRect());const auto title=header->mapRectToScene(header->boundingRect()),buttons=footer->mapRectToScene(footer->boundingRect());
            return frame.contains(content) && frame.contains(title) && frame.contains(buttons) && title.bottom()<=content.top()+1 && content.bottom()<=buttons.top()+1;
        };
        QVERIFY2(validateFrame(),"The complete paragraph, title and buttons must fit without overlap");
        if(!evidence.isEmpty())QVERIFY(window->grabWindow().save(evidence+"/flatten-original-narrow.png"));
        window->resize(1100,760);QVERIFY(settleReaderViewport(window));QTest::qWait(100);record("open-wide");QVERIFY(validateFrame());
        if(!evidence.isEmpty()){QVERIFY(window->grabWindow().save(evidence+"/flatten-original-wide.png"));QFile output(evidence+"/flatten-metrics.json");QVERIFY(output.open(QIODevice::WriteOnly));QVERIFY(output.write(QJsonDocument::fromVariant(metrics).toJson())>0);}
        QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY(!notice->property("visible").toBool());QCOMPARE(window->property("selection").toMap(),selection);
        QVERIFY(!reader->hasUnsavedChanges());QCOMPARE(server.requests.size(),0);
        const auto loops=qmlBindingLoops(qmlWarnings);QVERIFY2(loops.isEmpty(),qPrintable(loops.join("\n")));

    }
    void documentQuestionUsesRetrievedSourcesAndRejectsUnsentCitations() {
        MockChatServer server;QVERIFY(server.listen());server.responses.append({{MockChatServer::delta({{"content","Document answer [p.1], invented [p.99], invalid [p.0]."}}),MockChatServer::usage(),QByteArray("data: [DONE]\n\n")},20,200});
        QTemporaryDir scratch;const auto path=scratch.path()+"/question.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        WorkspaceController workspace;auto *reader=workspace.activeReader();QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","fixture"}});reader->setAiInput("action",4);reader->setAiInput("question",QStringLiteral("Which page contains body text and caching?"));
        auto *panel=window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY2_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),qPrintable(reader->aiState().value("status").toString()),10000);const auto plan=reader->aiState().value("plan").toMap();QCOMPARE(plan.value("action").toString(),QStringLiteral("DocumentChat"));const auto sources=plan.value("sources").toList();QVERIFY(!sources.isEmpty());QCOMPARE(server.requests.size(),0);
        const auto wireBody=plan.value("parts").toList().first().toMap().value("wire_body").toString().toUtf8();QVERIFY(!wireBody.isEmpty());
        auto *payload=window->findChild<QObject *>("aiWirePayload");QVERIFY(payload);QCOMPARE(payload->property("text").toString().toUtf8(),wireBody);
        QVERIFY(reader->startAi("local",plan));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(reader->aiState().value("output").toString().contains("Document answer"));QTRY_VERIFY(window->findChild<QObject *>("aiAnswerText"));QVERIFY(!window->findChild<QObject *>("aiAnswerText")->property("text").toString().contains("href=\"p.99"));
        QCOMPARE(server.requests.size(),1);const auto sent=server.requests.first();const auto headerEnd=sent.indexOf("\r\n\r\n");QVERIFY(headerEnd>=0);QCOMPARE(sent.mid(headerEnd+4),wireBody);
        reader->setAiInput("question",QStringLiteral("A changed question"));QVERIFY(!reader->aiState().contains("plan"));
        const int page=sources.first().toMap().value("page").toInt();QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QString("p.%1").arg(page))));QTRY_COMPARE(window->property("currentPage").toInt(),page-1);
        QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QStringLiteral("p.99"))));QVERIFY(window->property("operationStatus").toString().contains("cannot be verified"));QCOMPARE(window->property("currentPage").toInt(),page-1);
        QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QStringLiteral("p.0"))));QCOMPARE(window->property("currentPage").toInt(),page-1);
    }
    void documentChatKeepsBoundedCompletedAndCancelledHistoryButExcludesFailures() {
        MockChatServer server;QVERIFY(server.listen());
        for(int i=0;i<7;++i)server.responses.append({{MockChatServer::delta({{"content",QString("Synthetic answer %1 [p.1]").arg(i)}}),QByteArray("data: [DONE]\n\n")},0,200});
        MockChatServer::Response partial;partial.holdLast=true;partial.chunks={MockChatServer::delta({{"content","Synthetic cancelled partial"}}),QByteArray("data: [DONE]\n\n")};server.responses.append(partial);
        server.responses.append({{QByteArray("{\"error\":{\"message\":\"synthetic failure\"}}")},0,400});
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/chat-history.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const int limit=reader->data().value("ai_history_limit").toInt();QVERIFY(limit>0);
        view.window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","fixture"}});reader->setAiInput("action",4);auto *panel=view.window->findChild<QObject *>("aiPanel");QVERIFY(panel);
        const auto prepare=[&](const QString &question){reader->setAiInput("question",question);return QMetaObject::invokeMethod(panel,"prepare");};
        for(int i=0;i<7;++i) {
            QVERIFY(prepare(QString("Which page contains body text and caching? turn%1").arg(i)));QTRY_VERIFY_WITH_TIMEOUT(reader->aiState().contains("plan"),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
            const auto plan=reader->aiState().value("plan").toMap();QCOMPARE(plan.value("history_turns").toInt(),qMin(i,limit));QCOMPARE(server.requests.size(),i);
            const auto body=plan.value("parts").toList().first().toMap().value("wire_body").toString().toUtf8();QVERIFY(reader->startAi("local",plan));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);
            QCOMPARE(reader->aiState().value("chatTurns").toList().size(),qMin(i+1,limit));QCOMPARE(reader->aiState().value("chatTurns").toList().last().toMap().value("state").toString(),QString("finished"));
            QCOMPARE(server.requests[i].mid(server.requests[i].indexOf("\r\n\r\n")+4),body);if(i)QVERIFY(body.contains("Synthetic answer"));
        }
        QVERIFY(prepare("Which page contains body text? CANCEL_QUESTION"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->startAi("local",reader->aiState().value("plan").toMap()));QTRY_VERIFY(reader->aiState().value("output").toString().contains("cancelled partial"));reader->cancelAi();QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(reader->aiState().value("chatTurns").toList().last().toMap().value("state").toString(),QString("cancelled"));
        QVERIFY(prepare("Which page contains body text? FAIL_QUESTION_ONLY"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);auto plan=reader->aiState().value("plan").toMap();QVERIFY(plan.value("parts").toList().first().toMap().value("wire_body").toString().contains("Synthetic cancelled partial"));QVERIFY(reader->startAi("local",plan));QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(reader->aiState().value("chatTurns").toList().last().toMap().value("state").toString(),QString("failed"));
        QVERIFY(prepare("Which page contains body text? NEXT_QUESTION"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);plan=reader->aiState().value("plan").toMap();QVERIFY(!plan.value("parts").toList().first().toMap().value("wire_body").toString().contains("FAIL_QUESTION_ONLY"));QCOMPARE(server.requests.size(),9);
        QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));QTRY_VERIFY(visualItem(view.window->contentItem(),"aiConversationHistory")->isVisible());
        auto *retry=visualItem(view.window->contentItem(),"retryAiRequest");auto *panelItem=qobject_cast<QQuickItem *>(panel);QVERIFY(retry && panelItem);
        QTRY_VERIFY(retry->mapRectToItem(panelItem,retry->boundingRect()).bottom()<=panelItem->height());
        auto *answer=visualItem(view.window->contentItem(),"aiHistoryAnswer0");QVERIFY(answer);QVERIFY(answer->property("text").toString().contains("Synthetic answer"));
        const auto capture=qEnvironmentVariable("LYRA_READER_AI_HISTORY_SNAPSHOT");if(!capture.isEmpty()){QTest::qWait(80);QVERIFY(view.window->grabWindow().save(capture));}
        const auto oldest=reader->aiState().value("chatTurns").toList().first().toMap();const auto source=oldest.value("sources").toList().first().toMap();
        const QVariant historicalPlan=QVariantMap{{"action","DocumentChat"},{"sources",oldest.value("sources")},{"generation",oldest.value("generation")}};
        QVERIFY(QMetaObject::invokeMethod(panel,"followHistoryLink",Q_ARG(QVariant,QString("p.%1").arg(source.value("page").toInt())),Q_ARG(QVariant,historicalPlan)));QTRY_COMPARE(view.window->property("currentPage").toInt(),source.value("page").toInt()-1);
        const auto turns=reader->aiState().value("chatTurns").toList();view.workspace.newTab();QVERIFY(view.workspace.activeReader()->aiState().value("chatTurns").toList().isEmpty());view.workspace.selectTab(0);QCOMPARE(reader->aiState().value("chatTurns").toList(),turns);
        reader->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",1}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(reader->aiState().value("chatTurns").toList().isEmpty());QCOMPARE(reader->data().value("ai_history_limit").toInt(),limit);
        const auto currentPage=view.window->property("currentPage").toInt();QVERIFY(QMetaObject::invokeMethod(panel,"followHistoryLink",Q_ARG(QVariant,QString("p.2")),Q_ARG(QVariant,historicalPlan)));QCOMPARE(view.window->property("currentPage").toInt(),currentPage);QVERIFY(view.window->property("operationStatus").toString().contains("document changed"));
    }
    void aiWorkspacesKeepIndependentDraftsResultsAndExactPreviews() {
        MockChatServer server;QVERIFY(server.listen());
        for(const auto &answer:{"Synthetic summary", "Synthetic translation [p.2]", "Synthetic selected text [p.1] [p.2]", "Synthetic chat [p.1]"})server.responses.append({{MockChatServer::delta({{"content",answer}}),QByteArray("data: [DONE]\n\n")},30,200});
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/workspaces.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        view.window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","fixture"}});QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));auto *panel=view.window->findChild<QObject *>("aiPanel");QVERIFY(panel);
        QCOMPARE(panel->property("action").toInt(),1); // Document summary is the normal summary target.
        reader->setAiInput("action",0);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto plan=reader->aiState().value("plan").toMap();QCOMPARE(plan.value("action").toString(),QString("SummarizePage"));QVERIFY(reader->startAi("local",plan));
        reader->setAiInput("view","translation");reader->setAiInput("language","Spanish");QVERIFY(QMetaObject::invokeMethod(panel,"prepare")); // No second job while another view streams.
        QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(server.requests.size(),1);QCOMPARE(panel->property("result").toMap().value("output").toString(),QString());
        reader->setAiInput("view","summary");QVERIFY(panel->property("result").toMap().value("output").toString().contains("Synthetic summary"));auto saved=reader->aiState().value("results").toMap().value("summary").toMap();QVERIFY(!saved.isEmpty());
        reader->setAiInput("action",2);reader->setAiInput("question","Selection-only draft");reader->setAiInput("view","chat");reader->setAiInput("question","Which page contains body text and caching?");reader->setAiInput("view","summary");QCOMPARE(reader->aiState().value("input").toMap().value("question").toString(),QString("Selection-only draft"));
        reader->setAiInput("view","translation");QCOMPARE(reader->aiState().value("input").toMap().value("language").toString(),QString("Spanish"));view.window->setProperty("selection",QVariantMap{{"page",0},{"start",0},{"end",3}});
        QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);plan=reader->aiState().value("plan").toMap();QCOMPARE(plan.value("action").toString(),QString("TranslateSelection"));const auto body=plan.value("parts").toList().first().toMap().value("wire_body").toString().toUtf8();QVERIFY(body.contains("Spanish"));
        reader->setAiInput("view","chat");QVERIFY(panel->property("plan").toMap().isEmpty());QCOMPARE(reader->aiState().value("input").toMap().value("question").toString(),QString("Which page contains body text and caching?"));reader->setAiInput("view","translation");QCOMPARE(panel->property("plan").toMap(),plan);QCOMPARE(server.requests.size(),1);
        QVERIFY(reader->startAi("local",plan));QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(server.requests.size(),2);QCOMPARE(server.requests[1].mid(server.requests[1].indexOf("\r\n\r\n")+4),body);QVERIFY(panel->property("result").toMap().value("output").toString().contains("Synthetic translation"));auto *translationAnswer=view.window->findChild<QObject *>("aiAnswerText");QVERIFY(translationAnswer);QVERIFY(!translationAnswer->property("text").toString().contains("href="));
        reader->setAiInput("view","summary");QCOMPARE(reader->aiState().value("results").toMap().value("summary").toMap(),saved);QVERIFY(panel->property("result").toMap().value("output").toString().contains("Synthetic summary"));
        // Selected-text summary is a real shared action, not a shell-side prompt.
        reader->setAiInput("action",5);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().contains("plan"));QCOMPARE(reader->aiState().value("plan").toMap().value("action").toString(),QString("SummarizeSelection"));QCOMPARE(server.requests.size(),2);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);plan=reader->aiState().value("plan").toMap();QCOMPARE(plan.value("source_pages").toList(),QVariantList{1});QVERIFY(reader->startAi("local",plan));QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(server.requests.size(),3);auto *selectedAnswer=view.window->findChild<QObject *>("aiAnswerText");QVERIFY(selectedAnswer);QTRY_VERIFY(selectedAnswer->property("text").toString().contains("Synthetic selected text"));QVERIFY(!selectedAnswer->property("text").toString().contains("href=\"p.2"));const auto oldPage=view.window->property("currentPage").toInt();QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,"p.2")));QCOMPARE(view.window->property("currentPage").toInt(),oldPage);QVERIFY(view.window->property("operationStatus").toString().contains("cannot be verified"));saved=reader->aiState().value("results").toMap().value("summary").toMap();
        reader->setAiInput("view","chat");QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().value("plan").toMap().value("action").toString()=="DocumentChat");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);plan=reader->aiState().value("plan").toMap();QVERIFY(reader->startAi("local",plan));QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(server.requests.size(),4);
        QQuickItem *sources=nullptr;QTRY_VERIFY((sources=visualItem(view.window->contentItem(),"aiHistoryAnswer0Sources")));QVERIFY(!sources->property("checked").toBool());QVERIFY(sources->property("visible").toBool());
        view.window->resize(700,600);QTest::qWait(100);auto *composer=visualItem(view.window->contentItem(),"aiQuestion"),*preview=visualItem(view.window->contentItem(),"prepareAiRequest");auto *panelItem=qobject_cast<QQuickItem *>(panel);QVERIFY(composer && preview && panelItem);QVERIFY(composer->isVisible());QVERIFY(preview->mapRectToItem(panelItem,preview->boundingRect()).bottom()<=panelItem->height());QVERIFY(composer->mapRectToItem(panelItem,composer->boundingRect()).bottom()<=panelItem->height());
        auto *conversation=visualItem(view.window->contentItem(),"aiConversationHistory");QVERIFY(conversation);auto *flick=conversation->property("contentItem").value<QObject *>();QVERIFY(flick);QTRY_VERIFY(flick->property("atYEnd").toBool());
        const auto capture=qEnvironmentVariable("LYRA_READER_AI_VIEWS_SNAPSHOT");if(!capture.isEmpty())QVERIFY(view.window->grabWindow().save(capture));
        reader->clearAiChat();QVERIFY(reader->aiState().value("chatTurns").toList().isEmpty());QVERIFY(panel->property("result").toMap().value("output").toString().isEmpty());QCOMPARE(reader->aiState().value("results").toMap().value("summary").toMap(),saved);QVERIFY(reader->aiState().value("results").toMap().contains("translation"));QCOMPARE(server.requests.size(),4);
        view.workspace.newTab();QVERIFY(view.workspace.activeReader()->aiState().isEmpty());view.workspace.selectTab(0);QCOMPARE(reader->aiState().value("input").toMap().value("chatQuestion").toString(),QString("Which page contains body text and caching?"));
    }
    void documentChatStopsFollowingWhenTheReaderScrollsUp() {
        MockChatServer server;QVERIFY(server.listen());MockChatServer::Response stream;stream.holdLast=true;stream.delay=1800;QString longAnswer;for(int i=0;i<100;++i)longAnswer+=QString("Synthetic paragraph %1 with enough text to scroll.\n\n").arg(i);stream.chunks={MockChatServer::delta({{"content",longAnswer}}),MockChatServer::delta({{"content","Later streaming chunk"}}),QByteArray("data: [DONE]\n\n")};server.responses.append(stream);
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);view.window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","fixture"}});QVERIFY(QMetaObject::invokeMethod(view.window,"openAiWorkspace",Q_ARG(QVariant,"chat")));reader->setAiInput("question","Which page contains body text and caching?");auto *panel=view.window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY(reader->aiState().contains("plan"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->startAi("local",reader->aiState().value("plan").toMap()));QTRY_VERIFY(reader->aiState().value("output").toString().contains("paragraph 99"));
        auto *conversation=visualItem(view.window->contentItem(),"aiConversationHistory");QVERIFY(conversation);auto *flick=conversation->property("contentItem").value<QQuickItem *>();QVERIFY(flick);QTRY_VERIFY(flick->property("contentHeight").toDouble()>flick->height()+100);QTRY_VERIFY(flick->property("atYEnd").toBool());QVERIFY(conversation->property("followTail").toBool());
        const auto bottom=flick->property("contentY").toDouble();const auto point=conversation->mapToScene(QPointF(conversation->width()/2,conversation->height()/2));QWheelEvent wheel(point,view.window->mapToGlobal(point.toPoint()),QPoint(),QPoint(0,240),Qt::NoButton,Qt::NoModifier,Qt::NoScrollPhase,false);QGuiApplication::sendEvent(view.window,&wheel);QTRY_VERIFY(!conversation->property("followTail").toBool());QTRY_VERIFY(flick->property("contentY").toDouble()<bottom);QTRY_VERIFY(!flick->property("moving").toBool());const auto y=flick->property("contentY").toDouble();QTRY_VERIFY(reader->aiState().value("output").toString().contains("Later streaming chunk"));QCOMPARE(flick->property("contentY").toDouble(),y);
        flick->setProperty("contentY",flick->property("contentHeight").toDouble()-flick->height());QTRY_VERIFY(conversation->property("followTail").toBool());reader->cancelAi();QTRY_VERIFY(!reader->aiState().value("running").toBool());QCOMPARE(server.requests.size(),1);
    }
    void aiDrawerLeavesOverviewWithoutForcingAToolRowOrLosingTheViewport() {
        NativeCorpus::Viewer view;QVERIFY(view.window);QTemporaryDir scratch;const auto path=scratch.path()+"/drawer.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        view.window->setProperty("fitting",false);view.window->setProperty("zoom",1.2);QVERIFY(QMetaObject::invokeMethod(view.window,"navigate",Q_ARG(QVariant,1),Q_ARG(QVariant,140)));QTest::qWait(100);auto *list=visualItem(view.window->contentItem(),"pageList");QVERIFY(list);const auto y=list->property("contentY").toDouble();
        QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));QCOMPARE(view.window->property("secondaryRow").toString(),QString());QTRY_VERIFY(qAbs(list->property("contentY").toDouble()-y)<2);QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,false)));QTRY_VERIFY(qAbs(list->property("contentY").toDouble()-y)<2);
        QVERIFY(QMetaObject::invokeMethod(view.window,"showOverview",Q_ARG(QVariant,false)));QTRY_VERIFY(view.window->property("overviewVisible").toBool());QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));QVERIFY(!view.window->property("overviewVisible").toBool());
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"fill"),Q_ARG(QVariant,false)));QVERIFY(!view.window->property("aiPanelVisible").toBool());QVERIFY(QMetaObject::invokeMethod(view.window,"openAiWorkspace",Q_ARG(QVariant,"translation")));QCOMPARE(view.window->property("secondaryRow").toString(),QString());QVERIFY(!view.window->property("fillInspectorVisible").toBool());QVERIFY(view.window->property("aiPanelVisible").toBool());QCOMPARE(reader->aiState().value("input").toMap().value("view").toString(),QString("translation"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"annotate"),Q_ARG(QVariant,false)));QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));QCOMPARE(view.window->property("secondaryRow").toString(),QString("annotate"));
    }
    void aiDrawerDefersToTheContentDraftAndDoesNotDismissAFailedEdit() {
        QTemporaryDir scratch;const auto path=scratch.path()+"/drawer-edit.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);auto *editor=view.window->findChild<QObject *>("contentEditing");QVERIFY(editor);QVariantMap item;for(const auto &value:reader->data().value("content_objects").toMap().value("items").toList())if(value.toMap().value("can_edit_text").toBool()){item=value.toMap();break;}QVERIFY(!item.isEmpty());QVERIFY(QMetaObject::invokeMethod(editor,"editText",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(editor,"changeText",Q_ARG(QVariant,"AI draft")));
        auto failed=reader->editDrafts().value("content").toMap();failed.insert("error","Synthetic preserved edit error");reader->setEditDraft("content",failed);QVERIFY(QMetaObject::invokeMethod(view.window,"openAiWorkspace",Q_ARG(QVariant,"chat")));QVERIFY(!view.window->property("aiPanelVisible").toBool());QCOMPARE(view.window->property("secondaryRow").toString(),QString("edit"));QCOMPARE(reader->editDrafts().value("content").toMap(),failed);
        failed.remove("error");reader->setEditDraft("content",failed);QVERIFY(QMetaObject::invokeMethod(view.window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QTRY_VERIFY(view.window->property("aiPanelVisible").toBool());QCOMPARE(view.window->property("aiPanelMode").toString(),QString("notes"));QCOMPARE(view.window->property("secondaryRow").toString(),QString());QVERIFY(!reader->hasEditDrafts());QVERIFY(reader->hasUnsavedChanges());reader->requestText(0);QTRY_VERIFY2(reader->textPages().value("0").toMap().value("text").toString().contains("AI draft"),qPrintable(reader->textPages().value("0").toMap().value("text").toString()));
    }
    void longAiQuestionsKeepTheirCaretAndTextInsideTheComposer() {
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(view.window,"openAiWorkspace",Q_ARG(QVariant,"chat")));view.window->resize(700,600);QTest::qWait(80);
        auto *composer=visualItem(view.window->contentItem(),"aiQuestion");QVERIFY(composer);auto *viewport=visualItem(view.window->contentItem(),"aiComposerScroll");QVERIFY(viewport && viewport->clip());QVERIFY(composer->height()>=viewport->property("availableHeight").toDouble());composer->forceActiveFocus();QString draft;for(int i=0;i<30;++i)draft+=QString("Synthetic question line %1 with wrapped text.\n").arg(i);composer->setProperty("text",draft);QTest::keyClick(view.window,Qt::Key_End,Qt::ControlModifier);QTest::qWait(80);QCOMPARE(reader->aiState().value("input").toMap().value("chatQuestion").toString(),draft);
        auto *flick=viewport->property("contentItem").value<QQuickItem *>();QVERIFY(flick);QVERIFY(flick->property("contentHeight").toDouble()>viewport->height());const auto cursor=composer->mapRectToItem(viewport,composer->property("cursorRectangle").toRectF());const auto image=qEnvironmentVariable("LYRA_READER_AI_COMPOSER_SNAPSHOT");if(!image.isEmpty())QVERIFY(view.window->grabWindow().save(image));QVERIFY2(cursor.top()>=0 && cursor.bottom()<=viewport->height(),qPrintable(QString("Caret %1..%2; viewport height %3").arg(cursor.top()).arg(cursor.bottom()).arg(viewport->height())));
        QTest::keyClick(view.window,Qt::Key_Home,Qt::ControlModifier);QTRY_VERIFY(composer->mapRectToItem(viewport,composer->property("cursorRectangle").toRectF()).top()>=0);QVERIFY(composer->mapRectToItem(viewport,composer->property("cursorRectangle").toRectF()).bottom()<=viewport->height());QCOMPARE(reader->aiState().value("input").toMap().value("chatQuestion").toString(),draft);
    }
    void aiComposerExternalTextStaysUnchangedUntilARealEdit_data() {
        QTest::addColumn<QString>("value");
        QTest::newRow("crlf")<<QStringLiteral("first\r\nsecond");
        QTest::newRow("cr")<<QStringLiteral("first\rsecond");
        QTest::newRow("paragraph")<<QStringLiteral("first\u2029second");
        QTest::newRow("unicode-spaces")<<QString::fromUtf8("  合成问题 e\u0301\t  ");
        QTest::newRow("nul")<<(QStringLiteral("before")+QChar(0)+QStringLiteral("after"));
    }
    void aiComposerExternalTextStaysUnchangedUntilARealEdit() {
        QFETCH(QString,value);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("external-question.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        QSignalSpy warnings(&view.engine,&QQmlEngine::warnings);
        QVERIFY(QMetaObject::invokeMethod(view.window,"openAiWorkspace",Q_ARG(QVariant,"chat")));auto *composer=visualItem(view.window->contentItem(),"aiQuestion");QVERIFY(composer);composer->forceActiveFocus();QTRY_VERIFY(composer->hasActiveFocus());
        QSignalSpy changed(reader,&ReaderController::aiStateChanged);reader->setAiInput("question",value);QTest::qWait(30);
        QCOMPARE(reader->aiState().value("input").toMap().value("question").toString(),value);QCOMPARE(reader->aiState().value("input").toMap().value("chatQuestion").toString(),value);QCOMPARE(changed.size(),1);
        const auto beforeTyping=composer->property("text").toString();composer->setProperty("cursorPosition",composer->property("length"));QTest::keyClick(view.window,Qt::Key_X);QTest::qWait(10);
        const auto edited=composer->property("text").toString();QVERIFY(edited.endsWith('x'));QCOMPARE(reader->aiState().value("input").toMap().value("question").toString(),edited);
        QTest::keyClick(view.window,Qt::Key_Z,Qt::ControlModifier);QCOMPARE(composer->property("text").toString(),beforeTyping);QCOMPARE(reader->aiState().value("input").toMap().value("question").toString(),beforeTyping);
        const auto loops=qmlBindingLoops(warnings);QVERIFY2(loops.isEmpty(),qPrintable(loops.join("\n")));QVERIFY(!reader->hasUnsavedChanges());
    }
    void closingAiWithAComposerFocusedReturnsKeyboardUndoToTheDocument() {
        QTemporaryDir scratch;const auto path=scratch.path()+"/ai-focus.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);QSignalSpy qmlWarnings(&view.engine,&QQmlEngine::warnings);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","square"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",60},{"y",120},{"width",60},{"height",40}}},{"color","#90B79AFF"},{"note","Synthetic document undo"},{"strokeWidth",2}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().size(),1);
        QVERIFY(QMetaObject::invokeMethod(view.window,"openAiWorkspace",Q_ARG(QVariant,"chat")));auto *composer=visualItem(view.window->contentItem(),"aiQuestion");QVERIFY(composer);composer->forceActiveFocus();QTRY_VERIFY(composer->hasActiveFocus());for(const auto ch:QByteArray("Draft retained"))QTest::keyClick(view.window,ch);QCOMPARE(reader->aiState().value("input").toMap().value("chatQuestion").toString(),QString("Draft retained"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,false)));QVERIFY(!composer->hasActiveFocus());auto *canvas=visualItem(view.window->contentItem(),"pageList");QVERIFY(canvas && canvas->hasActiveFocus());QTest::keyClick(view.window,Qt::Key_Z,Qt::ControlModifier);QTRY_COMPARE_WITH_TIMEOUT(reader->data().value("marks").toMap().value("annotations").toList().size(),0,10000);QCOMPARE(reader->aiState().value("input").toMap().value("chatQuestion").toString(),QString("Draft retained"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));composer->forceActiveFocus();view.window->setProperty("aiPanelVisible",false);QVERIFY(!composer->hasActiveFocus());QVERIFY(canvas->hasActiveFocus());
        QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));view.window->setProperty("textViewVisible",true);auto *text=visualItem(view.window->contentItem(),"accessiblePageText");QVERIFY(text);QTRY_VERIFY(text->isVisible());QTest::qWait(30);composer->forceActiveFocus();view.window->setProperty("aiPanelVisible",false);QTRY_VERIFY(text->hasActiveFocus());QVERIFY(!canvas->hasActiveFocus());
        view.window->setProperty("textViewVisible",false);QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));QVERIFY(QMetaObject::invokeMethod(view.window,"showOverview",Q_ARG(QVariant,false)));auto *grid=visualItem(view.window->contentItem(),"pageOverview");QVERIFY(grid && grid->isVisible());composer->forceActiveFocus();view.window->setProperty("aiPanelVisible",false);QTRY_VERIFY(grid->hasActiveFocus());QVERIFY(!canvas->hasActiveFocus());
        QVERIFY(QMetaObject::invokeMethod(view.window,"showAiPanel",Q_ARG(QVariant,true)));composer->forceActiveFocus();view.workspace.newTab();QTRY_VERIFY(!composer->hasActiveFocus());QVERIFY(view.workspace.activeReader()->aiState().value("input").toMap().value("chatQuestion").toString().isEmpty());QCOMPARE(reader->aiState().value("input").toMap().value("chatQuestion").toString(),QString("Draft retained"));
        const auto loops=qmlBindingLoops(qmlWarnings);QVERIFY2(loops.isEmpty(),qPrintable(loops.join("\n")));
        QCOMPARE(view.workspace.activeReader()->aiState().value("input").toMap(),QVariantMap());
    }
    void auditViewerWorksWithoutAPdfAndClearsOnlyTheReviewedLocalSnapshot() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto previous=qgetenv("LYRA_READER_DOCUMENT_CACHE_DIR");const auto restore=qScopeGuard([&]{qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",previous);});const auto cache=scratch.path()+"/cache";qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());
        MockChatServer sentinel;QVERIFY(sentinel.listen());NativeCorpus::Viewer view;QVERIFY(view.window);auto *main=view.window;main->setProperty("aiSettings",QVariantMap{{"baseUrl",sentinel.baseUrl()},{"model","audit-no-send-synthetic-model"}});
        auto *settings=main->findChild<QQuickWindow *>("settingsWindow");QVERIFY(settings);QVERIFY(QMetaObject::invokeMethod(settings,"open"));QTRY_VERIFY(settings->isVisible());
        // Window-scoped Escape shortcuts need the native activation acknowledgement.
        settings->requestActivate();QVERIFY(QTest::qWaitForWindowActive(settings,5000));QTRY_VERIFY(QGuiApplication::focusWindow()==settings);
        auto *button=settings->findChild<QObject *>("openAuditTrail");QVERIFY(button);QVERIFY(QMetaObject::invokeMethod(button,"clicked"));auto *dialog=settings->findChild<QObject *>("auditDialog");auto *controller=settings->findChild<AuditController *>("auditController");QVERIFY(dialog && controller);QTRY_VERIFY(dialog->property("visible").toBool());QTRY_VERIFY_WITH_TIMEOUT(!controller->busy(),10000);
        QCOMPARE(view.workspace.activeReader()->pageCount(),0);QCOMPARE(controller->state().value("records").toList().size(),0);QVERIFY2(controller->error().isEmpty(),qPrintable(controller->error()));QVERIFY(!QDir(cache+"/Audit").exists());QCOMPARE(sentinel.requests.size(),0);
        QVERIFY(QDir().mkpath(cache+"/Audit"));const auto path=cache+"/Audit/ai-requests.jsonl";
        QJsonObject first{{"version",1},{"id","00000001-1111-4222-8333-000000000001"},{"at_unix_ms",qint64(1793800000000)},{"action","region_question"},{"local",true},{"outcome","sent"},{"code",QJsonValue::Null},{"http_status",QJsonValue::Null},{"duration_ms",31}};
        auto second=first;second["id"]="00000002-1111-4222-8333-000000000002";second["action"]="document_chat";second["outcome"]="failed";second["code"]="http_error";second["http_status"]=400;second["local"]=false;
        const auto rows=(QJsonDocument(first).toJson(QJsonDocument::Compact)+"\n"+QJsonDocument(second).toJson(QJsonDocument::Compact)+"\n").replace("\"duration_ms\":31","\"duration_ms\":18446744073709551615");
        QSaveFile file(path);QVERIFY(file.open(QIODevice::WriteOnly));QCOMPARE(file.write(rows),rows.size());QVERIFY(file.commit());controller->reload();QTRY_VERIFY_WITH_TIMEOUT(!controller->busy(),10000);QVERIFY(controller->error().isEmpty());QCOMPARE(controller->state().value("records").toList().size(),2);QCOMPARE(controller->state().value("records").toList()[0].toMap().value("http_status").toInt(),400);QVERIFY(controller->metadata().contains("18446744073709551615"));
        auto *clear=settings->findChild<QObject *>("clearAuditTrail");auto *confirm=settings->findChild<QObject *>("clearAuditConfirmation");QVERIFY(clear && confirm);QVERIFY(clear->property("enabled").toBool());QVERIFY(QMetaObject::invokeMethod(clear,"clicked"));QTRY_VERIFY(confirm->property("opened").toBool());
        auto *auditContent=qvariant_cast<QQuickItem *>(dialog->property("contentItem"));auto *confirmContent=qvariant_cast<QQuickItem *>(confirm->property("contentItem"));QVERIFY(auditContent && confirmContent);
        const auto diagnostic=qEnvironmentVariable("LYRA_READER_AUDIT_SNAPSHOT");if(!diagnostic.isEmpty())QVERIFY(settings->grabWindow().save(diagnostic+"-confirm.png"));
        QCOMPARE(auditContent->window(),settings);QCOMPARE(confirmContent->window(),settings);
        qInfo()<<"Audit Escape preflight"<<"active"<<settings->isActive()<<"exposed"<<settings->isExposed()<<"confirmationOpened"<<confirm->property("opened");
        QVERIFY(settings->isActive());
        QTest::keyClick(settings,Qt::Key_Escape);
        QTRY_VERIFY(!confirm->property("visible").toBool());QVERIFY(dialog->property("visible").toBool());QVERIFY(settings->isVisible());
        QFile unchanged(path);QVERIFY(unchanged.open(QIODevice::ReadOnly));QCOMPARE(unchanged.readAll(),rows);unchanged.close();
        if(qEnvironmentVariableIsSet("LYRA_READER_AUDIT_DARK_NARROW")){main->setProperty("appearance","dark");settings->resize(380,600);}
        const auto snapshot=qEnvironmentVariable("LYRA_READER_AUDIT_SNAPSHOT");if(!snapshot.isEmpty()){QTest::qWait(100);QVERIFY(settings->grabWindow().save(snapshot));}
        QVERIFY(QMetaObject::invokeMethod(clear,"clicked"));QTRY_VERIFY(confirm->property("opened").toBool());auto third=first;third["id"]="00000003-1111-4222-8333-000000000003";const auto newer=rows+QJsonDocument(third).toJson(QJsonDocument::Compact)+"\n";
        QSaveFile concurrent(path);QVERIFY(concurrent.open(QIODevice::WriteOnly));QCOMPARE(concurrent.write(newer),newer.size());QVERIFY(concurrent.commit());QVERIFY(QMetaObject::invokeMethod(confirm,"accept"));QTRY_VERIFY_WITH_TIMEOUT(!controller->busy(),10000);QVERIFY(controller->error().contains("changed"));QVERIFY(unchanged.open(QIODevice::ReadOnly));QCOMPARE(unchanged.readAll(),newer);unchanged.close();QCOMPARE(sentinel.requests.size(),0);
        controller->reload();QTRY_VERIFY_WITH_TIMEOUT(!controller->busy(),10000);QVERIFY(controller->error().isEmpty());QCOMPARE(controller->state().value("records").toList().size(),3);QVERIFY(QMetaObject::invokeMethod(clear,"clicked"));QTRY_VERIFY(confirm->property("opened").toBool());QVERIFY(QMetaObject::invokeMethod(confirm,"accept"));QTRY_VERIFY_WITH_TIMEOUT(!controller->busy(),10000);QVERIFY(controller->error().isEmpty());QCOMPARE(controller->state().value("records").toList().size(),0);
        QVERIFY(unchanged.open(QIODevice::ReadOnly));QVERIFY(unchanged.readAll().isEmpty());unchanged.close();
        auto bad=first;bad["question"]="synthetic content that must never enter an audit snapshot";const auto damaged=QJsonDocument(bad).toJson(QJsonDocument::Compact)+"\n";QSaveFile corrupt(path);QVERIFY(corrupt.open(QIODevice::WriteOnly));QCOMPARE(corrupt.write(damaged),damaged.size());QVERIFY(corrupt.commit());controller->reload();QTRY_VERIFY_WITH_TIMEOUT(!controller->busy(),10000);QVERIFY(!controller->error().isEmpty());QVERIFY(!controller->metadata().contains("synthetic content"));QVERIFY(!clear->property("enabled").toBool());auto *empty=settings->findChild<QObject *>("auditEmpty");QVERIFY(empty);QVERIFY(!empty->property("visible").toBool());
        QVERIFY(unchanged.open(QIODevice::ReadOnly));QCOMPARE(unchanged.readAll(),damaged);QCOMPARE(sentinel.requests.size(),0);QVERIFY(QMetaObject::invokeMethod(dialog,"close"));QVERIFY(settings->isVisible());QVERIFY(settings->close());
        QVERIFY(QMetaObject::invokeMethod(main,"showAuditTrail"));QTRY_VERIFY(settings->isVisible());QTRY_VERIFY(dialog->property("visible").toBool());QTRY_VERIFY_WITH_TIMEOUT(!controller->busy(),10000);QCOMPARE(sentinel.requests.size(),0);QVERIFY(QMetaObject::invokeMethod(dialog,"close"));QVERIFY(settings->close());
    }
    void regionQuestionsCaptureOnceAndSendOnlyTheExplicitPreview() {
        MockChatServer server;QVERIFY(server.listen());
        server.responses.append({{QByteArray("{\"error\":{\"message\":\"Unsupported parameter: stream_options\"}}")},0,400});
        server.responses.append({{MockChatServer::delta({{"content","Synthetic area answer [p.1] and [p.99]."}}),QByteArray("data: [DONE]\n\n")},20,200});
        server.responses.append({{MockChatServer::delta({{"content","partial area answer"}}),QByteArray("data: [DONE]\n\n")},20,200,true});
        const auto auditPath=qEnvironmentVariable("LYRA_READER_DOCUMENT_CACHE_DIR")+"/Audit/ai-requests.jsonl";
        const auto auditRows=[&]{QList<QJsonObject> rows;QFile audit(auditPath);if(audit.open(QIODevice::ReadOnly))for(const auto &line:audit.readAll().split('\n'))if(!line.isEmpty())rows.append(QJsonDocument::fromJson(line).object());return rows;};
        const int initialAuditCount=auditRows().size();
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/area.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!window->property("positionRestoring").toBool());
        QVERIFY(settleReaderViewport(window));
        window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","region-audit-synthetic-model"},{"imageInput",false}});
        QVERIFY(QMetaObject::invokeMethod(window,"armRegion",Q_ARG(QVariant,false)));QTRY_VERIFY(window->property("regionSelecting").toBool());QVERIFY(settleReaderViewport(window));
        reader->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto sourcePages=reader->pages(),sourceRows=reader->layoutRows();
        auto *page=visualItem(window->contentItem(),"pdfPage0");QVERIFY(page);
        const auto start=page->mapToScene(QPointF(60,55)*window->property("zoom").toDouble()).toPoint(),end=page->mapToScene(QPointF(480,235)*window->property("zoom").toDouble()).toPoint();
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,start);QTest::mouseMove(window,end,30);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,end);
        QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegion().value("image_png").toString().isEmpty(),15000);
        QVERIFY2(reader->aiRegion().value("error").toString().isEmpty(),qPrintable(reader->aiRegion().value("error").toString()));QVERIFY(!window->property("regionSelecting").toBool());
        const auto attachment=reader->aiRegion();QCOMPARE(attachment.value("capture_scale").toDouble(),2.0);QVERIFY(attachment.value("text").toString().contains("quick brown fox"));
        const auto paperPlan=attachment.value("paper_plan").toMap();QVERIFY(paperPlan.contains("split_pt"));QVERIFY(paperPlan.contains("fallback"));QVERIFY(paperPlan.value("warning").isNull());
        const auto png=QByteArray::fromBase64(attachment.value("image_png").toByteArray());const auto picture=QImage::fromData(png);QVERIFY(!picture.isNull());QCOMPARE(picture.size(),QSize(attachment.value("image_width_px").toInt(),attachment.value("image_height_px").toInt()));
        const double pointerTolerance=1.01/window->property("zoom").toDouble();
        QVERIFY(std::abs(attachment.value("width_pt").toDouble()-420)<pointerTolerance);QVERIFY(std::abs(attachment.value("height_pt").toDouble()-180)<pointerTolerance);
        QVERIFY(std::abs(picture.width()-840)<=std::ceil(pointerTolerance*2));QVERIFY(std::abs(picture.height()-360)<=std::ceil(pointerTolerance*2));
        if(qEnvironmentVariableIsSet("LYRA_READER_REGION_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(700,600);QTest::qWait(100);}
        auto *card=window->findChild<QObject *>("aiRegionCard");QVERIFY(card);QTRY_VERIFY(card->property("visible").toBool());auto *crop=window->findChild<QObject *>("aiRegionImage");QVERIFY(crop);QTRY_COMPARE_WITH_TIMEOUT(crop->property("status").toInt(),1,10000);
        QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegionPaper().contains("rows") && !reader->aiRegionPaper().value("loading").toBool(),10000);
        auto *paperCard=qobject_cast<QQuickItem *>(card);QVERIFY(paperCard);QCOMPARE(paperCard->parentItem()->objectName(),QString("documentCanvas"));
        QCOMPARE(reader->pages(),sourcePages);QCOMPARE(reader->layoutRows(),sourceRows);QCOMPARE(visualItem(window->contentItem(),"pdfPage0"),page);
        QTRY_VERIFY(!card->property("motionActive").toBool() && paperCard->y()>=-1 && paperCard->y()+paperCard->height()<=paperCard->parentItem()->height()+1);
        auto *canvas=paperCard->parentItem();const auto gapTop=reader->aiRegionPaper().value("gap_top").toDouble();
        QVERIFY(QMetaObject::invokeMethod(canvas,"positionAnchor",Q_ARG(QVariant,QVariantMap({{"page",0},{"y",gapTop+80}})),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
        const auto saved=workspace.viewState(reader);QCOMPARE(saved.value("viewportAnchor").toMap().value("y").toDouble(),gapTop);
        QCOMPARE(saved.value("offset").toDouble()/window->property("zoom").toDouble(),gapTop);
        QVERIFY(QMetaObject::invokeMethod(card,"close"));QVERIFY(reader->aiRegionPaper().isEmpty());
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
        const auto list=window->findChild<QQuickItem *>("pageList");QVERIFY(list);
        const double edge=reader->zoomPresetInset(),zoom=window->property("zoom").toDouble();
        const auto expectedClosed=std::max(0.0,reader->clampScroll(gapTop*zoom+edge,reader->documentHeight()*zoom+2*edge,list->height())-edge);
        QVERIFY(qAbs(workspace.viewState(reader).value("offset").toDouble()-expectedClosed)<.01);
        QVERIFY(QMetaObject::invokeMethod(card,"open"));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegionPaper().contains("rows") && !reader->aiRegionPaper().value("loading").toBool(),10000);
        QTRY_VERIFY(!card->property("motionActive").toBool() && paperCard->y()>=-1 && paperCard->y()+paperCard->height()<=canvas->height()+1);
        const auto paperSnapshot=qEnvironmentVariable("LYRA_READER_REGION_PAPER_SNAPSHOT");if(!paperSnapshot.isEmpty()){QTest::qWait(100);QVERIFY(window->grabWindow().save(paperSnapshot));}
        QVERIFY2(qAbs(crop->property("width").toDouble()/crop->property("height").toDouble()-double(picture.width())/picture.height())<.001,"The captured area must keep its pixel aspect ratio in the bounded preview");
        window->setProperty("paperAppearance","night");QCOMPARE(reader->aiRegion().value("image_png"),attachment.value("image_png"));QCOMPARE(crop->property("paperAppearance").toString(),QString("original"));
        QSignalSpy imageChanges(reader,&ReaderController::aiRegionImageChanged);const auto imageUrl=reader->aiRegionImage();
        reader->setAiRegionQuestion("What is shown in this synthetic area?");QCOMPARE(imageChanges.size(),0);QCOMPARE(reader->aiRegionImage(),imageUrl);QVERIFY(QMetaObject::invokeMethod(card,"prepare"));
        QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QCOMPARE(server.requests.size(),0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto textPlan=reader->aiState().value("plan").toMap();const auto textBody=textPlan.value("parts").toList().first().toMap().value("wire_body").toString();QVERIFY(!textBody.contains("data:image/png"));QVERIFY(textBody.contains("quick brown fox"));
        window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","region-audit-synthetic-model"},{"imageInput",true}});QVERIFY(!reader->startAi("local",textPlan));
        QVERIFY(QMetaObject::invokeMethod(card,"prepare"));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto plan=reader->aiState().value("plan").toMap();const auto body=plan.value("parts").toList().first().toMap().value("wire_body").toString();QVERIFY(body.contains("data:image/png;base64,"+attachment.value("image_png").toString()));QVERIFY(!body.contains("paper_plan"));QCOMPARE(server.requests.size(),0);
        auto *payload=window->findChild<QObject *>("aiRegionPayload"),*displayedPayload=window->findChild<QObject *>("aiRegionDisplayedPayload");QVERIFY(payload && displayedPayload);QVERIFY(displayedPayload->property("text").toString().isEmpty());
        QVERIFY(QMetaObject::invokeMethod(payload,"open"));QTRY_VERIFY(payload->property("visible").toBool());QVERIFY(displayedPayload->property("text").toString().contains("Captured PNG bytes"));QVERIFY(!displayedPayload->property("text").toString().contains(attachment.value("image_png").toString()));QCOMPARE(payload->property("snapshot").toMap().value("parts").toList().first().toMap().value("wire_body").toString(),body);
        QVERIFY(QMetaObject::invokeMethod(payload,"close"));QTRY_VERIFY(!payload->property("visible").toBool());QVERIFY(displayedPayload->property("text").toString().isEmpty());
        const auto snapshots=qEnvironmentVariable("LYRA_READER_REGION_SNAPSHOT");if(!snapshots.isEmpty()){QTest::qWait(100);QVERIFY(window->grabWindow().save(snapshots));}
        auto *send=window->findChild<QQuickItem *>("sendAiRegion");QVERIFY(send && send->isEnabled());QVERIFY(settleRegionControl(window,paperCard,send,reader));QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,send->mapToScene(QPointF(send->width()/2,send->height()/2)).toPoint());
        QTRY_COMPARE_WITH_TIMEOUT(server.requests.size(),2,10000);const auto raw=server.requests.first();QCOMPARE(raw.mid(raw.indexOf("\r\n\r\n")+4),body.toUtf8());
        auto fallback=QJsonDocument::fromJson(body.toUtf8()).object();fallback.remove("stream_options");const auto retry=server.requests[1];QCOMPARE(QJsonDocument::fromJson(retry.mid(retry.indexOf("\r\n\r\n")+4)).object(),fallback);
        QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(reader->aiState().value("output").toString().contains("Synthetic area answer"));
        auto *answer=window->findChild<QObject *>("aiRegionAnswer");QVERIFY(answer);QVERIFY(!answer->property("text").toString().contains("href=\"p.99\""));
        QVERIFY(reader->saveAiRegionNote());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto savedRegionId=reader->aiRegion().value("history_id").toString();QSignalSpy regionReads(reader,&ReaderController::commandFinished);
        const auto firstRead=reader->submit("region_get",{{"id",savedRegionId}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap firstEntry;
        for(const auto &row:regionReads)if(row[0].toULongLong()==firstRead){QVERIFY(row[3].toString().isEmpty());firstEntry=row[2].toMap();}
        QVERIFY(!firstEntry.isEmpty());QCOMPARE(firstEntry.value("turns").toList().size(),1);QCOMPARE(firstEntry.value("turns").toList()[0].toMap().value("sourcePages").toList(),plan.value("source_pages").toList());

        const auto pageBefore=window->property("currentPage");const QVariant sentSource=QVariantMap{{"source_pages",plan.value("source_pages")},{"generation",reader->documentGeneration()}};QVERIFY(QMetaObject::invokeMethod(card,"follow",Q_ARG(QVariant,"p.99"),Q_ARG(QVariant,sentSource)));QCOMPARE(window->property("currentPage"),pageBefore);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(auditRows().size(),initialAuditCount+2);
        QCOMPARE(auditRows().at(initialAuditCount).value("http_status").toInt(),400);QCOMPARE(auditRows().at(initialAuditCount).value("outcome").toString(),QString("failed"));QCOMPARE(auditRows().last().value("outcome").toString(),QString("sent"));
        reader->setAiRegionQuestion("Second synthetic area question never logged");QVERIFY(QMetaObject::invokeMethod(card,"prepare"));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto secondBody=reader->aiState().value("plan").toMap().value("parts").toList().first().toMap().value("wire_body").toString().toUtf8();QVERIFY(secondBody.contains("Synthetic area answer"));
        QVERIFY(settleRegionControl(window,paperCard,send,reader));QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,send->mapToScene(QPointF(send->width()/2,send->height()/2)).toPoint());QTRY_COMPARE_WITH_TIMEOUT(server.requests.size(),3,10000);const auto secondRequest=server.requests.last();QCOMPARE(secondRequest.mid(secondRequest.indexOf("\r\n\r\n")+4),secondBody);QTRY_VERIFY(reader->aiState().value("output").toString().contains("partial area answer"));
        auto *stop=window->findChild<QQuickItem *>("stopAiRegion");QVERIFY(stop && stop->isVisible());QTRY_COMPARE_WITH_TIMEOUT(reader->aiRegionPaper().value("card").toMap().value("gap_pt").toDouble()*window->property("zoom").toDouble(),paperCard->height(),10000);QTRY_VERIFY(paperCard->parentItem()->contains(stop->mapToItem(paperCard->parentItem(),QPointF(0,0))) && paperCard->parentItem()->contains(stop->mapToItem(paperCard->parentItem(),QPointF(stop->width(),stop->height()))));QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,stop->mapToScene(QPointF(stop->width()/2,stop->height()/2)).toPoint());QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(auditRows().size(),initialAuditCount+3);QCOMPARE(auditRows().last().value("outcome").toString(),QString("cancelled"));
        QFile audit(auditPath);QVERIFY(audit.open(QIODevice::ReadOnly));const auto auditBytes=audit.readAll();QVERIFY(!auditBytes.contains("quick brown fox"));QVERIFY(!auditBytes.contains("Second synthetic"));QVERIFY(!auditBytes.contains(attachment.value("image_png").toByteArray()));QVERIFY(!auditBytes.contains("area.pdf"));
        audit.close();const auto restoreAudit=qScopeGuard([&]{QSaveFile restored(auditPath);if(restored.open(QIODevice::WriteOnly)){restored.write(auditBytes);restored.commit();}});
        QSaveFile broken(auditPath);QVERIFY(broken.open(QIODevice::WriteOnly));QCOMPARE(broken.write("incomplete audit"),qint64(16));QVERIFY(broken.commit());
        reader->setAiRegionQuestion("An unavailable audit must block HTTP");QVERIFY(QMetaObject::invokeMethod(card,"prepare"));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto afterStopBody=reader->aiState().value("plan").toMap().value("parts").toList().first().toMap().value("wire_body").toString();QVERIFY(afterStopBody.contains("Synthetic area answer"));QVERIFY(!afterStopBody.contains("partial area answer"));
        QVERIFY(reader->startAi("local",reader->aiState().value("plan").toMap()));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(reader->aiState().value("status").toString().contains("audit"));QCOMPARE(server.requests.size(),3);
        QFile unchangedAudit(auditPath);QVERIFY(unchangedAudit.open(QIODevice::ReadOnly));QCOMPARE(unchangedAudit.readAll(),QByteArray("incomplete audit"));
        QVERIFY(reader->saveAiRegionNote());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);regionReads.clear();
        const auto blockedRead=reader->submit("region_get",{{"id",savedRegionId}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap blockedEntry;
        for(const auto &row:regionReads)if(row[0].toULongLong()==blockedRead){QVERIFY(row[3].toString().isEmpty());blockedEntry=row[2].toMap();}
        QCOMPARE(blockedEntry.value("turns").toList().size(),3);QCOMPARE(blockedEntry.value("turns").toList()[1].toMap().value("state").toString(),QString("cancelled"));QVERIFY(blockedEntry.value("turns").toList()[1].toMap().value("answer").toString().contains("partial area answer"));QVERIFY(!blockedEntry.value("turns").toList().last().toMap().contains("sourcePages"));QCOMPARE(server.requests.size(),3);

        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",220},{"height",440}},1));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegion().value("image_png").toString().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(crop->property("status").toInt(),1,10000);QVERIFY(qAbs(crop->property("width").toDouble()/crop->property("height").toDouble()-.5)<.001);
        window->setProperty("textViewVisible",true);auto *readable=visualItem(window->contentItem(),"accessiblePageText");QVERIFY(readable);QTRY_VERIFY(readable->isVisible());
        QVERIFY(QMetaObject::invokeMethod(card,"close"));QTRY_VERIFY(readable->hasActiveFocus());QVERIFY(reader->aiRegionPaper().isEmpty());QVERIFY(!card->property("opened").toBool());QCOMPARE(server.requests.size(),3);
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));auto *savedNotes=window->findChild<QObject *>("regionNotes");QVERIFY(savedNotes);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(savedNotes,"load",Q_ARG(QVariant,savedRegionId)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTRY_VERIFY(visualItem(window->contentItem(),"regionNoteSource1"));auto *sentPage=visualItem(window->contentItem(),"regionNoteSource1");QTRY_VERIFY(sentPage->isVisible());QVERIFY(sentPage->isEnabled());
        const auto beforeSource=window->property("currentPage");QVERIFY(QMetaObject::invokeMethod(savedNotes,"followSource",Q_ARG(QVariant,99)));QCOMPARE(window->property("currentPage"),beforeSource);QVERIFY(window->property("operationStatus").toString().contains("unavailable"));
        window->setProperty("operationStatus",QString{});QVERIFY(QMetaObject::invokeMethod(sentPage,"clicked"));QCOMPARE(window->property("currentPage").toInt(),0);QVERIFY(window->property("operationStatus").toString().isEmpty());
        const auto generation=savedNotes->property("ownerGeneration");savedNotes->setProperty("ownerGeneration",generation.toInt()-1);QVERIFY(QMetaObject::invokeMethod(savedNotes,"followSource",Q_ARG(QVariant,1)));QVERIFY(window->property("operationStatus").toString().contains("unavailable"));savedNotes->setProperty("ownerGeneration",generation);
        savedNotes->setProperty("turnIndex",2);QTRY_VERIFY(!visualItem(window->contentItem(),"regionNoteSource1"));QVERIFY(QMetaObject::invokeMethod(savedNotes,"followSource",Q_ARG(QVariant,1)));QVERIFY(window->property("operationStatus").toString().contains("unavailable"));
        QVERIFY(QMetaObject::invokeMethod(savedNotes,"close"));QCOMPARE(server.requests.size(),3);
        QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);
    }
    void regionPaperUnfoldClipsNativeTextAndHoldsRasterDemand_data() {
        QTest::addColumn<double>("zoom");QTest::newRow("page")<<1.0;QTest::newRow("tiles")<<3.0;
    }
    void regionPaperUnfoldClipsNativeTextAndHoldsRasterDemand() {
        QFETCH(double,zoom);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-unfold.pdf");
        {QPdfWriter writer(path);writer.setResolution(72);writer.setPageSize(QPageSize(QSizeF(595,842),QPageSize::Point));writer.setPageMargins(QMarginsF(0,0,0,0),QPageLayout::Point);
            QPainter paint(&writer);QVERIFY(paint.isActive());paint.setPen(Qt::black);
            for(int i=0;i<3;++i){if(i)QVERIFY(writer.newPage());paint.drawText(QPointF(60,90),QString("PUBLIC_MOTION_PAGE_%1").arg(i+1));paint.drawText(QPointF(60,260),QString("PUBLIC_BELOW_CUT_%1").arg(i+1));}QVERIFY(paint.end());}
        QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;const auto previousMotion=window->property("reduceMotion");auto restoreMotion=qScopeGuard([&]{window->setProperty("reduceMotion",previousMotion);});window->setProperty("reduceMotion",false);
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==3 && !reader->loading() && reader->pendingCommands()==0 && !window->property("positionRestoring").toBool());
        window->setProperty("secondaryRow","lyra");QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,zoom),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        reader->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));
        QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),10000);
        auto *page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);
        QTRY_VERIFY_WITH_TIMEOUT(page->refined(),10000);QCOMPARE(page->rasterScale(),zoom);
        QVERIFY(settleRasterWork(reader));if(zoom>1)QVERIFY(page->loadedTileCount()>0);
        const auto enqueued=[] {const auto stats=RasterJobs::statistics();return stats.value("completed").toLongLong()+stats.value("running").toLongLong()+stats.value("queued").toLongLong();};
        auto *card=window->findChild<QQuickItem *>("aiRegionCard");auto *body=window->findChild<QQuickItem *>("aiRegionBody");auto *question=window->findChild<QQuickItem *>("aiRegionQuestion");QVERIFY(card && body && question);
        const auto font=question->property("font");
        window->setProperty("secondaryRow","lyra");QVERIFY(QMetaObject::invokeMethod(card,"open"));
        QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegionPaper().contains("rows") && card->property("motionActive").toBool(),10000);
        QTRY_VERIFY_WITH_TIMEOUT(card->property("revealProgress").toDouble()>0,10000);
        auto *crop=window->findChild<QObject *>("aiRegionImage");QVERIFY(crop);
        QTRY_COMPARE_WITH_TIMEOUT(crop->property("status").toInt(),1,10000);
        // A single PNG decode belongs to opening the card, not to its geometry frames.
        auto *animation=window->findChild<QObject *>("paperRevealMotion");QVERIFY(animation);QCOMPARE(animation->property("duration").toInt(),220);
        QVERIFY(QMetaObject::invokeMethod(animation,"pause"));QVERIFY(card->property("motionActive").toBool());
        const auto before=enqueued();const auto plans=reader->tilePlanBatches();
        // Hold representative geometry frames longer than the normal demand debounce.
        // A stalled/slow animation must not accidentally schedule PDF work either.
        for(const double progress:{.25,.5,.75}) {
            card->setProperty("revealProgress",progress);QTest::qWait(60);
            QVERIFY(page->rasterDemandPaused());QCOMPARE(enqueued(),before);QCOMPARE(reader->tilePlanBatches(),plans);
            QCOMPARE(question->property("font"),font);QCOMPARE(body->height(),card->property("fullHeight").toDouble());
            QVERIFY(qAbs(card->height()-body->height()*progress)<.01);
            if(progress==.5) {
                QObject otherSurface;auto dropSurface=qScopeGuard([&]{RenderBudget::instance()->setClient(&otherSurface,0);});
                RenderBudget::instance()->setClient(&otherSurface,20);QTest::qWait(90);
                QCOMPARE(enqueued(),before);QCOMPARE(reader->tilePlanBatches(),plans);
                RenderBudget::instance()->setClient(&otherSurface,0);QTest::qWait(90);
                QCOMPARE(enqueued(),before);QCOMPARE(reader->tilePlanBatches(),plans);
            }
            QVERIFY2(card->y()>=-.01 && card->y()+card->height()<=card->parentItem()->height()+.01,"The revealed native card must remain inside the viewport.");
            const auto evidence=qEnvironmentVariable("LYRA_READER_REVEAL_EVIDENCE_DIR");
            if(!evidence.isEmpty()){QVERIFY(QDir().mkpath(evidence));QVERIFY(window->grabWindow().save(evidence+QString("/unfold-z%1-p%2.png").arg(int(zoom*100)).arg(int(progress*100))));}
        }
        QVERIFY(QMetaObject::invokeMethod(animation,"resume"));
        int openingFrames=0;const auto sourcePages=reader->pages();QElapsedTimer limit;limit.start();
        while(card->property("motionActive").toBool() && limit.elapsed()<3000) {
            const double progress=card->property("revealProgress").toDouble();
            if(progress>0 && progress<1) {
                ++openingFrames;QVERIFY(card->clip());QVERIFY(page->rasterDemandPaused());
                QVERIFY(qAbs(card->height()-body->height()*progress)<.01);QCOMPARE(question->property("font"),font);
                QCOMPARE(body->height(),card->property("fullHeight").toDouble());QCOMPARE(enqueued(),before);QCOMPARE(reader->tilePlanBatches(),plans);
                QVERIFY(page->paperLayout());QVERIFY(qAbs(page->paperLayout()->gap-reader->aiRegionPaper().value("card").toMap().value("gap_pt").toDouble()*progress)<.01);
            }
            QTest::qWait(16);
        }
        QVERIFY(openingFrames>=2);QVERIFY(!card->property("motionActive").toBool());QVERIFY(!page->rasterDemandPaused());
        QCOMPARE(card->height(),body->height());QCOMPARE(reader->pages(),sourcePages);
        QVERIFY(settleRasterWork(reader));
        const auto gapTop=reader->aiRegionPaper().value("gap_top").toDouble();
        QVERIFY(QMetaObject::invokeMethod(card->parentItem(),"positionAnchor",Q_ARG(QVariant,QVariantMap({{"page",0},{"y",gapTop+80/zoom}})),Q_ARG(QVariant,0)));
        QTRY_VERIFY(qAbs(card->y()+80)<1.01);QVERIFY(settleRasterWork(reader));
        const auto closingBottom=card->y()+card->height();const auto closingBefore=enqueued();const auto closingPlans=reader->tilePlanBatches();
        QVERIFY(QMetaObject::invokeMethod(card,"closeAnimated"));QVERIFY(QMetaObject::invokeMethod(animation,"pause"));
        // Read settled geometry rather than the interval between animation publication
        // and the queued scroll adjustment, which can span separate native callbacks.
        for(const double progress:{.99,.9,.75,.5,.25}) {
            card->setProperty("revealProgress",progress);QTest::qWait(60);
            const auto endBound=gapTop*zoom+card->parentItem()->height()-(reader->documentHeight()*zoom+card->height());
            const auto expectedY=qMax(qMin(0.0,closingBottom-card->height()),endBound);
            QVERIFY2(qAbs(card->y()-expectedY)<1.01,qPrintable(QString("Closing gap anchor moved %1 -> %2").arg(expectedY).arg(card->y())));
            QCOMPARE(enqueued(),closingBefore);QCOMPARE(reader->tilePlanBatches(),closingPlans);
        }
        QVERIFY(QMetaObject::invokeMethod(animation,"resume"));int closingFrames=0;limit.restart();
        while(card->property("opened").toBool() && limit.elapsed()<3000) {
            const double progress=card->property("revealProgress").toDouble();
            if(progress>0 && progress<1) {
                ++closingFrames;QVERIFY(page->rasterDemandPaused());QCOMPARE(enqueued(),closingBefore);QCOMPARE(reader->tilePlanBatches(),closingPlans);
                QCOMPARE(body->height(),card->property("fullHeight").toDouble());QCOMPARE(question->property("font"),font);
                QVERIFY(qAbs(card->height()-body->height()*progress)<.01);
            }
            QTest::qWait(16);
        }
        QVERIFY(closingFrames>=2);QVERIFY(!card->property("opened").toBool());QVERIFY(reader->aiRegionPaper().isEmpty());QVERIFY(!page->rasterDemandPaused());
        window->setProperty("reduceMotion",true);QVERIFY(QMetaObject::invokeMethod(card,"open"));
        QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegionPaper().contains("rows") && !card->property("needsReveal").toBool(),10000);
        QCOMPARE(card->property("revealProgress").toDouble(),1.0);QVERIFY(!card->property("motionActive").toBool());QCOMPARE(card->height(),body->height());
        QVERIFY(QMetaObject::invokeMethod(card,"closeAnimated"));QVERIFY(!card->property("opened").toBool());QVERIFY(reader->aiRegionPaper().isEmpty());
        reader->clearAiRegion();QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);
    }
    void regionPaperMotionsFinishOnReopenNavigationAndDocumentChanges() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("motion-cancel.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;const auto oldMotion=window->property("reduceMotion");auto restore=qScopeGuard([&]{window->setProperty("reduceMotion",oldMotion);});window->setProperty("reduceMotion",false);
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && reader->pendingCommands()==0 && !window->property("positionRestoring").toBool());
        window->setProperty("secondaryRow","lyra");QVERIFY(settleReaderViewport(window));
        reader->requestText(0);QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),10000);
        auto *card=window->findChild<QQuickItem *>("aiRegionCard");QVERIFY(card);window->setProperty("secondaryRow","lyra");
        const auto openMoving=[&] {return QMetaObject::invokeMethod(card,"open");};
        QVERIFY(openMoving());QTRY_VERIFY(card->property("revealProgress").toDouble()>0 && card->property("revealProgress").toDouble()<1);
        view.workspace.newTab();QVERIFY(!card->property("opened").toBool());QVERIFY(reader->aiRegionPaper().isEmpty());QTest::qWait(260);QVERIFY(!card->property("opened").toBool());QVERIFY(view.workspace.activeReader()!=reader);
        view.workspace.selectTab(0);QTRY_COMPARE(window->property("currentReader").value<QObject *>(),reader);QVERIFY(openMoving());
        QTRY_VERIFY(card->property("revealProgress").toDouble()>0 && card->property("revealProgress").toDouble()<1);
        window->setProperty("reduceMotion",true);QVERIFY(!card->property("motionActive").toBool());QCOMPARE(card->property("revealProgress").toDouble(),1.0);
        QVERIFY(QMetaObject::invokeMethod(card,"close"));window->setProperty("reduceMotion",false);QVERIFY(openMoving());
        QTRY_VERIFY(card->property("revealProgress").toDouble()>0 && card->property("revealProgress").toDouble()<1);
        QVERIFY(QMetaObject::invokeMethod(card,"closeAnimated"));QVERIFY(card->property("closing").toBool());QVERIFY(openMoving());
        QTRY_VERIFY(!card->property("motionActive").toBool());QTest::qWait(260);QVERIFY(card->property("opened").toBool());QVERIFY(!card->property("closing").toBool());
        QVERIFY(QMetaObject::invokeMethod(card,"close"));QVERIFY(openMoving());QTRY_VERIFY(card->property("motionActive").toBool() && reader->aiRegionPaper().contains("rows"));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,100)));QVERIFY(!card->property("motionActive").toBool());QCOMPARE(card->property("revealProgress").toDouble(),1.0);
        QVERIFY(QMetaObject::invokeMethod(card,"close"));QVERIFY(openMoving());QTRY_VERIFY(card->property("motionActive").toBool() && reader->aiRegionPaper().contains("rows"));
        window->hide();QVERIFY(!card->property("motionActive").toBool());window->show();QVERIFY(QMetaObject::invokeMethod(card,"close"));QVERIFY(openMoving());
        QTRY_VERIFY(card->property("motionActive").toBool() && reader->aiRegionPaper().contains("rows"));reader->openFile(QUrl::fromLocalFile(path));
        QTRY_VERIFY(!reader->loading() && reader->pendingCommands()==0);QVERIFY(!card->property("opened").toBool());QVERIFY(reader->aiRegionPaper().isEmpty());QTest::qWait(260);QVERIFY(reader->aiRegionPaper().isEmpty());
        QTRY_COMPARE(reader->pendingRasters(),0);QVERIFY(QMetaObject::invokeMethod(window,"armRegion",Q_ARG(QVariant,false)));
        const auto used=RenderBudget::statistics().value("residentBytes").toLongLong();
        auto pressure=RenderBudget::reserve(RenderBudget::Kind::Resident,RenderBudget::residentLimit-used);QVERIFY(pressure);
        QVERIFY(QMetaObject::invokeMethod(window,"finishRegionSelection",Q_ARG(QVariant,0),Q_ARG(QVariant,QVariantMap({{"x",60},{"y",55},{"width",420},{"height",180}}))));
        QVERIFY(reader->aiRegion().contains("error"));QVERIFY(!reader->aiRegion().contains("image_png"));
        QTRY_VERIFY(card->property("opened").toBool() && card->height()>0 && !card->property("motionActive").toBool());
        QVERIFY(QMetaObject::invokeMethod(card,"close"));pressure.reset();reader->clearAiRegion();
    }
    void regionPaperKeepsUnequalRowsDraftsAndDistantReadingAnchors_data() {
        QTest::addColumn<QString>("mode");QTest::addColumn<int>("ownerPage");QTest::addColumn<bool>("foot");
        QTest::newRow("continuous-tear")<<QString("Continuous")<<7<<false;
        QTest::newRow("facing-left-tear")<<QString("Facing")<<7<<false;
        QTest::newRow("facing-right-tear")<<QString("Facing")<<8<<false;
        QTest::newRow("facing-left-foot")<<QString("Facing")<<7<<true;
        QTest::newRow("facing-left-foot-late-layout")<<QString("Facing")<<7<<true;
        QTest::newRow("facing-right-foot")<<QString("Facing")<<8<<true;
        QTest::newRow("last-page-foot")<<QString("Continuous")<<11<<true;
        QTest::newRow("last-page-foot-tall")<<QString("Continuous")<<11<<true;
    }
    void regionPaperKeepsUnequalRowsDraftsAndDistantReadingAnchors() {
        QFETCH(QString,mode);QFETCH(int,ownerPage);QFETCH(bool,foot);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-navigation.pdf");
        {QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageMargins(QMarginsF(0,0,0,0));
            QPainter painter;for(int page=0;page<12;++page){
                const auto height=page%3==0?640:page%3==1?760:900;
                pdf.setPageSize(QPageSize(QSizeF(400+50*(page%3),height),QPageSize::Point));
                if(page)QVERIFY(pdf.newPage());else QVERIFY(painter.begin(&pdf));
                painter.fillRect(QRectF(0,0,500,height),Qt::white);painter.setPen(Qt::black);painter.setFont(QFont("DejaVu Sans",13));
                painter.drawText(QPointF(40,90),QString("PUBLIC_PAPER_PAGE_%1").arg(page+1));
                painter.fillRect(QRectF(40,300,220,100),QColor("#88611B"));
                painter.drawText(QPointF(40,height-50),QString("PUBLIC_BOTTOM_%1").arg(page+1));
            }QVERIFY(painter.end());}
        QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        MockChatServer server;QVERIFY(server.listen());NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;
        if(QByteArray(QTest::currentDataTag()).endsWith("-tall"))window->resize(1693,1385);
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==12 && !reader->loading() && reader->pendingCommands()==0 && !window->property("positionRestoring").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,mode)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        const auto navigate=[&](int page,double y){return QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,page),Q_ARG(QVariant,y));};
        QVERIFY(navigate(ownerPage,0));QTRY_VERIFY(visualItem(window->contentItem(),"pdfPage"+QString::number(ownerPage)));
        reader->requestText(ownerPage);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto sourcePages=reader->pages(),sourceRows=reader->layoutRows();QPointer<QQuickItem> originalPage=visualItem(window->contentItem(),"pdfPage"+QString::number(ownerPage));
        window->setProperty("secondaryRow","lyra");window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","public-paper-model"}});
        const QVariantMap rect{{"x",40},{"y",foot?300:70},{"width",220},{"height",foot?100:70}};
        QVERIFY(reader->captureAiRegion(ownerPage,rect,1));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),10000);
        auto *card=window->findChild<QObject *>("aiRegionCard");QVERIFY(card);QVERIFY(QMetaObject::invokeMethod(card,"open"));
        QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegionPaper().contains("rows") && !reader->aiRegionPaper().value("loading").toBool() && !card->property("needsReveal").toBool(),10000);
        const auto plan=reader->aiRegionPaper();const auto geometry=plan.value("card").toMap();QCOMPARE(geometry.value("split_pt").isNull(),foot);
        QCOMPARE(reader->pages(),sourcePages);QCOMPARE(reader->layoutRows(),sourceRows);QVERIFY(originalPage);QCOMPARE(visualItem(window->contentItem(),"pdfPage"+QString::number(ownerPage)),originalPage.data());
        if(mode=="Facing") {
            const int mate=ownerPage%2?ownerPage+1:ownerPage-1;const auto source=sourcePages[mate].toMap();
            QVERIFY(source.value("height")!=sourcePages[ownerPage].toMap().value("height"));
            auto *item=visualItem(window->contentItem(),"pdfPage"+QString::number(mate));QVERIFY(item);
            QCOMPARE(item->height(),source.value("height").toDouble()*window->property("zoom").toDouble());
        }
        QPointer<QQuickItem> question=window->findChild<QQuickItem *>("aiRegionQuestion");QVERIFY(question);question->forceActiveFocus();for(const char letter:QByteArray("draft retained"))QTest::keyClick(window,letter);
        QTRY_COMPARE(reader->aiRegion().value("question").toString(),QString("draft retained"));const auto captureId=reader->aiRegion().value("history_id");
        QVERIFY(navigate(0,0));QTest::qWait(80);QVERIFY(card->property("opened").toBool());QVERIFY(question);QCOMPARE(question->property("text").toString(),QString("draft retained"));
        QVERIFY(navigate(ownerPage,0));QVERIFY(QMetaObject::invokeMethod(card,"open"));QTRY_VERIFY(!card->property("needsReveal").toBool());QVERIFY(question);QCOMPARE(reader->aiRegion().value("history_id"),captureId);
        auto *paperCard=qobject_cast<QQuickItem *>(card);QVERIFY(paperCard);auto *canvas=paperCard->parentItem();
        canvas->forceActiveFocus();QTRY_VERIFY(!question->hasActiveFocus());QTest::qWait(30);
        const auto currentPlan=reader->aiRegionPaper();const auto ownerRow=currentPlan.value("card_row").toInt();const auto gapLocal=currentPlan.value("gap_top").toDouble()-currentPlan.value("rows").toList()[ownerRow].toMap().value("top").toDouble();
        QVERIFY(QMetaObject::invokeMethod(canvas,"positionAnchor",Q_ARG(QVariant,QVariantMap({{"page",ownerPage},{"y",gapLocal+90}})),Q_ARG(QVariant,0)));
        const double cardPoint=200;
        QTRY_VERIFY_WITH_TIMEOUT(paperCard->y()+cardPoint>0 && paperCard->y()+cardPoint<canvas->height(),3000);
        const double viewY=paperCard->y()+cardPoint;
        const bool lateLayout=QByteArray(QTest::currentDataTag()).endsWith("-late-layout");
        auto nudges=std::make_shared<int>(0);QPointer<QQuickItem> list=visualItem(window->contentItem(),"pageList");QVERIFY(list);
        if(lateLayout)connect(reader,&ReaderController::aiRegionPaperChanged,window,[reader,window,list,nudges]{
            if(*nudges || reader->aiRegionPaper().value("loading").toBool())return;
            *nudges=1;
            // Simulate a queued virtual-origin adjustment after the first plan restore.
            // Both callbacks are owned by this test window and never alter source rows.
            QTimer::singleShot(0,window,[window,list,nudges]{QTimer::singleShot(0,window,[list,nudges]{
                if(list){list->setProperty("contentY",list->property("contentY").toDouble()+2.375);*nudges=2;}
            });});
        });
        const auto fitting=reader->fitPresentation();
        const double expectedTail=foot && ownerPage==reader->pageCount()-1 ? fitting.value("inset").toDouble()*window->property("zoom").toDouble() : 0;
        for(const double zoom:{1.35,.9,1.0}) {
            if(zoom==.9){question->forceActiveFocus();QTRY_VERIFY(question->hasActiveFocus());}
            QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,zoom),Q_ARG(QVariant,paperCard->x()+paperCard->width()*.4),Q_ARG(QVariant,viewY)));
            QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegionPaper().value("loading").toBool() && qAbs(reader->aiRegionPaper().value("card").toMap().value("gap_pt").toDouble()*window->property("zoom").toDouble()-paperCard->height())<.01,10000);
            if(lateLayout)QTRY_COMPARE_WITH_TIMEOUT(*nudges,2,3000);
            QTRY_VERIFY2_WITH_TIMEOUT(qAbs(paperCard->y()+cardPoint-viewY)<.1,qPrintable(QString("zoom=%1 expectedY=%2 actualY=%3 height=%4 contentY=%5 originY=%6 pixelAligned=%7").arg(zoom).arg(viewY).arg(paperCard->y()+cardPoint).arg(paperCard->height()).arg(list->property("contentY").toDouble()).arg(list->property("originY").toDouble()).arg(list->property("pixelAligned").toBool())),3000);
            QVERIFY(question);QCOMPARE(question->property("text").toString(),QString("draft retained"));
            QVERIFY(canvas->property("paperTailPixels").toDouble()>=0 && canvas->property("paperTailPixels").toDouble()<=canvas->height());
            QVERIFY(std::abs(canvas->property("paperTailPixels").toDouble()-expectedTail)<.01);
        }
        const int destination=ownerPage<10?10:2;
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.15),Q_ARG(QVariant,paperCard->x()+paperCard->width()*.4),Q_ARG(QVariant,viewY)));
        QVERIFY(navigate(destination,80));QCOMPARE(canvas->property("paperTailPixels").toDouble(),0.0);QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto navigated=view.workspace.viewState(reader);
        QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegionPaper().value("loading").toBool() && qAbs(reader->aiRegionPaper().value("card").toMap().value("gap_pt").toDouble()*window->property("zoom").toDouble()-paperCard->height())<.01,10000);
        QTest::qWait(30);QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto before=view.workspace.viewState(reader);
        QCOMPARE(before.value("viewportAnchor").toMap().value("page"),navigated.value("viewportAnchor").toMap().value("page"));
        // ListView rounds recreated row origins to view pixels at fractional zoom.
        QVERIFY2(qAbs(before.value("viewportAnchor").toMap().value("y").toDouble()-navigated.value("viewportAnchor").toMap().value("y").toDouble())<1.01/window->property("zoom").toDouble(),qPrintable(QString("navigation anchor moved %1 -> %2").arg(navigated.value("viewportAnchor").toMap().value("y").toDouble()).arg(before.value("viewportAnchor").toMap().value("y").toDouble())));
        QVERIFY(QMetaObject::invokeMethod(card,"close"));QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto after=view.workspace.viewState(reader);
        QVERIFY2(qAbs(before.value("offset").toDouble()-after.value("offset").toDouble())<1.01,qPrintable(QString("source offset moved %1 -> %2").arg(before.value("offset").toDouble()).arg(after.value("offset").toDouble())));
        QCOMPARE(reader->pages(),sourcePages);QCOMPARE(reader->layoutRows(),sourceRows);QCOMPARE(server.requests.size(),0);
        reader->clearAiRegion();QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);
    }
    void offscreenNoteBadgesReleaseTheirPaintObjects() {
        NativeCorpus::Viewer view;QVERIFY(view.window);QQmlComponent component(&view.engine);
        component.setData(R"(import QtQuick
            import LyraReader 1.0
            Item {
                width:700;height:700
                property alias notes:notes
                LyraReaderTheme { id:theme }
                QtObject {
                    id:reader
                    property var textPages:({})
                    property int documentGeneration:1
                    signal noteMarkersReady(double request,int page,var markers,string error)
                }
                QtObject {
                    id:fakeApp
                    property var currentReader:reader
                    property var placedTextEditor:null
                    property var selectedAnnotation:null
                    property var annotationDraft:null
                    property var erasePreview:[]
                    property var eraseDraft:[]
                    property real zoom:1
                    property string paperAppearance:"original"
                    property var colors:theme
                    property string annotationFont:"sans-serif"
                    property var annotations:[{id:"near",page:0,kind:"stickyNote",rect:{x:20,y:20,width:24,height:24},visible:true},
                        {id:"far",page:0,kind:"stickyNote",rect:{x:500,y:500,width:24,height:24},visible:true}]
                }
                AnnotationsLayer { id:notes;anchors.fill:parent;app:fakeApp;page:0;visibleRegion:Qt.rect(0,0,100,100) }
            })",QUrl("qrc:/qml/NoteVisibilityCheck.qml"));
        QScopedPointer<QObject> object(component.create());QVERIFY2(object,qPrintable(component.errorString()));auto *item=qobject_cast<QQuickItem *>(object.data());QVERIFY(item);item->setParentItem(view.window->contentItem());
        auto *notes=object->property("notes").value<QObject *>();QVERIFY(notes);
        QTRY_VERIFY(visualItem(item,"foldedNoteBadge_near"));QVERIFY(!visualItem(item,"foldedNoteBadge_far"));
        notes->setProperty("visibleRegion",QRectF(0,0,700,700));QTRY_VERIFY(visualItem(item,"foldedNoteBadge_far"));
        notes->setProperty("visibleRegion",QRectF(0,0,100,100));QTRY_VERIFY(!visualItem(item,"foldedNoteBadge_far"));QVERIFY(visualItem(item,"foldedNoteBadge_near"));
    }
    void readingANoteAndEnteringEditPreserveRawTextUntilInput() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/raw-note.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        const auto raw=QString::fromUtf8("First\r\nSecond\rThird\u2029中文  ");
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","stickyNote"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",80},{"y",90},{"width",22},{"height",22}}},{"fontSize",14},{"color","#88611Bff"},{"note",raw}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto annotations=[&]{return reader->data().value("marks").toMap().value("annotations").toList();};QCOMPARE(annotations().size(),1);QCOMPARE(annotations()[0].toMap().value("note").toString(),raw);
        const auto annotation=window->property("annotations").value<QJSValue>().toVariant().toList().first();QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,annotation),Q_ARG(QVariant,false)));
        auto *body=window->findChild<QQuickItem *>("annotationNoteBody");auto *editor=window->findChild<QObject *>("placedTextEditing");QVERIFY(body && editor);QTRY_VERIFY(body->isVisible() && body->property("readOnly").toBool());body->forceActiveFocus();QTest::keyClick(window,Qt::Key_Return);
        QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool(),10000);QTest::qWait(650);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(annotations()[0].toMap().value("note").toString(),raw);QCOMPARE(editor->property("text").toString(),raw);
        QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY_WITH_TIMEOUT(!editor->property("active").toBool(),10000);QCOMPARE(annotations()[0].toMap().value("note").toString(),raw);
    }
    void inlineNoteLookupsWarmEvictedVisibleTextAndDropOldSources() {
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf"));QTRY_VERIFY(reader.pageCount()==9 && !reader.loading() && !reader.pendingCommands());
        reader.requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);const auto chars=reader.textPages().value("0").toMap().value("chars").toList();
        QVariantMap first,last;for(const auto &v:chars){const auto c=v.toMap();if(c.value("width_pt").toDouble()<=0 || c.value("height_pt").toDouble()<=0)continue;if(first.isEmpty())first=c;else if(c.value("x_pt").toDouble()>first.value("x_pt").toDouble()+30 && qAbs(c.value("y_pt").toDouble()-first.value("y_pt").toDouble())<2){last=c;break;}}QVERIFY(!last.isEmpty());
        const QVariantMap box{{"x",last.value("x_pt")},{"y",last.value("y_pt")},{"width",last.value("width_pt")},{"height",last.value("height_pt")}};
        const QVariantList entries{QVariantMap{{"id","synthetic-comment"},{"boxes",QVariantList{box}}}};
        QSignalSpy ready(&reader,&ReaderController::noteMarkersReady);reader.requestNoteMarkers(0,entries);QTRY_COMPARE_WITH_TIMEOUT(ready.size(),1,10000);QVERIFY(ready[0][3].toString().isEmpty());const auto baseline=ready[0][2].toList();QVERIFY(!baseline.isEmpty());
        auto source=reader.renderSource();QString error;for(int page=1;page<9;++page)source->query({{"op","text"},{"page",page}},&error);QVERIFY(error.isEmpty());
        const auto cold=source->query({{"op","note_markers"},{"page",0},{"entries",entries}},&error).toMap();QVERIFY(error.isEmpty());QVERIFY(!cold.value("prepared").toBool());
        reader.requestNoteMarkers(0,entries);QTRY_COMPARE_WITH_TIMEOUT(ready.size(),2,10000);QVERIFY(ready[1][3].toString().isEmpty());QCOMPARE(ready[1][2].toList(),baseline);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.findChildren<QFutureWatcherBase *>().size(),0,10000);ready.clear();
        auto *pool=QThreadPool::globalInstance();const auto oldLimit=pool->maxThreadCount();pool->setMaxThreadCount(1);
        QSemaphore entered,release;auto held=QtConcurrent::run([&]{entered.release();release.acquire();});auto restore=qScopeGuard([&]{release.release();pool->setMaxThreadCount(oldLimit);held.waitForFinished();});QVERIFY(entered.tryAcquire(1,3000));
        reader.requestNoteMarkers(0,entries);reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));
        release.release();pool->setMaxThreadCount(oldLimit);held.waitForFinished();restore.dismiss();
        QTRY_VERIFY_WITH_TIMEOUT(reader.pageCount()==1 && !reader.loading() && !reader.pendingCommands(),10000);QCOMPARE(ready.size(),0);
    }
    void replySidebarRowsJumpToTheirRootAndRetainReplyIdentity() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/reply-roots.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/annotated-replies.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==2 && !reader->loading());QVERIFY(settleReaderViewport(window));
        const auto rows=[&]{return window->property("annotationThreads").value<QJSValue>().toVariant().toMap().value("rows").toList();};
        const auto row=[&](const QString &id){for(const auto &v:rows())if(v.toMap().value("annotation").toMap().value("id")==id)return v.toMap();return QVariantMap{};};
        const auto cross=row("nm:reply-cross-page");QCOMPARE(cross.value("rootID").toString(),QString("nm:parent-highlight"));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,1),Q_ARG(QVariant,20)));QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"annotations")));
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"annotationThreadRow_nm:reply-cross-page"),10000);auto *item=visualItem(window->contentItem(),"annotationThreadRow_nm:reply-cross-page");
        QVERIFY(QMetaObject::invokeMethod(item,"clicked"));QTRY_COMPARE(window->property("currentPage").toInt(),0);
        QCOMPARE(window->property("selectedSidebarAnnotationID").toString(),QString("nm:reply-cross-page"));QVERIFY(!window->property("selectedAnnotation").value<QJSValue>().toVariant().isValid());
        auto *paper=window->findChild<QObject *>("annotationNotePaperController");QVERIFY(paper);QVERIFY(!paper->property("opened").toBool());QVERIFY(item->property("highlighted").toBool());
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());
        reader->submit("file_adopt",{{"id","nm:parent-highlight"}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto adopted=reader->data().value("marks").toMap().value("annotations").toList().first().toMap();QCOMPARE(row("nm:reply-cross-page").value("rootID"),adopted.value("id"));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,1),Q_ARG(QVariant,20)));QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"activateAnnotationThreadRow",Q_ARG(QVariant,cross)));QTRY_COMPARE(window->property("currentPage").toInt(),0);
        QVERIFY(QMetaObject::invokeMethod(window,"activateAnnotationThreadRow",Q_ARG(QVariant,row("nm:reply-two"))));QCOMPARE(window->property("selectedSidebarAnnotationID").toString(),QString("nm:reply-two"));QVERIFY(!paper->property("opened").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"activateAnnotationThreadRow",Q_ARG(QVariant,row("nm:reply-to-hidden"))));QVERIFY(window->property("operationStatus").toString().contains("hidden"));
        reader->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));
        QTRY_VERIFY(reader->pageCount()==1 && !reader->loading());QVERIFY(window->property("selectedSidebarAnnotationID").toString().isEmpty());
    }
    void sameLayoutContentRevisionsKeepAWholePageUntilReplacementIsReady_data() {
        QTest::addColumn<QString>("layout");QTest::addColumn<QString>("edit");
        for(const auto &layout:QStringList{"Continuous","Facing"})for(const auto &edit:QStringList{"delete","image","blackout","erase"})QTest::newRow(qPrintable(layout+"-"+edit))<<layout<<edit;
    }
    void sameLayoutContentRevisionsKeepAWholePageUntilReplacementIsReady() {
        QFETCH(QString,layout);QFETCH(QString,edit);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("revision-continuity.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        if(layout=="Facing") {QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QSizeF(500,600),QPageSize::Point));pdf.setPageMargins(QMarginsF(0,0,0,0));QPainter painter(&pdf);QVERIFY(painter.isActive());painter.setFont(QFont("DejaVu Sans",16));painter.drawText(QPointF(72,100),"LyraReader fixture title");QVERIFY(pdf.newPage());painter.drawText(QPointF(72,100),"Second facing page");QVERIFY(painter.end());}
        QFile originalFile(path);QVERIFY(originalFile.open(QIODevice::ReadOnly));const auto originalBytes=originalFile.readAll();originalFile.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->resize(1100,850);if(qEnvironmentVariableIsSet("LYRA_READER_REVISION_DARK_NARROW")){window->setProperty("appearance","dark");window->setProperty("paperAppearance","night");}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==(layout=="Facing"?2:1) && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,layout)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,3.25),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));
        QPointer<PageItem> page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);
        QTRY_VERIFY_WITH_TIMEOUT(page->refined() && page->texturesReady(),15000);QVERIFY(settleRasterWork(reader));QVERIFY(page->loadedTileCount()>1);
        const auto capture=[&]{auto grab=page->grabToImage(QSize(300,400));if(!grab)return QImage{};QSignalSpy ready(grab.data(),&QQuickItemGrabResult::ready);if(ready.isEmpty() && !ready.wait(3000))return QImage{};return grab->image();};
        const auto saveImage=[&](const QImage &image,const QString &phase){const auto folder=qEnvironmentVariable("LYRA_READER_REVISION_SNAPSHOT_DIR");if(folder.isEmpty())return true;return QDir().mkpath(folder) && image.save(QDir(folder).filePath(layout.toLower()+"-"+edit+"-"+phase+".png"));};
        const auto before=capture();QVERIFY(!before.isNull());QVERIFY(saveImage(before,"before"));reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto objects=reader->data().value("content_objects").toMap();QVariantMap title;for(const auto &v:objects.value("items").toList())if((layout=="Facing" && v.toMap().value("kind")=="text") || v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY2(!title.isEmpty(),qPrintable(QString::fromUtf8(QJsonDocument::fromVariant(objects).toJson(QJsonDocument::Compact))));
        std::vector<std::unique_ptr<HeldRasterAdmission>> blocked;
        const auto hold=[&]{for(int i=0;i<RasterJobs::maximumQueued;++i){auto slot=std::make_unique<HeldRasterAdmission>();if(!slot->ticket)return false;blocked.push_back(std::move(slot));}return true;};
        QVERIFY(hold());const auto generation=reader->documentGeneration();const auto originalPages=reader->pages(),originalRows=reader->layoutRows();
        QVariantMap command{{"Delete",QVariantMap{{"revision",objects.value("revision")},{"target",title.value("id")}}}};
        if(edit=="image") {const auto image=scratch.filePath("continuity-colors.png");QImage pixels(8,8,QImage::Format_RGBA8888);pixels.fill(Qt::red);QVERIFY(pixels.save(image));command={{"InsertImage",QVariantMap{{"revision",objects.value("revision")},{"bounds",QVariantMap{{"x",72},{"y",65},{"width",220},{"height",80}}},{"image_path",image}}}};}
        else if(edit=="blackout" || edit=="erase")command={{"Redact",QVariantMap{{"revision",objects.value("revision")},{"bounds",title.value("bounds")},{"blackout",edit=="blackout"}}}};
        bool allowRaster=false;
        if(edit=="blackout" || edit=="erase") {reader->submit("content_redaction_preflight",{{"page",0},{"command",command}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));allowRaster=!reader->data().value("content_redaction_preflight").toList().isEmpty();}
        reader->submit("content_stage",{{"page",0},{"command",command},{"allow_raster",allowRaster}});
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(reader->documentGeneration()!=generation);
        QCOMPARE(reader->pages(),originalPages);QCOMPARE(reader->layoutRows(),originalRows);QCOMPARE(qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0")),page.data());QVERIFY(page->loaded());QVERIFY(page->revisionFallbackActive());QVERIFY(!page->refined());QVERIFY(!page->texturesReady());
        QCOMPARE(capture(),before);
        bool heldPartial=false;
        const auto partial=[&]{if(!heldPartial){heldPartial=hold();}};
        const auto tile=connect(reader,&ReaderController::tileReady,window,[&](int p){if(p==0)partial();});const auto base=connect(reader,&ReaderController::pageReady,window,[&](int p,double){if(p==0)partial();});
        blocked.clear();QTRY_VERIFY_WITH_TIMEOUT(heldPartial,10000);QVERIFY(!page->refined());QCOMPARE(capture(),before);QVERIFY(saveImage(capture(),"partial"));
        disconnect(tile);disconnect(base);blocked.clear();
        QTRY_VERIFY_WITH_TIMEOUT(page->refined() && page->texturesReady(),15000);const auto after=capture();QVERIFY(!after.isNull());QVERIFY(after!=before);QTRY_VERIFY(!page->revisionFallbackActive());QVERIFY(saveImage(after,"after"));
        // Exercise the actual row policy and shared transaction undo/redo, not a parallel history.
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleRasterWork(reader));QVERIFY(hold());const auto editedGeneration=reader->documentGeneration();
        QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_VERIFY_WITH_TIMEOUT(reader->documentGeneration()!=editedGeneration && !reader->pendingCommands(),15000);
        QVERIFY(page->revisionFallbackActive());QCOMPARE(capture(),after);blocked.clear();
        QTRY_VERIFY_WITH_TIMEOUT(page->refined() && page->texturesReady() && !page->revisionFallbackActive(),15000);const auto undone=capture();QVERIFY(undone!=after);
        QVERIFY(settleRasterWork(reader));QVERIFY(hold());const auto undoneGeneration=reader->documentGeneration();
        QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_VERIFY_WITH_TIMEOUT(reader->documentGeneration()!=undoneGeneration && !reader->pendingCommands(),15000);
        QVERIFY(page->revisionFallbackActive());QCOMPARE(capture(),undone);blocked.clear();
        QTRY_VERIFY_WITH_TIMEOUT(page->refined() && page->texturesReady() && !page->revisionFallbackActive(),15000);QVERIFY(capture()!=undone);
        QCOMPARE(window->property("layoutMode").toString(),layout);
        QVERIFY(originalFile.open(QIODevice::ReadOnly));QCOMPARE(originalFile.readAll(),originalBytes);originalFile.close();
        QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->hasUnsavedChanges(),15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QVERIFY(originalFile.open(QIODevice::ReadOnly));QVERIFY(originalFile.readAll()!=originalBytes);originalFile.close();reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && !reader->pendingCommands(),15000);QVERIFY(settleReaderViewport(window));
        page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);QTRY_VERIFY_WITH_TIMEOUT(page->refined() && page->texturesReady(),15000);QVERIFY(capture()!=before);
    }
    void revisionFallbackRetiresForFailuresPressureAndIdentityChanges_data() {
        QTest::addColumn<QString>("action");
        for(const auto &a:QStringList{"failure","resident-pressure","texture-pressure","hide","replace-url","rotation","paper","policy","reprime","second-edit","undo-pending"})QTest::newRow(qPrintable(a))<<a;
    }
    void revisionFallbackRetiresForFailuresPressureAndIdentityChanges() {
        QFETCH(QString,action);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("revision-lifetime.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;if(qEnvironmentVariableIsSet("LYRA_READER_REVISION_DARK_NARROW")){window->resize(700,600);window->setProperty("appearance","dark");window->setProperty("paperAppearance","night");}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));
        QPointer<PageItem> page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);QTRY_VERIFY_WITH_TIMEOUT(page->refined() && page->texturesReady(),15000);QVERIFY(settleRasterWork(reader));
        const auto capture=[&]{auto grab=page->grabToImage(QSize(300,400));if(!grab)return QImage{};QSignalSpy ready(grab.data(),&QQuickItemGrabResult::ready);if(ready.isEmpty() && !ready.wait(3000))return QImage{};return grab->image();};
        if(action=="reprime"){emit reader->rasterPressure(0);page->update();QVERIFY(!capture().isNull());}
        const auto before=capture();QVERIFY(!before.isNull());reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto objects=reader->data().value("content_objects").toMap();QVariantMap title;for(const auto &v:objects.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());
        std::vector<std::unique_ptr<HeldRasterAdmission>> blocked;for(int i=0;i<RasterJobs::maximumQueued;++i){auto slot=std::make_unique<HeldRasterAdmission>();QVERIFY(slot->ticket);blocked.push_back(std::move(slot));}
        if(action=="policy")page->setRevisionContinuityAllowed(false);
        const auto generation=reader->documentGeneration();reader->submit("content_stage",{{"page",0},{"command",QVariantMap{{"Delete",QVariantMap{{"revision",objects.value("revision")},{"target",title.value("id")}}}}}});
        QTRY_VERIFY_WITH_TIMEOUT(reader->documentGeneration()!=generation && !reader->pendingCommands(),15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(page);
        if(action=="policy"){QVERIFY(!page->revisionFallbackActive());QVERIFY(!page->loaded());page->setRevisionContinuityAllowed(true);}
        else {
            QVERIFY(page->revisionFallbackActive());QCOMPARE(capture(),before);
            if(action=="failure") {
                // This injects the controller's page-specific failure notification, not a
                // physical driver failure. A different page must not retire this snapshot.
                emit reader->rasterFailed(1);QVERIFY(page->revisionFallbackActive());emit reader->rasterFailed(0);QVERIFY(!page->revisionFallbackActive());QVERIFY(!page->loaded());QVERIFY(capture()!=before);
            }else if(action=="resident-pressure" || action=="texture-pressure") {
                const bool texture=action=="texture-pressure";const auto stats=RenderBudget::statistics();const auto key=texture?QString("textureBytes"):QString("residentBytes");const auto limit=texture?RenderBudget::textureLimit:RenderBudget::residentLimit;
                auto reserve=RenderBudget::reserve(texture?RenderBudget::Kind::Texture:RenderBudget::Kind::Resident,limit-stats.value(key).toLongLong()-1);QVERIFY(reserve);QSignalSpy pressure(reader,&ReaderController::rasterPressure);
                blocked.clear();QTRY_VERIFY_WITH_TIMEOUT(!page->revisionFallbackActive(),15000);
                if(texture)QVERIFY(RenderBudget::statistics().value("textureDenied").toLongLong()>stats.value("textureDenied").toLongLong());else QVERIFY(!pressure.isEmpty());
                QVERIFY(RenderBudget::statistics().value(key).toLongLong()<=limit);QVERIFY(capture()!=before);reserve.reset();
            }else if(action=="hide") {page->setResourceActive(false);QVERIFY(!page->revisionFallbackActive());QVERIFY(!page->loaded());page->setResourceActive(true);}
            else if(action=="replace-url") {reader->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));QTRY_VERIFY(reader->pageCount()==3 && !reader->loading());QVERIFY(!page || !page->revisionFallbackActive());}
            else if(action=="rotation") {const auto g=reader->documentGeneration();reader->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",1}}}}}});QTRY_VERIFY_WITH_TIMEOUT(reader->documentGeneration()!=g && !reader->pendingCommands(),15000);QVERIFY(!page || !page->revisionFallbackActive());}
            else if(action=="paper") {QVERIFY(page->configurePaper(reader->pages().first().toMap().value("height").toDouble(),20,40));QVERIFY(!page->revisionFallbackActive());page->clearPaperGeometry();}
            else if(action=="second-edit" || action=="undo-pending") {
                const auto g=reader->documentGeneration();
                if(action=="second-edit") {
                    reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto next=reader->data().value("content_objects").toMap();const auto items=next.value("items").toList();QVERIFY(!items.isEmpty());
                    reader->submit("content_stage",{{"page",0},{"command",QVariantMap{{"Delete",QVariantMap{{"revision",next.value("revision")},{"target",items.first().toMap().value("id")}}}}}});
                }else reader->submit("page_undo",{{"current_page",0},{"preserve_viewport",true}});
                QTRY_VERIFY_WITH_TIMEOUT(reader->documentGeneration()!=g && !reader->pendingCommands(),15000);QVERIFY(page && page->revisionFallbackActive());QCOMPARE(capture(),before);
            }
        }
        blocked.clear();auto *current=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(current);QTRY_VERIFY_WITH_TIMEOUT(current->refined() && current->texturesReady() && !current->revisionFallbackActive(),15000);
        // Hiding the final surface must release every previous-revision lease as well.
        current->setResourceActive(false);QVERIFY(!current->loaded());QVERIFY(!current->revisionFallbackActive());
    }
    void closingDuringARevisionReleasesTheOldSceneAndPixelLeases() {
        const auto resident=RenderBudget::statistics().value("residentBytes").toLongLong(),texture=RenderBudget::statistics().value("textureBytes").toLongLong();
        for(int round=0;round<3;++round) {
            {
                QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("close-revision.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
                NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(view.window));
                auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);QTRY_VERIFY_WITH_TIMEOUT(page->refined() && page->texturesReady(),15000);QVERIFY(settleRasterWork(reader));reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto objects=reader->data().value("content_objects").toMap(),first=objects.value("items").toList().first().toMap();
                std::vector<std::unique_ptr<HeldRasterAdmission>> held;for(int i=0;i<RasterJobs::maximumQueued;++i){auto ticket=std::make_unique<HeldRasterAdmission>();QVERIFY(ticket->ticket);held.push_back(std::move(ticket));}
                const auto generation=reader->documentGeneration();reader->submit("content_stage",{{"page",0},{"command",QVariantMap{{"Delete",QVariantMap{{"revision",objects.value("revision")},{"target",first.value("id")}}}}}});QTRY_VERIFY_WITH_TIMEOUT(reader->documentGeneration()!=generation && !reader->pendingCommands(),15000);QVERIFY(page->revisionFallbackActive());
            }
            QTRY_VERIFY_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong()<=resident,10000);
            QTRY_VERIFY_WITH_TIMEOUT(RenderBudget::statistics().value("textureBytes").toLongLong()<=texture,10000);
        }
    }
    void foldedNoteGlyphsHaveCompleteOpaqueArtworkAndBoundedTextures() {
        NativeCorpus::Viewer view;QVERIFY(view.window);QQmlComponent component(&view.engine);
        component.setData(R"(import QtQuick
            Item {
                width:64;height:64
                property alias badge:badge
                property alias theme:theme
                LyraReaderTheme { id:theme }
                NoteBadge { id:badge;objectName:"testNoteBadge";anchors.fill:parent;colors:theme }
            })",QUrl("qrc:/qml/NoteGlyphCheck.qml"));
        QScopedPointer<QObject> object(component.create());QVERIFY2(object,qPrintable(component.errorString()));
        auto *item=qobject_cast<QQuickItem *>(object.data());QVERIFY(item);item->setParentItem(view.window->contentItem());item->setPosition(QPointF(200,150));
        QTest::mouseMove(view.window,QPoint(view.window->width()-20,view.window->height()-20));
        auto *badge=visualItem(item,"testNoteBadge");QVERIFY(badge);auto *canvas=visualItem(badge,"noteBadgeCanvas");QVERIFY(canvas);
        // A non-null image can precede the render thread's queued completion event.
        // Keep the result alive until ready(), then read it on the GUI thread.
        const auto capture=[&]{QTest::qWait(80);auto grab=badge->grabToImage();if(!grab)return QImage{};QSignalSpy ready(grab.data(),&QQuickItemGrabResult::ready);if(ready.isEmpty() && !ready.wait(3000))return QImage{};return grab->image();};
        const auto sample=[](const QImage &image,double x,double y){return image.pixelColor(qFloor(x/24*image.width()),qFloor(y/24*image.height()));};
        auto normal=capture();QVERIFY(!normal.isNull());QCOMPARE(sample(normal,2,2).alpha(),0);QCOMPARE(sample(normal,19,19).alpha(),0);
        const auto paper=sample(normal,6,14);QVERIFY2(qAbs(paper.red()-245)<2 && qAbs(paper.green()-236)<2 && qAbs(paper.blue()-215)<2,qPrintable(paper.name()));QCOMPARE(paper.alpha(),255);
        const auto ink=sample(normal,10,8.25);QVERIFY(ink.red()<paper.red()-30);
        QTest::mouseMove(view.window,badge->mapToScene(QPointF(32,32)).toPoint());QTRY_VERIFY(badge->property("hovered").toBool());auto hovered=capture();QVERIFY(sample(hovered,6,14)!=paper);QTest::mouseMove(view.window,QPoint(view.window->width()-20,view.window->height()-20));QTRY_VERIFY(!badge->property("hovered").toBool());
        const auto windowRect=canvas->property("canvasWindow").toRectF();const auto canvasSize=canvas->property("canvasSize").toSizeF();QCOMPARE(windowRect.size(),canvasSize);
        auto *theme=object->property("theme").value<QObject *>();QVERIFY(theme);theme->setProperty("dark",true);QCOMPARE(capture(),normal);
        badge->setProperty("active",true);auto active=capture();QVERIFY(sample(active,6,14)!=paper);
        badge->setProperty("inlineComment",true);badge->setProperty("highlight",QColor::fromRgbF(.2,.4,1,.01));auto translucent=capture();QCOMPARE(sample(translucent,6,14).alpha(),255);
        badge->setProperty("highlight",QColor::fromRgbF(.2,.4,1,1));QCOMPARE(capture(),translucent);
        const auto dots=sample(translucent,8.375,9.875);QVERIFY(dots.red()<sample(translucent,6,14).red()-20);
        badge->setProperty("nightPaper",true);auto night=capture();QVERIFY(sample(night,6,14).red()<120);QCOMPARE(sample(night,6,14).alpha(),255);
        item->setWidth(2400);item->setHeight(2400);QCoreApplication::processEvents();QCOMPARE(canvas->property("canvasSize").toSizeF(),QSizeF(192,192));
        item->setWidth(64);item->setHeight(64);
    }
    void inlineCommentsReuseFullLineAnchorsWithoutAdoptingOrMovingPdfBytes() {
        QTest::failOnWarning(QRegularExpression(QStringLiteral(".*(TypeError:|Binding loop|ReferenceError:).*")));
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/inline-comments.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/annotated-replies.pdf",path));QFile pdf(path);QVERIFY(pdf.open(QIODevice::ReadOnly));const auto original=pdf.readAll();pdf.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==2 && !reader->loading());QVERIFY(settleReaderViewport(window));reader->requestText(0);
        const auto markers=[&]{return window->property("noteMarkerLayouts").value<QJSValue>().toVariant().toMap().value("0").toMap().value("markers").toList();};
        const auto marker=[&](const QString &id){for(const auto &m:markers())if(m.toMap().value("id").toString()==id)return m.toMap().value("rect").toMap();return QVariantMap{};};
        QTRY_VERIFY_WITH_TIMEOUT(!marker("nm:parent-highlight").isEmpty(),10000);const auto before=marker("nm:parent-highlight");
        QCOMPARE(before.value("width").toDouble(),24.0);QVERIFY(visualItem(window->contentItem(),"inlineNoteBadge_nm:parent-highlight"));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *sheet=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(sheet);
        QTRY_VERIFY_WITH_TIMEOUT(sheet->refined() && sheet->texturesReady(),10000);
        // Native mapping can still settle the first viewport and thumbnail demand.
        // Fence that work, then count only this reader, not other provider instances.
        QTest::qWait(250);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingRasters(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(sheet->refined() && sheet->texturesReady(),10000);
        const auto jobs=reader->completedRasters();const auto globalJobs=RasterJobs::statistics().value("completed");
        const double x=before.value("x").toDouble()+12,y=before.value("y").toDouble()+12;
        QVariant hit;QVERIFY(QMetaObject::invokeMethod(window,"annotationAt",Q_RETURN_ARG(QVariant,hit),Q_ARG(QVariant,0),Q_ARG(QVariant,x),Q_ARG(QVariant,y),Q_ARG(QVariant,false)));QCOMPARE(hit.toMap().value("id").toString(),QString("nm:parent-highlight"));
        QVERIFY(QMetaObject::invokeMethod(window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,x),Q_ARG(QVariant,y),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        auto *paper=window->findChild<QObject *>("annotationNotePaperController");auto *body=window->findChild<QQuickItem *>("annotationNoteBody");QVERIFY(paper && body);
        QTRY_VERIFY(body->isVisible());QVERIFY(body->property("readOnly").toBool());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());QTest::qWait(80);qInfo()<<"Note read raster counters"<<jobs<<reader->completedRasters()<<"global"<<globalJobs<<RasterJobs::statistics().value("completed");QCOMPARE(reader->completedRasters(),jobs);
        const auto anchor=paper->property("anchor").toRectF();QVERIFY(qAbs(anchor.width()-24*window->property("zoom").toDouble())<.01);
        const auto openShot=qEnvironmentVariable("LYRA_READER_INLINE_NOTE_OPEN_SNAPSHOT");if(!openShot.isEmpty())QVERIFY(window->grabWindow().save(openShot));
        QVERIFY(QMetaObject::invokeMethod(paper,"close"));
        auto *layer=window->property("noteMarkerLayouts").value<QJSValue>().toVariant().toMap().value("0").toMap().value("layer").value<QObject *>();QVERIFY(layer);
        QVERIFY(QQmlProperty::write(layer,"page",1));QVERIFY(markers().isEmpty());
        QVERIFY(QQmlProperty::write(layer,"page",0));QTRY_VERIFY_WITH_TIMEOUT(!marker("nm:parent-highlight").isEmpty(),10000);
        reader->submit("file_adopt",{{"id","nm:parent-highlight"}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto owned=reader->data().value("marks").toMap().value("annotations").toList().first().toMap();const auto id=owned.value("id").toString();
        QTRY_VERIFY_WITH_TIMEOUT(!marker(id).isEmpty(),10000);QCOMPARE(marker(id),before);
        QVERIFY(pdf.open(QIODevice::ReadOnly));QCOMPARE(pdf.readAll(),original);
        const auto shot=qEnvironmentVariable("LYRA_READER_INLINE_NOTES_SNAPSHOT");if(!shot.isEmpty())QVERIFY(window->grabWindow().save(shot));
    }
    void noteReadingDoesNotWriteAndInlineEditorsKeepTheirOwnText() {
        QTest::failOnWarning(QRegularExpression(QStringLiteral(".*TypeError:.*")));
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/note-paper.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QFile pdf(path);QVERIFY(pdf.open(QIODevice::ReadOnly));const auto original=pdf.readAll();pdf.close();
        QStringList ids;const QStringList texts{"FIRST_NOTE_ISOLATED","SECOND_NOTE_ISOLATED\n"+QString("A long separate note line.\n").repeated(32)};
        {ReaderController setup;setup.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(setup.pageCount()==1 && !setup.loading() && !setup.pendingCommands());for(int i=0;i<2;++i){setup.submit("mark_create",{{"entry",QVariantMap{{"kind","stickyNote"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",70+i*120},{"y",80+i*60},{"width",22},{"height",22}}},{"fontSize",14},{"color","#88611Bff"},{"note",texts[i]}}}});QTRY_COMPARE_WITH_TIMEOUT(setup.pendingCommands(),0,10000);}for(const auto &v:setup.data().value("marks").toMap().value("annotations").toList())ids.append(v.toMap().value("id").toString());}QCOMPARE(ids.size(),2);
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;if(qEnvironmentVariableIsSet("LYRA_READER_NOTE_PAPER_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(700,600);}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));
        const auto values=[&]{return reader->data().value("marks").toMap().value("annotations").toList();};const auto initial=values();QString cache;QDirIterator files(qEnvironmentVariable("LYRA_READER_DOCUMENT_CACHE_DIR"),{"annotations.json"},QDir::Files,QDirIterator::Subdirectories);while(files.hasNext()){const auto candidate=files.next();QFile f(candidate);if(f.open(QIODevice::ReadOnly) && f.readAll().contains(ids[0].toUtf8())){cache=candidate;break;}}QVERIFY(!cache.isEmpty());QFile f(cache);QVERIFY(f.open(QIODevice::ReadOnly));const auto cached=f.readAll();f.close();
        auto *body=window->findChild<QQuickItem *>("annotationNoteBody"),*panel=window->findChild<QQuickItem *>("annotationNotePaper");auto *editing=window->findChild<QObject *>("placedTextEditing");auto *scroll=window->findChild<QQuickItem *>("annotationNoteScroll"),*bar=window->findChild<QQuickItem *>("annotationNoteScrollBar");QVERIFY(body && panel && editing && scroll && bar);QSignalSpy commands(reader,&ReaderController::commandFinished);
        for(int index:{0,1,0,1}){QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,initial[index]),Q_ARG(QVariant,true)));QTRY_VERIFY_WITH_TIMEOUT(panel->isVisible(),10000);QTRY_COMPARE(body->property("text").toString(),texts[index]);QVERIFY(body->property("readOnly").toBool());QVERIFY(!editing->property("active").toBool());}
        QTRY_VERIFY(qAbs(bar->height()-scroll->height())<1);QTRY_VERIFY(qAbs(bar->x()+bar->width()-scroll->width())<1);
        QCOMPARE(values(),initial);QVERIFY(f.open(QIODevice::ReadOnly));QCOMPARE(f.readAll(),cached);f.close();for(const auto &row:commands)QVERIFY2(!row[1].toString().startsWith("mark_") && row[1].toString()!="file_adopt",qPrintable(row[1].toString()));
        auto *close=window->findChild<QQuickItem *>("closeReadingNote"),*cancel=window->findChild<QQuickItem *>("cancelReadingNote"),*done=window->findChild<QQuickItem *>("doneReadingNote");QVERIFY(close && cancel && done);QVERIFY(!window->findChild<QObject *>("editReadingNote"));QVERIFY(close->isVisible());QVERIFY(!cancel->isVisible() && !done->isVisible());QCOMPARE(qvariant_cast<QFont>(body->property("font")).pixelSize(),13);
        // The reading paper has only a corner Close. Editing exposes bottom actions,
        // and both actions return focus to the same unchanged reading body.
        body->forceActiveFocus();QTest::keyClick(window,Qt::Key_Return);QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool() && body->hasActiveFocus(),10000);QVERIFY(cancel->isVisible() && done->isVisible() && !close->isVisible());QVERIFY(done->mapToItem(panel,QPointF()).y()>body->mapToItem(panel,QPointF()).y()+80);QVERIFY(cancel->mapToItem(panel,QPointF()).y()+cancel->height()<=panel->height()+.1);
        const auto editSnapshot=qEnvironmentVariable("LYRA_READER_NOTE_EDIT_SNAPSHOT");if(!editSnapshot.isEmpty())QVERIFY(window->grabWindow().save(editSnapshot));
        QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);for(const char typed:QByteArray(" BOTTOM_CANCEL"))QTest::keyClick(window,typed);QTest::qWait(650);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(cancel,"clicked"));QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool() && body->property("readOnly").toBool() && body->hasActiveFocus(),10000);QCOMPARE(values(),initial);QVERIFY(close->isVisible());
        QTest::keyClick(window,Qt::Key_F2);QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool() && body->hasActiveFocus(),10000);QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);for(const char typed:QByteArray(" BOTTOM_DONE"))QTest::keyClick(window,typed);QVERIFY(QMetaObject::invokeMethod(done,"clicked"));QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool() && !reader->pendingCommands() && body->hasActiveFocus(),10000);QCOMPARE(values()[1].toMap().value("note").toString(),texts[1]+" BOTTOM_DONE");reader->submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(values(),initial);

        // The actual sidebar row reopens the first note in read mode without adopting it.
        QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"annotations")));QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"annotationThreadRow_"+ids[0]),10000);auto *row=visualItem(window->contentItem(),"annotationThreadRow_"+ids[0]);QVERIFY(row);QVERIFY(QMetaObject::invokeMethod(row,"clicked"));QTRY_COMPARE(body->property("text").toString(),texts[0]);QVERIFY(body->property("readOnly").toBool());QTRY_VERIFY_WITH_TIMEOUT(panel->isVisible(),10000);
        QCOMPARE(panel->width(),280.0);QCOMPARE(panel->height(),220.0);
        QVERIFY2(visualItem(window->contentItem(),"foldedNoteBadge_"+ids[0]),"Sticky notes use the shared folded-paper artwork");
        QTest::qWait(40);QTest::mouseMove(window,body->mapToScene(QPointF(12,12)).toPoint(),20);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,body->mapToScene(QPointF(12,12)).toPoint());QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool() && body->hasActiveFocus(),10000);QCOMPARE(body->property("text").toString(),texts[0]);QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);for(const char typed:QByteArray(" first-edit"))QTest::keyClick(window,typed);QTest::qWait(650);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);for(const char typed:QByteArray(" second-edit"))QTest::keyClick(window,typed);QTest::qWait(650);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::keyClick(window,Qt::Key_Return,Qt::ControlModifier);QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool(),10000);QCOMPARE(values()[0].toMap().value("note").toString(),texts[0]+" first-edit second-edit");QCOMPARE(values()[1],initial[1]);
        reader->submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(values(),initial);
        QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,initial[1]),Q_ARG(QVariant,true)));body->forceActiveFocus();QTest::keyClick(window,Qt::Key_F2);QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool() && body->hasActiveFocus(),10000);QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);for(const char typed:QByteArray(" CANCELLED_NOTE_DRAFT"))QTest::keyClick(window,typed);QTest::qWait(650);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool(),10000);QCOMPARE(values(),initial);QCOMPARE(body->property("text").toString(),texts[1]);
        const auto font=body->property("font");QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.6),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QCOMPARE(body->property("font"),font);QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,initial[0]),Q_ARG(QVariant,true)));QTRY_COMPARE(body->property("text").toString(),texts[0]);body->forceActiveFocus();QTest::keyClick(window,Qt::Key_Return);QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool(),10000);QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);for(const char typed:QByteArray(" SWITCHED_DRAFT"))QTest::keyClick(window,typed);QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,initial[1]),Q_ARG(QVariant,true)));QTRY_VERIFY_WITH_TIMEOUT(body->property("readOnly").toBool() && body->property("text").toString()==texts[1],10000);QCOMPARE(values()[0].toMap().value("note").toString(),texts[0]+" SWITCHED_DRAFT");QCOMPARE(values()[1],initial[1]);
        const auto screenshot=qEnvironmentVariable("LYRA_READER_NOTE_PAPER_SNAPSHOT");if(!screenshot.isEmpty())QVERIFY(window->grabWindow().save(screenshot));QVERIFY(pdf.open(QIODevice::ReadOnly));QCOMPARE(pdf.readAll(),original);
    }
    void fileNoteReadingOnlyAdoptsOnAnExplicitBodyEditAndSavesItsContents() {
        QTest::failOnWarning(QRegularExpression(QStringLiteral(".*TypeError:.*")));
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/file-note.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/annotated-notes.pdf",path));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));
        const auto all=window->property("annotations").value<QJSValue>().toVariant().toList();QVariantMap note;for(const auto &v:all)if(v.toMap().value("kind")=="stickyNote"){note=v.toMap();break;}QVERIFY(!note.isEmpty());QVERIFY(note.value("foreign").toBool());const auto fileId=note.value("id").toString();auto *body=window->findChild<QQuickItem *>("annotationNoteBody");auto *editing=window->findChild<QObject *>("placedTextEditing");QVERIFY(body && editing);
        QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,note),Q_ARG(QVariant,true)));QTRY_VERIFY_WITH_TIMEOUT(body->isVisible(),10000);QCOMPARE(body->property("text").toString(),note.value("note").toString());QVERIFY(body->property("readOnly").toBool());QVERIFY(!reader->hasUnsavedChanges());QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().size(),0);QVERIFY(!editing->property("active").toBool());
        QTest::qWait(40);QTest::mouseMove(window,body->mapToScene(QPointF(12,12)).toPoint(),20);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,body->mapToScene(QPointF(12,12)).toPoint());QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool() && body->hasActiveFocus(),10000);const auto adopted=reader->data().value("marks").toMap().value("annotations").toList();QCOMPARE(adopted.size(),1);QCOMPARE(adopted.first().toMap().value("fileIdentity").toString(),fileId);QTest::keyClick(window,Qt::Key_A,Qt::ControlModifier);for(const char typed:QByteArray("SAVED_NOTE_AFTER_EXPLICIT_EDIT"))QTest::keyClick(window,typed);QTest::keyClick(window,Qt::Key_Return,Qt::ControlModifier);QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool() && !reader->pendingCommands(),10000);QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);file.close();
        reader->submit("document_save");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());bool found=false;for(const auto &v:reader->data().value("marks").toMap().value("file_annotations").toList())if(v.toMap().value("contents").toString()=="SAVED_NOTE_AFTER_EXPLICIT_EDIT")found=true;QVERIFY(found);
    }
    void newNotesMarkupAndRotatedVirtualPagesKeepOneAnchoredPaper() {
        QTest::failOnWarning(QRegularExpression(QStringLiteral(".*TypeError:.*")));
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/note-pages.pdf";
        {QPdfWriter writer(path);writer.setResolution(72);QPainter paint(&writer);for(int page=0;page<9;++page){if(page)QVERIFY(writer.newPage());paint.drawText(QPointF(60,80),QString("Public note page %1 with text for markup.").arg(page+1));}QVERIFY(paint.end());}
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==9 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));auto *body=window->findChild<QQuickItem *>("annotationNoteBody"),*panel=window->findChild<QQuickItem *>("annotationNotePaper");auto *editing=window->findChild<QObject *>("placedTextEditing");QVERIFY(body && panel && editing);
        const auto clickPage=[&]{window->setProperty("secondaryRow","annotate");window->setProperty("annotationTool","stickyNote");return QMetaObject::invokeMethod(window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,80.0),Q_ARG(QVariant,110.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0));};
        QVERIFY(clickPage());QTRY_VERIFY_WITH_TIMEOUT(panel->isVisible() && !body->property("readOnly").toBool() && body->hasActiveFocus(),10000);for(const char typed:QByteArray("CANCEL_NEW_NOTE"))QTest::keyClick(window,typed);QTest::qWait(650);QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool() && !reader->pendingCommands(),10000);QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());QVERIFY(!panel->isVisible());
        QVERIFY(clickPage());QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool() && body->hasActiveFocus(),10000);for(const char typed:QByteArray("STICKY_KEPT_FOR_ROTATIONS"))QTest::keyClick(window,typed);QTest::keyClick(window,Qt::Key_Return,Qt::ControlModifier);QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool() && !reader->pendingCommands(),10000);
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","highlight"},{"page",0},{"start",0},{"end",4},{"color","#E8BC5552"},{"note","MARKUP_COMMENT"}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap mark;for(const auto &v:reader->data().value("marks").toMap().value("annotations").toList())if(v.toMap().value("kind")=="highlight")mark=v.toMap();QVERIFY(!mark.isEmpty());QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,mark),Q_ARG(QVariant,true)));QTRY_VERIFY(panel->isVisible());QCOMPARE(body->property("text").toString(),QString("MARKUP_COMMENT"));body->forceActiveFocus();QTest::keyClick(window,Qt::Key_F2);QTRY_VERIFY_WITH_TIMEOUT(!body->property("readOnly").toBool() && body->hasActiveFocus(),10000);QTest::keyClick(window,Qt::Key_A,Qt::ControlModifier);for(const char typed:QByteArray("MARKUP_EDITED_WITHOUT_GEOMETRY"))QTest::keyClick(window,typed);QTest::keyClick(window,Qt::Key_Return,Qt::ControlModifier);QTRY_VERIFY_WITH_TIMEOUT(!editing->property("active").toBool() && !reader->pendingCommands(),10000);
        QVariantMap changed;for(const auto &v:reader->data().value("marks").toMap().value("annotations").toList())if(v.toMap().value("id")==mark.value("id"))changed=v.toMap();auto expected=mark;expected["note"]="MARKUP_EDITED_WITHOUT_GEOMETRY";QCOMPARE(changed,expected);
        auto *list=window->findChild<QQuickItem *>("pageList");QVERIFY(list);const auto before=list->property("contentY").toDouble();const auto point=body->mapToScene(QPointF(12,12));QWheelEvent wheel(point,window->mapToGlobal(point),QPoint{},QPoint(0,-120),Qt::NoButton,Qt::NoModifier,Qt::NoScrollPhase,false);QCoreApplication::sendEvent(window,&wheel);QTest::qWait(80);QVERIFY(qAbs(list->property("contentY").toDouble()-before)<.01);
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,8),Q_ARG(QVariant,0)));QTRY_VERIFY(!panel->isVisible());QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTRY_VERIFY_WITH_TIMEOUT(panel->isVisible(),10000);QCOMPARE(body->property("text").toString(),QString("MARKUP_EDITED_WITHOUT_GEOMETRY"));
        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",80},{"width",300},{"height",100}},1));QTRY_VERIFY2_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),qPrintable(QJsonDocument::fromVariant(reader->aiRegion()).toJson(QJsonDocument::Compact)),10000);auto *card=window->findChild<QQuickItem *>("aiRegionCard");QVERIFY(card);QVERIFY(QMetaObject::invokeMethod(card,"open"));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegionPaper().contains("rows") && !reader->aiRegionPaper().value("loading").toBool(),10000);QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,changed),Q_ARG(QVariant,true)));QTRY_VERIFY(panel->isVisible());QCOMPARE(body->property("text").toString(),QString("MARKUP_EDITED_WITHOUT_GEOMETRY"));QVERIFY(panel->parentItem()->z()>card->z());QVERIFY(QMetaObject::invokeMethod(card,"close"));QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedReadingNotes() && !reader->pendingCommands(),10000);
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,"Facing")));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        // The real restore callback navigates while positionRestoring is still true.
        // A sidebar jump queued during that interval must follow the completed restore.
        {QVariantMap note;for(const auto &v:window->property("annotations").value<QJSValue>().toVariant().toList())if(v.toMap().value("note")=="STICKY_KEPT_FOR_ROTATIONS")note=v.toMap();QVERIFY(!note.isEmpty());window->setProperty("positionRestoring",true);QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,note),Q_ARG(QVariant,true)));QTest::qWait(25);QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,8),Q_ARG(QVariant,0)));window->setProperty("positionRestoring",false);QTRY_COMPARE_WITH_TIMEOUT(window->property("currentPage").toInt(),0,3000);QTRY_VERIFY_WITH_TIMEOUT(panel->isVisible(),3000);
        window->setProperty("positionRestoring",true);QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,note),Q_ARG(QVariant,true)));QTest::qWait(25);QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,8),Q_ARG(QVariant,0)));window->setProperty("positionRestoring",false);QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,7),Q_ARG(QVariant,0)));QTRY_VERIFY_WITH_TIMEOUT(!window->findChild<QObject *>("annotationNotePaperController")->property("revealPending").toBool(),3000);QCOMPARE(window->property("currentPage").toInt(),7);QVERIFY(!panel->isVisible());QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));}
        for(int turn=0;turn<4;++turn){reader->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",1}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);const auto all=window->property("annotations").value<QJSValue>().toVariant().toList();QVariantMap note;for(const auto &v:all)if(v.toMap().value("kind")=="stickyNote" && v.toMap().value("note")=="STICKY_KEPT_FOR_ROTATIONS"){note=v.toMap();break;}QVERIFY(!note.isEmpty());QVERIFY(QMetaObject::invokeMethod(window,"selectAnnotation",Q_ARG(QVariant,note),Q_ARG(QVariant,true)));QTRY_VERIFY2_WITH_TIMEOUT(panel->isVisible(),qPrintable(QString("turn=%1 note=%2 pages=%3 zoom=%4 y=%5 status=%6").arg(turn).arg(QString::fromUtf8(QJsonDocument::fromVariant(note).toJson(QJsonDocument::Compact))).arg(QString::fromUtf8(QJsonDocument::fromVariant(reader->pages()).toJson(QJsonDocument::Compact))).arg(window->property("zoom").toDouble()).arg(list->property("contentY").toDouble()).arg(window->property("operationStatus").toString()+" paperOpen="+window->findChild<QObject *>("annotationNotePaperController")->property("opened").toString()+" current="+window->findChild<QObject *>("annotationNotePaperController")->property("current").toString()+" anchor="+window->findChild<QObject *>("annotationNotePaperController")->property("anchor").toString())),10000);QCOMPARE(body->property("text").toString(),QString("STICKY_KEPT_FOR_ROTATIONS"));QVERIFY(body->property("readOnly").toBool());QVERIFY(panel->x()>=0 && panel->y()>=0 && panel->x()+panel->width()<=panel->parentItem()->width()+.01 && panel->y()+panel->height()<=panel->parentItem()->height()+.01);}
    }
    void regionAutosaveThrottlesDraftsAndKeepsPartialStreamsBeforeClose() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/autosave.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile pdf(path);QVERIFY(pdf.open(QIODevice::ReadOnly));const auto original=pdf.readAll();pdf.close();
        MockChatServer server;QVERIFY(server.listen());server.responses.append({{MockChatServer::delta({{"content","DURABLE_PARTIAL"}}),MockChatServer::delta({{"content","_LATER"}}),QByteArray("data: [DONE]\n\n")},1400,200,true});
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));QPointer<ReaderController> reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),10000);
        const auto id=reader->aiRegion().value("history_id").toString(),image=reader->aiRegion().value("image_png").toString();
        // Continuous changes outlast the throttle period. A debounce-only implementation
        // cannot publish even the first snapshot until this input sequence stops.
        for(int i=0;i<16;++i){reader->setAiRegionQuestion(QString("CONTINUOUS_%1").arg(i));QTest::qWait(80);}
        QVERIFY2(reader->aiRegion().value("persisted").toBool(),"Continuous typing must not postpone every autosave");
        reader->setAiRegionQuestion("EXACT_SENT_QUESTION");QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedReadingNotes(),10000);
        QVERIFY(!reader->hasUnsavedChanges());const QVariantMap settings{{"baseUrl",server.baseUrl()},{"model","synthetic-autosave"},{"imageInput",false}};
        reader->prepareAiRegion(settings);QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty() && !reader->pendingCommands(),10000);const auto plan=reader->aiState().value("plan").toMap();
        QVERIFY(reader->startAi("local",plan));QTRY_VERIFY2_WITH_TIMEOUT(reader->aiState().value("output").toString().contains("DURABLE_PARTIAL"),qPrintable(QJsonDocument::fromVariant(reader->aiState()).toJson(QJsonDocument::Compact)),10000);
        QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().value("saved").toBool() && reader->aiState().value("running").toBool() && !reader->pendingCommands(),10000);
        QSignalSpy reads(reader,&ReaderController::commandFinished);const auto read=reader->submit("region_get",{{"id",id}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap partial;for(const auto &row:reads)if(row[0].toULongLong()==read)partial=row[2].toMap();
        QCOMPARE(partial.value("turns").toList().size(),1);const auto turn=partial.value("turns").toList().first().toMap();QCOMPARE(turn.value("state").toString(),QString("empty"));QVERIFY(turn.value("answer").toString().contains("DURABLE_PARTIAL"));const auto created=turn.value("createdAt");
        const auto wire=plan.value("parts").toList().first().toMap().value("wire_body").toString().toUtf8();QCOMPARE(server.requests.size(),1);QCOMPARE(server.requests.first().mid(server.requests.first().indexOf("\r\n\r\n")+4),wire);
        reader->setAiRegionQuestion("UNSENT_LOCAL_FOLLOWUP");QVERIFY(QMetaObject::invokeMethod(window,"requestCloseTab",Q_ARG(QVariant,0)));
        QTRY_VERIFY_WITH_TIMEOUT(reader.isNull(),15000);QCOMPARE(server.requests.size(),1);
        view.workspace.openFile(QUrl::fromLocalFile(path));reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        QSignalSpy reopened(reader,&ReaderController::commandFinished);const auto get=reader->submit("region_get",{{"id",id}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap saved;for(const auto &row:reopened)if(row[0].toULongLong()==get)saved=row[2].toMap();
        QCOMPARE(saved.value("attachment").toMap().value("png").toString(),image);QCOMPARE(saved.value("draftQuestion").toString(),QString("UNSENT_LOCAL_FOLLOWUP"));QCOMPARE(saved.value("turns").toList().size(),1);
        const auto final=saved.value("turns").toList().first().toMap();QCOMPARE(final.value("state").toString(),QString("cancelled"));QCOMPARE(final.value("createdAt"),created);QCOMPARE(final.value("question").toString(),QString("EXACT_SENT_QUESTION"));QVERIFY(final.value("answer").toString().contains("DURABLE_PARTIAL"));
        QVERIFY(pdf.open(QIODevice::ReadOnly));QCOMPARE(pdf.readAll(),original);
    }
    void regionAutosaveFailurePreservesDraftsAndDeferredClearKeepsLateInput() {
        QTest::failOnWarning(QRegularExpression(QStringLiteral(".*TypeError:.*")));
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/autosave-protection.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));QPointer<ReaderController> reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),10000);QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedReadingNotes(),10000);const auto id=reader->aiRegion().value("history_id").toString();
        QString cache;QDirIterator files(qEnvironmentVariable("LYRA_READER_DOCUMENT_CACHE_DIR"),{"region-conversations-v1.json"},QDir::Files,QDirIterator::Subdirectories);while(files.hasNext()){const auto candidate=files.next();QFile f(candidate);if(f.open(QIODevice::ReadOnly) && f.readAll().contains(id.toUtf8())){cache=candidate;break;}}QVERIFY(!cache.isEmpty());
        QFile f(cache);QVERIFY(f.open(QIODevice::ReadOnly));const auto baseline=f.readAll();f.close();const auto external=baseline+"\n ";{QSaveFile changed(cache);QVERIFY(changed.open(QIODevice::WriteOnly));QCOMPARE(changed.write(external),external.size());QVERIFY(changed.commit());}
        QSignalSpy commands(reader,&ReaderController::commandFinished);reader->setAiRegionQuestion("MUST_SURVIVE_WRITE_FAILURE");QTRY_VERIFY_WITH_TIMEOUT(reader->regionHistory().value("error").toString().contains("outside"),10000);QVERIFY(reader->hasUnsavedReadingNotes());QVERIFY(!reader->regionPersistencePending());const int count=commands.size();QTest::qWait(1000);QCOMPARE(commands.size(),count);
        QVERIFY(QMetaObject::invokeMethod(window,"requestCloseTab",Q_ARG(QVariant,0)));QTRY_COMPARE(window->property("closingTab").toInt(),-2);QVERIFY(reader && window->isVisible());reader->clearAiRegion();QVERIFY(reader->hasUnsavedReadingNotes());QCOMPARE(reader->aiRegion().value("question").toString(),QString("MUST_SURVIVE_WRITE_FAILURE"));QVERIFY(f.open(QIODevice::ReadOnly));QCOMPARE(f.readAll(),external);f.close();
        auto *card=window->findChild<QObject *>("aiRegionCard");QVERIFY(card);QVERIFY(QMetaObject::invokeMethod(card,"open"));auto *discard=window->findChild<QObject *>("discardFailedAiRegion"),*confirmation=window->findChild<QObject *>("discardAiRegionConfirmation");QVERIFY(discard && confirmation);
        QVERIFY(QMetaObject::invokeMethod(discard,"clicked"));QTRY_VERIFY(confirmation->property("opened").toBool());QVERIFY(QMetaObject::invokeMethod(confirmation,"reject"));QVERIFY(reader->hasUnsavedReadingNotes());
        const auto stale=reader->regionDiscardContext();QVERIFY(!stale.isEmpty());QVERIFY(QMetaObject::invokeMethod(discard,"clicked"));QTRY_VERIFY(confirmation->property("opened").toBool());reader->setAiRegionQuestion("LATE_INPUT_AFTER_REVIEW");QVERIFY(!reader->discardAiRegionChanges(stale));QVERIFY(clickDialogButton(window,confirmation,"Discard"));QVERIFY(reader->hasUnsavedReadingNotes());QCOMPARE(reader->aiRegion().value("question").toString(),QString("LATE_INPUT_AFTER_REVIEW"));
        QVERIFY(QMetaObject::invokeMethod(discard,"clicked"));QTRY_VERIFY(confirmation->property("opened").toBool());view.workspace.newTab();QTRY_VERIFY(!confirmation->property("opened").toBool());QVERIFY(reader->hasUnsavedReadingNotes());view.workspace.selectTab(0);QVERIFY(QMetaObject::invokeMethod(card,"open"));
        QVERIFY(QMetaObject::invokeMethod(discard,"clicked"));QTRY_VERIFY(confirmation->property("opened").toBool());QVERIFY(clickDialogButton(window,confirmation,"Discard"));QTRY_VERIFY(!reader->aiRegion().contains("image_png"));QVERIFY(!reader->hasUnsavedReadingNotes());QVERIFY(f.open(QIODevice::ReadOnly));QCOMPARE(f.readAll(),external);f.close();
        // Repair only this synthetic external edit. Explicit abandonment did not alter it.
        {QSaveFile repaired(cache);QVERIFY(repaired.open(QIODevice::WriteOnly));QCOMPARE(repaired.write(baseline),baseline.size());QVERIFY(repaired.commit());}QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),10000);QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedReadingNotes(),10000);

        reader->setAiRegionQuestion("CLEAR_SNAPSHOT");QVERIFY(reader->saveAiRegionNote());reader->clearAiRegion();reader->setAiRegionQuestion("LATE_TYPING_WINS");QTRY_VERIFY_WITH_TIMEOUT(!reader->hasUnsavedReadingNotes(),10000);QCOMPARE(reader->aiRegion().value("question").toString(),QString("LATE_TYPING_WINS"));QVERIFY(reader->aiRegion().contains("image_png"));reader->clearAiRegion();QTRY_VERIFY(!reader->aiRegion().contains("image_png"));
    }
    void regionAutosaveFlushesHiddenTabsAndEveryWindowBeforeGlobalQuit() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto aPath=scratch.path()+"/hidden-tab.pdf",bPath=scratch.path()+"/active-tab.pdf",cPath=scratch.path()+"/other-window.pdf";for(const auto &path:{aPath,bPath,cPath})QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer first,second;QVERIFY(first.window && second.window);first.workspace.openFile(QUrl::fromLocalFile(aPath));auto *a=first.workspace.activeReader();QTRY_VERIFY(a->pageCount()==1 && !a->loading() && !a->pendingCommands());QVERIFY(a->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(a->aiRegion().contains("image_png"),10000);a->setAiRegionQuestion("HIDDEN_TAB_LATEST");const auto aId=a->aiRegion().value("history_id").toString();
        first.workspace.newTab();QTRY_VERIFY_WITH_TIMEOUT(!a->hasUnsavedReadingNotes(),10000);QVERIFY(a!=first.workspace.activeReader());first.workspace.openFile(QUrl::fromLocalFile(bPath));auto *b=first.workspace.activeReader();second.workspace.openFile(QUrl::fromLocalFile(cPath));auto *c=second.workspace.activeReader();
        for(auto *reader:{b,c}){QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(reader->aiRegion().contains("image_png"),10000);}
        b->setAiRegionQuestion("ACTIVE_TAB_QUIT_LATEST");c->setAiRegionQuestion("OTHER_WINDOW_QUIT_LATEST");const auto bId=b->aiRegion().value("history_id").toString(),cId=c->aiRegion().value("history_id").toString();
        first.window->hide();auto *quit=second.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);second.workspace.requestQuit();QTRY_COMPARE_WITH_TIMEOUT(accepted.size(),1,15000);QVERIFY(!quit->busy());QVERIFY(!first.window->isVisible() && !second.window->isVisible());
        const QList<QString> paths{aPath,bPath,cPath},ids{aId,bId,cId},drafts{"HIDDEN_TAB_LATEST","ACTIVE_TAB_QUIT_LATEST","OTHER_WINDOW_QUIT_LATEST"};
        for(int i=0;i<paths.size();++i){ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(paths[i]));QTRY_VERIFY(reopened.pageCount()==1 && !reopened.loading() && !reopened.pendingCommands());QSignalSpy reads(&reopened,&ReaderController::commandFinished);const auto get=reopened.submit("region_get",{{"id",ids[i]}});QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QVariantMap saved;for(const auto &row:reads)if(row[0].toULongLong()==get)saved=row[2].toMap();QCOMPARE(saved.value("draftQuestion").toString(),drafts[i]);QVERIFY(!saved.value("attachment").toMap().value("png").toString().isEmpty());QVERIFY(saved.value("turns").toList().isEmpty());}
    }
    void regionAutosaveSurvivesAbruptProcessExitWithAnUnfinishedAnswer() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/abrupt-exit.pdf",cache=scratch.path()+"/cache";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile pdf(path);QVERIFY(pdf.open(QIODevice::ReadOnly));const auto original=pdf.readAll();pdf.close();
        QProcess child;auto env=QProcessEnvironment::systemEnvironment();env.insert("QT_QPA_PLATFORM","offscreen");env.insert("QT_QUICK_BACKEND","software");env.remove("LYRA_READER_REQUIRE_NATIVE_QT");child.setProcessEnvironment(env);child.start(QCoreApplication::applicationFilePath(),{"--region-autosave-crash-child",path,cache});QVERIFY(child.waitForStarted(5000));QVERIFY(child.waitForFinished(30000));QCOMPARE(child.exitStatus(),QProcess::NormalExit);QVERIFY2(child.exitCode()==9,child.readAllStandardError().constData());
        QFile receipt(cache+"/autosave-child-receipt.json");QVERIFY(receipt.open(QIODevice::ReadOnly));const auto proof=QJsonDocument::fromJson(receipt.readAll()).object();QCOMPARE(proof.value("requests").toInt(),1);const auto id=proof.value("id").toString();QVERIFY(!id.isEmpty());
        const auto previous=qgetenv("LYRA_READER_DOCUMENT_CACHE_DIR");const auto restore=qScopeGuard([&]{qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",previous);});qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(reader.pageCount()==1 && !reader.loading() && !reader.pendingCommands());QSignalSpy reads(&reader,&ReaderController::commandFinished);const auto get=reader.submit("region_get",{{"id",id}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVariantMap saved;for(const auto &row:reads)if(row[0].toULongLong()==get)saved=row[2].toMap();
        QCOMPARE(saved.value("draftQuestion").toString(),QString("SENT_BEFORE_ABRUPT_EXIT"));QCOMPARE(QString::fromLatin1(QCryptographicHash::hash(QByteArray::fromBase64(saved.value("attachment").toMap().value("png").toByteArray()),QCryptographicHash::Sha256).toHex()),proof.value("png_sha256").toString());QCOMPARE(saved.value("turns").toList().size(),1);const auto turn=saved.value("turns").toList().first().toMap();QCOMPARE(turn.value("state").toString(),QString("empty"));QVERIFY(turn.value("answer").toString().contains("RECOVERED_PARTIAL"));QCOMPARE(turn.value("id").toString(),proof.value("turn").toString());
        reader.submit("region_list");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(reader.reopenAiRegion(id,reader.regionHistory().value("revision").toString()));QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(reader.aiRegion().value("saved").toBool());QVERIFY(!reader.hasUnsavedReadingNotes());QVERIFY(!reader.aiState().value("running").toBool());QCOMPARE(reader.aiState().value("results").toMap().value("region").toMap().value("state").toString(),QString("empty"));
        const auto blocked=reader.submit("region_snapshot",{{"id",id},{"draft","FORGED_DRAFT"},{"turn",QVariantMap{{"id",proof.value("turn").toString()},{"question","SENT_BEFORE_ABRUPT_EXIT"},{"answer",turn.value("answer").toString()+" forged"},{"state","finished"}}}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);bool rejected=false;for(const auto &row:reads)if(row[0].toULongLong()==blocked)rejected=row[3].toString().contains("different contents");QVERIFY(rejected);
        QVERIFY(pdf.open(QIODevice::ReadOnly));QCOMPARE(pdf.readAll(),original);
    }
    void regionContinuationReopensFrozenSnapshotsAndProtectsPendingPreviews() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("continue-region.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile originalFile(path);QVERIFY(originalFile.open(QIODevice::ReadOnly));const auto original=originalFile.readAll();originalFile.close();
        MockChatServer server;QVERIFY(server.listen());server.responses.append({{MockChatServer::delta({{"content","COMPLETED_CONTEXT_ANSWER"}}),QByteArray("data: [DONE]\n\n")},20,200});
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        const QVariantMap settings{{"baseUrl",server.baseUrl()},{"model","synthetic-continuation"},{"imageInput",false}};window->setProperty("aiSettings",settings);
        QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        QVERIFY(reader->captureAiRegion(0,{{"x",60.125},{"y",55.0+1.0/3},{"width",420.75},{"height",180.5}},1));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegion().value("image_png").toString().isEmpty(),10000);
        const auto png=reader->aiRegion().value("image_png");const auto id=reader->aiRegion().value("history_id").toString();reader->setAiRegionQuestion("COMPLETED_CONTEXT_QUESTION");reader->prepareAiRegion(settings);
        QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto firstPlan=reader->aiState().value("plan").toMap();const auto firstBody=firstPlan.value("parts").toList().first().toMap().value("wire_body").toString().toUtf8();
        QVERIFY(reader->startAi("local",firstPlan));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QCOMPARE(server.requests.size(),1);QCOMPARE(server.requests.first().mid(server.requests.first().indexOf("\r\n\r\n")+4),firstBody);QVERIFY(reader->aiState().value("output").toString().contains("COMPLETED_CONTEXT_ANSWER"));
        // Preparing a follow-up durably keeps the previous turn before constructing its body.
        reader->setAiRegionQuestion("FOLLOWUP_NOT_SENT");reader->prepareAiRegion(settings);QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto body=reader->aiState().value("plan").toMap().value("parts").toList().first().toMap().value("wire_body").toString();QVERIFY(body.contains("COMPLETED_CONTEXT_ANSWER"));QVERIFY(body.contains("FOLLOWUP_NOT_SENT"));QCOMPARE(server.requests.size(),1);
        reader->setAiRegionQuestion("SNAPSHOT_DRAFT_QUERY");reader->prepareAiRegion(settings);reader->setAiRegionQuestion("LATEST_LOCAL_QUESTION");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->aiState().value("plan").toMap().isEmpty());QCOMPARE(reader->aiRegion().value("question").toString(),QString("LATEST_LOCAL_QUESTION"));QCOMPARE(server.requests.size(),1);
        reader->prepareAiRegion(settings);QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);body=reader->aiState().value("plan").toMap().value("parts").toList().first().toMap().value("wire_body").toString();QVERIFY(body.contains("LATEST_LOCAL_QUESTION"));QVERIFY(!body.contains("SNAPSHOT_DRAFT_QUERY"));
        reader->setAiRegionQuestion("CANCELLED_PREVIEW_DRAFT");reader->prepareAiRegion(settings);reader->invalidateAiPlan();QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->aiState().value("plan").toMap().isEmpty());QCOMPARE(server.requests.size(),1);
        QSignalSpy reads(reader,&ReaderController::commandFinished);const auto read=reader->submit("region_get",{{"id",id}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap stored;for(const auto &row:reads)if(row[0].toULongLong()==read)stored=row[2].toMap();QVERIFY(!stored.isEmpty());QCOMPARE(stored.value("turns").toList().size(),1);
        QString historyPath;QDirIterator historyFiles(qEnvironmentVariable("LYRA_READER_DOCUMENT_CACHE_DIR"),QStringList{"region-conversations-v1.json"},QDir::Files,QDirIterator::Subdirectories);while(historyFiles.hasNext()){const auto candidate=historyFiles.next();QFile record(candidate);if(record.open(QIODevice::ReadOnly) && record.readAll().contains(id.toUtf8())){historyPath=candidate;break;}}QVERIFY(!historyPath.isEmpty());QFile history(historyPath);QVERIFY(history.open(QIODevice::ReadOnly));const auto baseline=history.readAll();history.close();
        const auto external=baseline+"\n ";{QSaveFile changed(historyPath);QVERIFY(changed.open(QIODevice::WriteOnly));QCOMPARE(changed.write(external),external.size());QVERIFY(changed.commit());}
        reader->setAiRegionQuestion("DO_NOT_PREPARE_AFTER_FAILED_SAVE");reader->prepareAiRegion(settings);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->aiState().value("plan").toMap().isEmpty());QVERIFY(reader->hasUnsavedReadingNotes());QVERIFY(reader->aiState().value("status").toString().contains("outside"));QCOMPARE(server.requests.size(),1);QVERIFY(history.open(QIODevice::ReadOnly));QCOMPARE(history.readAll(),external);history.close();
        // Repair only this synthetic cache so its failed pending snapshot can be saved normally.
        {QSaveFile repaired(historyPath);QVERIFY(repaired.open(QIODevice::WriteOnly));QCOMPARE(repaired.write(baseline),baseline.size());QVERIFY(repaired.commit());}reader->dismissError();QVERIFY(reader->saveAiRegionNote());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->hasUnsavedReadingNotes());
        reader->submit("region_note",{{"id",id},{"text","KEPT_KNOWLEDGE_NOTE"}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);auto *notes=window->findChild<QObject *>("regionNotes");QVERIFY(notes);QVERIFY(QMetaObject::invokeMethod(notes,"load",Q_ARG(QVariant,id)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *continueNote=visualItem(window->contentItem(),"continueRegionConversation");QVERIFY(continueNote);QTRY_VERIFY(continueNote->isEnabled());QVERIFY(QMetaObject::invokeMethod(continueNote,"clicked"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->aiRegion().value("history_id").toString(),id);QCOMPARE(reader->aiRegion().value("image_png"),png);QCOMPARE(reader->aiRegion().value("completed_turn_count").toInt(),1);QVERIFY(reader->aiState().value("results").toMap().value("region").toMap().value("output").toString().contains("COMPLETED_CONTEXT_ANSWER"));QCOMPARE(server.requests.size(),1);
        reader->setAiRegionQuestion("AFTER_REOPEN_FOLLOWUP");reader->prepareAiRegion(settings);QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);body=reader->aiState().value("plan").toMap().value("parts").toList().first().toMap().value("wire_body").toString();QVERIFY(body.contains("COMPLETED_CONTEXT_ANSWER"));QVERIFY(body.contains("AFTER_REOPEN_FOLLOWUP"));QCOMPARE(server.requests.size(),1);
        reader->setAiRegionQuestion("LOCAL_TYPING_WINS");QVERIFY(reader->reopenAiRegion(id,reader->regionHistory().value("revision").toString()));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->aiRegion().value("question").toString(),QString("LOCAL_TYPING_WINS"));
        QVERIFY(reader->reopenAiRegion(id,reader->regionHistory().value("revision").toString()));reader->clearAiRegion();QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->aiRegion().contains("image_png"));QTRY_VERIFY(!window->findChild<QObject *>("aiRegionCard")->property("opened").toBool());
        QVERIFY(originalFile.open(QIODevice::ReadOnly));QCOMPARE(originalFile.readAll(),original);
    }
    void savedRegionNotesRetainCapturesLateDraftsAndKnowledgeAcrossReopen() {
        QTest::failOnWarning(QRegularExpression(QStringLiteral(".*exception occurred during delayed function evaluation.*")));
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/reading-notes.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        MockChatServer sentinel;QVERIFY(sentinel.listen());
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->setProperty("aiSettings",QVariantMap{{"baseUrl",sentinel.baseUrl()},{"model","notes-no-send"}});view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegion().value("image_png").toString().isEmpty(),10000);
        const auto id=reader->aiRegion().value("history_id").toString();const auto png=reader->aiRegion().value("image_png").toString();QVERIFY(!id.isEmpty());
        reader->setAiRegionQuestion("Initial local draft");QVERIFY(reader->saveAiRegionNote());reader->setAiRegionQuestion("Late draft is retained");
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->aiRegion().value("persisted").toBool());QVERIFY(!reader->aiRegion().value("saved").toBool());
        QVERIFY(reader->saveAiRegionNote());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->aiRegion().value("saved").toBool());QCOMPARE(reader->regionHistory().value("entries").toList().size(),1);QVERIFY(!reader->hasUnsavedChanges());
        reader->clearAiRegion();QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));auto *notes=window->findChild<QObject *>("regionNotes");QVERIFY(notes);QTRY_VERIFY(notes->property("visible").toBool());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(window->property("aiPanelMode").toString(),QString("notes"));QVERIFY(window->property("aiPanelVisible").toBool());
        auto *notesItem=qobject_cast<QQuickItem *>(notes);auto *dock=visualItem(window->contentItem(),"aiDock");auto *notesList=visualItem(window->contentItem(),"regionNotesList");QVERIFY(notesItem && dock && notesList);
        bool insideDock=false;for(auto *item=notesItem;item;item=item->parentItem())if(item==dock)insideDock=true;QVERIFY(insideDock);
        QTRY_VERIFY(notesItem->width()>240 && notesItem->width()<=dock->width());QTRY_VERIFY(notesItem->height()>300);QTRY_VERIFY(notesList->hasActiveFocus());
        auto *thumbnail=qobject_cast<CropItem *>(visualItem(window->contentItem(),"regionNoteThumbnail1"));QVERIFY2(thumbnail,"Saved list rows must show a bounded frozen capture thumbnail");QTRY_COMPARE_WITH_TIMEOUT(thumbnail->status(),1,10000);QVERIFY(!thumbnail->pixelSize().isEmpty());QVERIFY(qint64(thumbnail->pixelSize().width())*thumbnail->pixelSize().height()*4<=64*1024);QCOMPARE(sentinel.requests.size(),0);
        const auto historyBeforeThumbnailFailure=reader->regionHistory();QSignalSpy thumbnailFailures(reader,&ReaderController::commandFinished);const auto staleThumbnail=reader->submit("region_thumbnail",{{"id",id},{"expected_history_revision","obsolete-layout-fixture"}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);bool thumbnailRefused=false;for(const auto &row:thumbnailFailures)if(row[0].toULongLong()==staleThumbnail){thumbnailRefused=row[3].toString().contains("changed");}QVERIFY(thumbnailRefused);QCOMPARE(reader->regionHistory(),historyBeforeThumbnailFailure);QVERIFY2(reader->error().isEmpty(),"A retired thumbnail request must report to its owner without replacing document-wide errors");
        // Native key activation must reach a real list row, rather than calling load directly.
        QTRY_VERIFY(notesList->property("count").toInt()==1);QTest::keyClick(window,Qt::Key_Return);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto toMap=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>() ? v.value<QJSValue>().toVariant().toMap():v.toMap();};
        QTRY_COMPARE_WITH_TIMEOUT(toMap(notes->property("detail")).value("draftQuestion").toString(),QString("Late draft is retained"),10000);QCOMPARE(toMap(notes->property("detail")).value("attachment").toMap().value("png").toString(),png);
        QTRY_COMPARE_WITH_TIMEOUT(thumbnail->status(),0,10000);QVERIFY(!visualItem(window->contentItem(),"regionNoteSource1"));
        // Stress only the presentation with the storage source-count limit. These synthetic
        // pages are not provenance and the actual one-page reader must refuse their targets.
        auto *sourceStrip=visualItem(window->contentItem(),"regionNoteSources");QVERIFY(sourceStrip);const auto originalDetail=toMap(notes->property("detail"));auto layoutFixture=originalDetail;QVariantList manySources;for(int page=1;page<=4096;++page)manySources.append(page);layoutFixture.insert("verified_source_pages",QVariantList{QVariant::fromValue(manySources)});notes->setProperty("detail",layoutFixture);
        QTRY_COMPARE(sourceStrip->property("count").toInt(),4096);std::function<int(QQuickItem *)> sourceControls=[&](QQuickItem *item){bool number=false;item->objectName().mid(QStringLiteral("regionNoteSource").size()).toInt(&number);int count=number && item->objectName().startsWith("regionNoteSource") ? 1 : 0;for(auto *child:item->childItems())count+=sourceControls(child);return count;};QTRY_VERIFY(sourceControls(sourceStrip)>0);QVERIFY(sourceControls(sourceStrip)<32);
        sourceStrip->setProperty("currentIndex",4095);QTRY_VERIFY(visualItem(window->contentItem(),"regionNoteSource4096"));QVERIFY(sourceControls(sourceStrip)<32);const auto beforeJump=window->property("currentPage");QVERIFY(QMetaObject::invokeMethod(notes,"followSource",Q_ARG(QVariant,4096)));QCOMPARE(window->property("currentPage"),beforeJump);QVERIFY(window->property("operationStatus").toString().contains("unavailable"));notes->setProperty("detail",originalDetail);QTRY_COMPARE(sourceStrip->property("count").toInt(),0);window->setProperty("operationStatus",QString{});
        auto *crop=window->findChild<QObject *>("regionNoteImage");QVERIFY(crop);QTRY_COMPARE_WITH_TIMEOUT(crop->property("status").toInt(),1,10000);QVERIFY(qAbs(crop->property("width").toDouble()/crop->property("height").toDouble()-420.0/180.0)<.001);
        auto *continueNote=visualItem(window->contentItem(),"continueRegionConversation");QVERIFY(continueNote);QTRY_VERIFY(continueNote->isEnabled());QTest::keyClick(window,Qt::Key_L,Qt::ControlModifier);auto *shortcutPageField=visualItem(window->contentItem(),"pageNumber");QVERIFY(shortcutPageField);QTRY_VERIFY2(shortcutPageField->hasActiveFocus(),"The actual Go to Page shortcut must work from the reading-note detail");QTest::keyClick(window,Qt::Key_Backtab,Qt::ShiftModifier);auto *resizeHandle=visualItem(window->contentItem(),"aiPanelResizeHandle");QVERIFY(resizeHandle);QTRY_VERIFY(resizeHandle->hasActiveFocus());QTest::keyClick(window,Qt::Key_Backtab,Qt::ShiftModifier);QTRY_VERIFY2(continueNote->hasActiveFocus(),"Backward Tab through the resize handle must reach Continue conversation");QTest::keyClick(window,Qt::Key_Space);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);auto *restoredCard=window->findChild<QObject *>("aiRegionCard");QVERIFY(restoredCard);QTRY_VERIFY2(restoredCard->property("opened").toBool(),qPrintable(notes->property("readError").toString()+reader->error()));QCOMPARE(reader->aiRegion().value("history_id").toString(),id);QCOMPARE(reader->aiRegion().value("image_png").toString(),png);QCOMPARE(reader->aiRegion().value("question").toString(),QString("Late draft is retained"));QVERIFY(reader->aiRegion().value("saved").toBool());QCOMPARE(sentinel.requests.size(),0);
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(notes,"load",Q_ARG(QVariant,id)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(notes->property("visible").toBool());
        auto *exportNotes=window->findChild<QObject *>("exportRegionNotes");QVERIFY(exportNotes);QVERIFY(!exportNotes->property("enabled").toBool());
        auto *text=window->findChild<QObject *>("regionKnowledgeNote");auto *save=window->findChild<QObject *>("saveRegionKnowledgeNote");QVERIFY(text && save);text->setProperty("text","A synthetic local knowledge note α/β");auto *noteEditor=qobject_cast<QQuickItem *>(text);auto *saveButton=qobject_cast<QQuickItem *>(save);QVERIFY(noteEditor && saveButton);noteEditor->forceActiveFocus();QTest::keyClick(window,Qt::Key_End,Qt::ControlModifier);QTest::keyClick(window,Qt::Key_Return);QCOMPARE(text->property("text").toString(),QString("A synthetic local knowledge note α/β\n"));QTest::keyClick(window,Qt::Key_Backspace);QTest::keyClick(window,Qt::Key_Tab);QVERIFY2(saveButton->hasActiveFocus(),"Tab must leave the reading-note editor for its Save button, without inserting a tab");QCOMPARE(text->property("text").toString(),QString("A synthetic local knowledge note α/β"));QTest::keyClick(window,Qt::Key_Space);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        // Reach the editor from a stable window shortcut target, including disabled Save.
        auto *pageField=visualItem(window->contentItem(),"pageNumber");QVERIFY(pageField);pageField->forceActiveFocus();QStringList chain;
        for(int step=0;step<8 && !noteEditor->hasActiveFocus();++step){QTest::keyClick(window,Qt::Key_Backtab,Qt::ShiftModifier);auto *focus=window->activeFocusItem();chain.append(focus ? focus->objectName()+":"+focus->metaObject()->className() : QStringLiteral("none"));}
        QVERIFY2(noteEditor->hasActiveFocus(),qPrintable(chain.join(" -> ")));qInfo()<<"Reading-note backward focus chain"<<chain;
        QTest::keyClick(window,Qt::Key_A,Qt::ControlModifier);for(const auto ch:QByteArray("Keyboard focus probe"))QTest::keyClick(window,ch);QCOMPARE(text->property("text").toString(),QString("Keyboard focus probe"));
        text->setProperty("text","A synthetic local knowledge note α/β");QVERIFY(!reader->hasUnsavedReadingNotes());
        QString historyPath;QDirIterator files(qEnvironmentVariable("LYRA_READER_DOCUMENT_CACHE_DIR"),{"region-conversations-v1.json"},QDir::Files,QDirIterator::Subdirectories);
        while(files.hasNext()){const auto candidate=files.next();QFile record(candidate);if(record.open(QIODevice::ReadOnly) && record.readAll().contains(id.toUtf8())){historyPath=candidate;break;}}QVERIFY(!historyPath.isEmpty());
        QTRY_VERIFY(exportNotes->property("enabled").toBool());auto *exportDialog=window->findChild<QObject *>("readingNotesExportDialog");QVERIFY(exportDialog);
        QVERIFY(QMetaObject::invokeMethod(exportNotes,"clicked"));QTRY_VERIFY(exportDialog->property("visible").toBool());QVERIFY(QMetaObject::invokeMethod(exportDialog,"reject"));QVERIFY(!QFileInfo::exists(scratch.path()+"/reading-notes.md"));
        const auto historyBeforeExport=reader->regionHistory();QFile cached(historyPath);QVERIFY(cached.open(QIODevice::ReadOnly));const auto cacheBytes=cached.readAll();cached.close();
        QVERIFY(QMetaObject::invokeMethod(exportNotes,"clicked"));QTRY_VERIFY(exportDialog->property("visible").toBool());
        // Exercise the real FileDialog accepted callback with a synthetic local destination.
        const auto markdown=scratch.path()+"/reading-notes.md";QVERIFY(exportDialog->setProperty("currentFile",QUrl::fromLocalFile(markdown)));QTRY_COMPARE(exportDialog->property("selectedFile").toUrl(),QUrl::fromLocalFile(markdown));
        QVERIFY(QMetaObject::invokeMethod(exportDialog,"accepted"));QVERIFY(QMetaObject::invokeMethod(exportDialog,"close"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QFile written(markdown);QVERIFY(written.open(QIODevice::ReadOnly));const auto md=written.readAll();written.close();QVERIFY(md.contains("A synthetic local knowledge note"));QVERIFY(!md.contains("data:image"));
        QFile exportedImage(scratch.path()+"/reading-notes-images/region-01.png");QVERIFY(exportedImage.open(QIODevice::ReadOnly));QCOMPARE(exportedImage.readAll(),QByteArray::fromBase64(png.toLatin1()));QCOMPARE(reader->regionHistory(),historyBeforeExport);
        QVERIFY(cached.open(QIODevice::ReadOnly));QCOMPARE(cached.readAll(),cacheBytes);cached.close();QVERIFY(!reader->hasUnsavedChanges());QVERIFY(!reader->hasUnsavedReadingNotes());
        QVERIFY(QMetaObject::invokeMethod(exportNotes,"clicked"));QTRY_VERIFY(exportDialog->property("visible").toBool());const auto resetCopy=scratch.path()+"/reset-owner.md";
        QVERIFY(QMetaObject::invokeMethod(notes,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(resetCopy))));QVERIFY(QMetaObject::invokeMethod(exportDialog,"close"));reader->openFile(QUrl::fromLocalFile(path));
        QCOMPARE(notes->property("exportId").toInt(),0);QVERIFY(!notes->property("exportReader").value<QObject *>());QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(QFileInfo::exists(resetCopy),10000);QFile resetFile(resetCopy);QVERIFY(resetFile.open(QIODevice::ReadOnly));QVERIFY(resetFile.readAll().contains("A synthetic local knowledge note"));
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(notes,"load",Q_ARG(QVariant,id)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(exportNotes,"clicked"));QTRY_VERIFY(exportDialog->property("visible").toBool());
        const auto staleExport=scratch.path()+"/stale.md";reader->submit("region_note",{{"id",id},{"text","A synthetic local knowledge note α/β"}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        // A new record changes the reviewed revision even if the selected note stays identical.
        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",80},{"height",40}},1));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegion().value("image_png").toString().isEmpty(),10000);QVERIFY(reader->saveAiRegionNote());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto extraId=reader->aiRegion().value("history_id").toString();reader->clearAiRegion();
        QVERIFY(QMetaObject::invokeMethod(notes,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(staleExport))));QVERIFY(QMetaObject::invokeMethod(exportDialog,"reject"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->error().contains("changed"));QVERIFY(!QFileInfo::exists(staleExport));QVERIFY(!reader->hasUnsavedReadingNotes());reader->dismissError();
        reader->submit("region_delete",{{"id",extraId}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        if(qEnvironmentVariableIsSet("LYRA_READER_NOTES_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(700,600);QTRY_VERIFY(notesItem->width()>=240 && notesItem->width()<=dock->width());QTRY_VERIFY(notesItem->mapToScene(QPointF(notesItem->width(),0)).x()<=window->width()+1);}
        const auto snapshot=qEnvironmentVariable("LYRA_READER_NOTES_SNAPSHOT");if(!snapshot.isEmpty()){QTest::qWait(100);QVERIFY(window->grabWindow().save(snapshot));}
        QVERIFY(QMetaObject::invokeMethod(notes,"close"));reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->regionHistory().value("entries").toList().size(),1);
        QVERIFY(QMetaObject::invokeMethod(notes,"load",Q_ARG(QVariant,id)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_COMPARE_WITH_TIMEOUT(toMap(notes->property("detail")).value("knowledgeNote").toString(),QString("A synthetic local knowledge note α/β"),10000);
        QVERIFY(toMap(notes->property("detail")).value("turns").toList().isEmpty());
        auto *back=window->findChild<QObject *>("regionNotesBack");QVERIFY(back && back->property("enabled").toBool());QVERIFY(QMetaObject::invokeMethod(back,"clicked"));QTRY_VERIFY(toMap(notes->property("detail")).isEmpty());QTRY_VERIFY(notesList->isVisible());
        QVERIFY(QMetaObject::invokeMethod(notes,"load",Q_ARG(QVariant,id)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        text->setProperty("text","Draft survives drawer modes and tabs");QVERIFY(reader->hasUnsavedReadingNotes());
        QVERIFY(QMetaObject::invokeMethod(window,"openAiWorkspace",Q_ARG(QVariant,"chat")));QVERIFY(!notes->property("visible").toBool());QVERIFY(reader->hasUnsavedReadingNotes());
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_COMPARE(text->property("text").toString(),QString("Draft survives drawer modes and tabs"));
        view.workspace.newTab();QVERIFY(view.workspace.activeReader()!=reader);QVERIFY(!notes->property("visible").toBool());QVERIFY(toMap(notes->property("detail")).isEmpty());QVERIFY(reader->hasUnsavedReadingNotes());
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QVERIFY(!notes->property("visible").toBool());
        view.workspace.selectTab(0);QCOMPARE(view.workspace.activeReader(),reader);QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_COMPARE(text->property("text").toString(),QString("Draft survives drawer modes and tabs"));
        auto *discard=window->findChild<QObject *>("discardRegionNoteDraft");QVERIFY(discard);QVERIFY(QMetaObject::invokeMethod(discard,"clicked"));QVERIFY(!reader->hasUnsavedReadingNotes());
        auto *remove=window->findChild<QObject *>("deleteRegionKnowledgeNote");QVERIFY(remove);QVERIFY(QMetaObject::invokeMethod(remove,"clicked"));
        auto *confirm=notes->findChild<QObject *>("deleteRegionNoteConfirmation");QVERIFY(confirm);QTRY_VERIFY(confirm->property("visible").toBool());QVERIFY(QMetaObject::invokeMethod(confirm,"reject"));QCOMPARE(reader->regionHistory().value("entries").toList().size(),1);
        reader->submit("region_delete",{{"id",id}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->regionHistory().value("entries").toList().size(),0);QTRY_VERIFY(toMap(notes->property("detail")).isEmpty());
        QSaveFile corrupt(historyPath);QVERIFY(corrupt.open(QIODevice::WriteOnly));QCOMPARE(corrupt.write("invalid saved history"),qint64(21));QVERIFY(corrupt.commit());
        reader->openFile(QUrl::fromLocalFile(path));QVERIFY(!window->property("aiPanelVisible").toBool());QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->regionHistory().value("error").toString().contains("could not be read"));
        auto *empty=window->findChild<QObject *>("regionNotesEmpty");QVERIFY(empty);QVERIFY(!empty->property("visible").toBool());QCOMPARE(sentinel.requests.size(),0);QFile preserved(historyPath);QVERIFY(preserved.open(QIODevice::ReadOnly));QCOMPARE(preserved.readAll(),QByteArray("invalid saved history"));

    }
    void readingNoteDraftsAndFailedSavesBlockCloseAndKeepLateText() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/note-close.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));QPointer<ReaderController> reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiRegion().value("image_png").toString().isEmpty(),10000);reader->setAiRegionQuestion("Keep this area");QVERIFY(reader->saveAiRegionNote());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto id=reader->aiRegion().value("history_id").toString();QVERIFY(reader->setRegionNoteDraft(id,"First note"));QVERIFY(reader->hasUnsavedReadingNotes());
        QVERIFY(QMetaObject::invokeMethod(window,"requestCloseTab",Q_ARG(QVariant,0)));QVERIFY(reader && window->isVisible());QVERIFY(window->property("operationStatus").toString().contains("reading note"));
        QVERIFY(reader->saveRegionNoteDraft());QVERIFY(reader->setRegionNoteDraft(id,"Late local note"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->hasUnsavedReadingNotes());QCOMPARE(reader->regionNoteDraft().value("text").toString(),QString("Late local note"));
        QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));auto *notes=window->findChild<QObject *>("regionNotes");QVERIFY(notes);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);auto *text=window->findChild<QObject *>("regionKnowledgeNote");QVERIFY(text);QTRY_COMPARE(text->property("text").toString(),QString("Late local note"));
        auto *noteItem=qobject_cast<QQuickItem *>(text);QVERIFY(noteItem);noteItem->forceActiveFocus();QTRY_VERIFY(noteItem->hasActiveFocus());
        auto *back=window->findChild<QObject *>("regionNotesBack");auto *newArea=window->findChild<QObject *>("regionNotesNewArea");QVERIFY(back && newArea);QVERIFY(!back->property("enabled").toBool());QVERIFY(!newArea->property("enabled").toBool());
        QTest::keyClick(window,Qt::Key_Escape);QTRY_VERIFY(!notes->property("visible").toBool());QVERIFY(!noteItem->hasActiveFocus());auto *canvas=visualItem(window->contentItem(),"pageList");QVERIFY(canvas && canvas->hasActiveFocus());QVERIFY(reader->hasUnsavedReadingNotes());QVERIFY(QMetaObject::invokeMethod(window,"openRegionNotes"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_COMPARE(text->property("text").toString(),QString("Late local note"));
        auto *discard=window->findChild<QObject *>("discardRegionNoteDraft");QVERIFY(discard);QVERIFY(QMetaObject::invokeMethod(discard,"clicked"));QVERIFY(!reader->hasUnsavedReadingNotes());QCOMPARE(text->property("text").toString(),QString("First note"));
        text->setProperty("text","Pending replacement");QVERIFY(reader->saveRegionNoteDraft());text->setProperty("text","First note");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->hasUnsavedReadingNotes());QCOMPARE(reader->regionNoteDraft().value("text").toString(),QString("First note"));
        QVERIFY(QMetaObject::invokeMethod(discard,"clicked"));QVERIFY(!reader->hasUnsavedReadingNotes());QCOMPARE(text->property("text").toString(),QString("Pending replacement"));QVERIFY(QMetaObject::invokeMethod(notes,"close"));
        QString historyPath;QDirIterator files(qEnvironmentVariable("LYRA_READER_DOCUMENT_CACHE_DIR"),{"region-conversations-v1.json"},QDir::Files,QDirIterator::Subdirectories);
        while(files.hasNext()){const auto candidate=files.next();QFile record(candidate);if(record.open(QIODevice::ReadOnly) && record.readAll().contains(id.toUtf8())){historyPath=candidate;break;}}QVERIFY(!historyPath.isEmpty());
        QFile external(historyPath);QVERIFY(external.open(QIODevice::Append));QCOMPARE(external.write(" "),qint64(1));external.close();
        reader->setAiRegionQuestion("A failed snapshot save must remain in this tab");QVERIFY(reader->saveAiRegionNote());QVERIFY(QMetaObject::invokeMethod(window,"requestCloseTab",Q_ARG(QVariant,0)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(reader->hasUnsavedReadingNotes());QTRY_COMPARE(window->property("closingTab").toInt(),-2);QVERIFY(reader && window->isVisible());QCOMPARE(reader->aiRegion().value("question").toString(),QString("A failed snapshot save must remain in this tab"));
        QVERIFY(!window->close());QVERIFY(window->isVisible());reader->clearAiRegion();QVERIFY(reader->hasUnsavedReadingNotes());QCOMPARE(reader->aiRegion().value("question").toString(),QString("A failed snapshot save must remain in this tab"));
        // Clear cannot turn a failed autosave into a silent discard. Quit must keep
        // the same protected draft and externally changed cache in place too.
        auto *quit=view.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);
        QVERIFY(reader->saveAiRegionNote());view.workspace.requestQuit();QTRY_VERIFY_WITH_TIMEOUT(!quit->busy(),10000);QCOMPARE(accepted.size(),0);QVERIFY(quit->message().contains("reading-note"));QVERIFY(reader && window->isVisible());QVERIFY(reader->hasUnsavedReadingNotes());reader->clearAiRegion();

    }
    void cancelledRegionCapturesReleaseTheirBudgetAndRejectOldDocuments() {
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        const auto before=RenderBudget::statistics().value("residentBytes").toLongLong();
        QSemaphore entered,release;auto guard=qScopeGuard([&]{release.release(2);});
        const auto hold=[&]{entered.release();release.acquire();};auto first=QtConcurrent::run(RasterJobs::pool(),hold),second=QtConcurrent::run(RasterJobs::pool(),hold);
        QVERIFY(entered.tryAcquire(2,3000));
        const QVariantMap rect{{"x",60},{"y",55},{"width",420},{"height",180}};
        QVERIFY(reader.captureAiRegion(0,rect,1));QVERIFY(reader.aiRegion().value("loading").toBool());QVERIFY(RenderBudget::statistics().value("residentBytes").toLongLong()>before);
        reader.cancelAiRegionCapture();QVERIFY(reader.aiRegion().isEmpty());
        reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));release.release(2);guard.dismiss();first.waitForFinished();second.waitForFinished();
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTRY_COMPARE_WITH_TIMEOUT(RasterJobs::statistics().value("queued").toInt(),0,10000);QTest::qWait(80);QVERIFY(reader.aiRegion().isEmpty());
        QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong(),before,10000);
        QVERIFY(reader.captureAiRegion(0,{{"x",0},{"y",0},{"width",1000000},{"height",1000000}},1));QTRY_VERIFY_WITH_TIMEOUT(reader.aiRegion().contains("error"),10000);QVERIFY(!reader.aiRegion().contains("image_png"));
    }
    void regionPaperStateKeepsSourceRowsAndRejectsLatePlans() {
        QTemporaryDir temp;QVERIFY(temp.isValid());const auto path=temp.filePath("region-paper.pdf");
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto bytes=file.readAll();file.close();
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(path));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        reader.requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(reader.textPages().contains("0"));
        const auto pages=reader.pages(),rows=reader.layoutRows();const auto height=reader.documentHeight();
        QVERIFY(reader.captureAiRegion(0,{{"x",60},{"y",55},{"width",420},{"height",180}},1));
        QTRY_VERIFY_WITH_TIMEOUT(reader.aiRegion().contains("image_png"),10000);
        const auto capturePng=reader.aiRegion().value("image_png");
        const auto rasterCount=reader.completedRasters();
        const auto id=reader.aiRegion().value("history_id");const auto sha=reader.aiRegion().value("source_sha256");
        const auto split=reader.aiRegion().value("paper_plan").toMap().value("split_pt");QVERIFY(!split.isNull());QVERIFY(split.toDouble()>=235);
        reader.configureAiRegionPaper("Continuous",std::numeric_limits<double>::quiet_NaN(),50);QVERIFY(reader.aiRegionPaper().contains("error"));
        reader.configureAiRegionPaper("Continuous",12.75,-1);QVERIFY(reader.aiRegionPaper().contains("error"));
        reader.configureAiRegionPaper("Continuous",12.75,150.25);
        reader.configureAiRegionPaper("Continuous",12.75,150.25); // A repeated in-flight request must not invalidate itself.
        QTRY_VERIFY_WITH_TIMEOUT(reader.aiRegionPaper().contains("rows") && !reader.aiRegionPaper().value("loading").toBool(),10000);
        QCOMPARE(reader.aiRegionPaper().value("height").toDouble(),height+150.25);
        QCOMPARE(reader.aiRegionPaper().value("id"),id);QCOMPARE(reader.aiRegionPaper().value("source_sha256"),sha);
        const auto gapTop=reader.aiRegionPaper().value("gap_top").toDouble();
        QCOMPARE(reader.unshiftedPaperScroll(gapTop+50),gapTop);
        QCOMPARE(reader.unshiftedPaperScroll(gapTop+150.25+20),gapTop+20);
        QCOMPARE(reader.unshiftedPaperScroll(gapTop+75.125+20,.5),gapTop+20);
        QCOMPARE(reader.shiftedPaperScroll(gapTop+20,.5),gapTop+95.125);
        QCOMPARE(reader.shiftedPaperScroll(gapTop+20,0),gapTop+20);
        QVERIFY(std::isnan(reader.unshiftedPaperScroll(gapTop,-.1)));
        QVERIFY(std::isnan(reader.shiftedPaperScroll(gapTop,1.1)));
        QVERIFY(std::isnan(reader.shiftedPaperScroll(gapTop,qQNaN())));
        QVERIFY(std::isnan(reader.unshiftedPaperScroll(-1)));
        QCOMPARE(reader.pages(),pages);QCOMPARE(reader.layoutRows(),rows);QCOMPARE(reader.documentHeight(),height);
        QCOMPARE(reader.aiRegion().value("image_png"),capturePng);QCOMPARE(reader.completedRasters(),rasterCount);
        QTRY_COMPARE_WITH_TIMEOUT(reader.findChildren<QFutureWatcherBase *>().size(),0,10000);
        auto *pool=QThreadPool::globalInstance();const auto oldLimit=pool->maxThreadCount();pool->setMaxThreadCount(1);
        QSemaphore entered,release;auto held=QtConcurrent::run([&]{entered.release();release.acquire();});
        auto restore=qScopeGuard([&]{release.release();pool->setMaxThreadCount(oldLimit);held.waitForFinished();});
        QVERIFY(entered.tryAcquire(1,3000));
        for(int gap=75;gap<139;++gap)reader.configureAiRegionPaper("Continuous",12.75,gap);
        QCOMPARE(reader.findChildren<QFutureWatcherBase *>().size(),1); // One active job and one replaceable pending spec.
        release.release();pool->setMaxThreadCount(oldLimit);held.waitForFinished();restore.dismiss();
        QTRY_COMPARE_WITH_TIMEOUT(reader.aiRegionPaper().value("height").toDouble(),height+138,10000);
        reader.configureAiRegionPaper("Facing",18,75);reader.configureAiRegionPaper("Continuous",12.75,25);
        QVERIFY(QThreadPool::globalInstance()->waitForDone(10000));QCoreApplication::processEvents();
        QTRY_COMPARE(reader.aiRegionPaper().value("height").toDouble(),height+25);
        reader.configureAiRegionPaper("Continuous",12.75,95);reader.clearAiRegionPaper();
        QVERIFY(QThreadPool::globalInstance()->waitForDone(10000));QCoreApplication::processEvents();QVERIFY(reader.aiRegionPaper().isEmpty());
        reader.configureAiRegionPaper("Continuous",12.75,95);reader.setLayout("Facing",18);
        QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(QThreadPool::globalInstance()->waitForDone(10000));QCoreApplication::processEvents();QVERIFY(reader.aiRegionPaper().isEmpty());QVERIFY(reader.aiRegion().contains("image_png"));
        // Replacing this controller waits for its new automatic snapshot. The paper
        // request still starts immediately before reopen to test stale-result rejection.
        reader.flushAiRegionNote(false);QTRY_VERIFY_WITH_TIMEOUT(!reader.hasUnsavedReadingNotes(),10000);
        reader.configureAiRegionPaper("Facing",18,95);reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));
        QTRY_VERIFY_WITH_TIMEOUT(!reader.loading(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        QVERIFY(QThreadPool::globalInstance()->waitForDone(10000));QCoreApplication::processEvents();QVERIFY(reader.aiRegionPaper().isEmpty());QVERIFY(reader.aiRegion().isEmpty());
        QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),bytes);
    }
    void aiPreviewStreamingCancellationAndTabsUseTheRealLocalTransport() {
        MockChatServer server;QVERIFY2(server.listen(),"Loopback HTTP is required for this GUI check; no external service is contacted");
        const auto imageUrl=server.baseUrl()+"/unwanted-image";
        server.responses.append({{MockChatServer::delta({{"reasoning_content","provider rationale"}}),MockChatServer::delta({{"content","Answer [p.1] **ready**.\n![remote][image]\n[image]: "+imageUrl}}),MockChatServer::usage(),QByteArray("data: [DONE]\n\n")},70,200});
        MockChatServer::Response slow;slow.holdLast=true;slow.chunks={MockChatServer::delta({{"content","chunk0 "}}),QByteArray("data: [DONE]\n\n")};server.responses.append(slow);
        server.responses.append({{MockChatServer::delta({{"content","retry succeeded"}}),MockChatServer::usage(),QByteArray("data: [DONE]\n\n")},30,200});
        server.responses.append({{QByteArray("{\"error\":{\"message\":\"fixture rejection\"}}")},0,400});server.responses.append(slow);
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::qWait(150);
        window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","fixture"}});QVERIFY(QMetaObject::invokeMethod(window,"showSidebar",Q_ARG(QVariant,"ai")));
        reader->setAiInput("action",0);auto *panel=window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY2_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),qPrintable(reader->aiState().value("status").toString()),10000);QCOMPARE(server.requests.size(),0);
        const auto plan=reader->aiState().value("plan").toMap();QVERIFY(plan.value("is_local").toBool());
        auto *send=window->findChild<QQuickItem *>("sendAiRequest");QVERIFY(send);QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,send->mapToScene(QPointF(send->width()/2,send->height()/2)).toPoint());
        QTRY_COMPARE(server.requests.size(),1);QVERIFY(reader->aiState().value("running").toBool());
        workspace.newTab();auto *other=workspace.activeReader();other->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));QTRY_COMPARE_WITH_TIMEOUT(other->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(other->pendingCommands(),0,10000);
        QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(other->aiState().value("output").toString().isEmpty());QVERIFY(reader->aiState().value("output").toString().contains("Answer"));QVERIFY(!reader->aiState().value("output").toString().contains("provider rationale"));QCOMPARE(reader->aiState().value("reasoning").toString(),QString("provider rationale"));QCOMPARE(reader->aiState().value("usage").toMap().value("total_tokens").toInt(),10);
        workspace.selectTab(0);QTest::qWait(200);QCOMPARE(server.requests.size(),1); // Reference images must remain text.
        auto *answer=window->findChild<QObject *>("aiAnswerText");QVERIFY(answer);QVERIFY(!answer->property("text").toString().contains("<img"));
        const auto sentPages=plan.value("source_pages").toList();QVERIFY(!sentPages.isEmpty());const int unsent=reader->pageCount()+1;const auto beforeLink=window->property("currentPage").toInt();QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QString("p.%1").arg(unsent))));QCOMPARE(window->property("currentPage").toInt(),beforeLink);QVERIFY(window->property("operationStatus").toString().contains("cannot be verified"));QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QString("p.%1").arg(sentPages.first().toInt()))));QTRY_COMPARE(window->property("currentPage").toInt(),sentPages.first().toInt()-1);
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
    void sessionCredentialsReuseSuccessfulReadsAndRejectStaleOrFailedReplies() {
        FakeCredentialStore store;QSignalSpy events(&store,&CredentialStore::finished);
        const QString first="https://provider-a.invalid/v1",second="https://provider-b.invalid/v1",secret="synthetic-session-secret";
        const auto a=store.read(first),b=store.read(first);QCOMPARE(store.requests.size(),1);store.reply(0,secret);QCOMPARE(events.size(),2);QCOMPARE(events[0][0].toULongLong(),a);QCOMPARE(events[1][0].toULongLong(),b);QCOMPARE(events[1][2].toString(),secret);
        events.clear();const auto cached=store.read(first);QVERIFY(events.isEmpty());QTRY_COMPARE(events.size(),1);QCOMPARE(events[0][0].toULongLong(),cached);QCOMPARE(events[0][2].toString(),secret);QCOMPARE(store.requests.size(),1);
        events.clear();store.clearSession();store.read(first);store.read(second);QCOMPARE(store.requests.size(),3);store.reply(1,secret);QCOMPARE(events.size(),1);QVERIFY(events[0][2].toString().isEmpty());QVERIFY(!events[0][3].toString().isEmpty());
        store.reply(2,{},"Synthetic vault locked");QCOMPARE(events.last()[3].toString(),QString("Synthetic vault locked"));store.read(second);QCOMPARE(store.requests.size(),4);store.reply(3);store.read(second);QCOMPARE(store.requests.size(),5);store.reply(4,secret);QCOMPARE(events.last()[2].toString(),secret);
        // A completion listener can switch providers between coalesced replies.
        store.clearSession();events.clear();const auto firstId=store.read(first);store.read(first);
        const auto connection=connect(&store,&CredentialStore::finished,&store,[&](quint64 id,const QString &,const QString &,const QString &){if(id==firstId)store.clearSession();});
        store.reply(5,secret);QCOMPARE(events.size(),2);QCOMPARE(events[0][2].toString(),secret);QVERIFY(events[1][2].toString().isEmpty());QVERIFY(!events[1][3].toString().isEmpty());disconnect(connection);
    }
    void credentialChangesInvalidateOtherWindowsAndQueuedCacheHits() {
        const QString account="https://provider-session.invalid/v1",oldKey="synthetic-old-key",newKey="synthetic-new-key";
        FakeCredentialStore first,second;QSignalSpy a(&first,&CredentialStore::finished),b(&second,&CredentialStore::finished);
        first.read(account);first.reply(0,oldKey);second.read(account);second.reply(0,oldKey);a.clear();b.clear();
        first.read(account);second.write(account,newKey);QCOMPARE(second.requests.size(),2);QTRY_COMPARE(a.size(),1);QVERIFY(a[0][2].toString().isEmpty());QVERIFY(!a[0][3].toString().isEmpty());second.reply(1);
        second.read(account);QTRY_COMPARE(b.size(),2);QCOMPARE(b.last()[2].toString(),newKey);QCOMPARE(second.requests.size(),2);
        first.read(account);QCOMPARE(first.requests.size(),2);first.reply(1,newKey);a.clear();second.remove(account);first.read(account);QCOMPARE(first.requests.size(),3);second.reply(2);first.reply(2,oldKey);QVERIFY(a.last()[2].toString().isEmpty());QVERIFY(!a.last()[3].toString().isEmpty());
        first.read(account);QCOMPARE(first.requests.size(),4);first.reply(3);QVERIFY(a.last()[2].toString().isEmpty());QVERIFY(a.last()[3].toString().isEmpty());
        // An older write finishing after a provider switch cannot repopulate it.
        first.write(account,newKey);first.clearSession();first.reply(4);first.read(account);QCOMPARE(first.requests.size(),6);first.reply(5,{},"Synthetic read failure");QCOMPARE(a.last()[3].toString(),QString("Synthetic read failure"));
        first.write(account,newKey);first.reply(6,{},"Synthetic write failure");QCOMPARE(a.last()[3].toString(),QString("Synthetic write failure"));
        first.read(account);QCOMPARE(first.requests.size(),8);first.reply(7,oldKey);QCOMPARE(a.last()[2].toString(),oldKey);
    }
    void changingAiSettingsRejectsAnOldPendingCredentialReply() {
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *reader=view.workspace.activeReader();
        view.window->setProperty("credentialReadId",123);view.window->setProperty("pendingAiReader",QVariant::fromValue(reader));view.window->setProperty("pendingAiPlan",QVariantMap{{"host","old-provider.invalid"}});
        view.window->setProperty("aiSettings",QVariantMap{{"baseUrl","https://new-provider.invalid/v1"},{"model","synthetic-model"}});
        QCOMPARE(view.window->property("credentialReadId").toDouble(),-1.0);QVERIFY(!view.window->property("pendingAiReader").value<QObject *>());QCOMPARE(view.window->property("credentialSessionBaseUrl").toString(),QString("https://new-provider.invalid/v1"));
        emit view.workspace.credentials()->finished(123,"read","synthetic-late-key",{});QVERIFY(!reader->aiState().value("running").toBool());
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
        store.clearSession(); // Force an actual vault read, not the successful-write cache.
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
            const auto windowToken=qEnvironmentVariable("LYRA_READER_PERF_WINDOW_TOKEN");
            if(!windowToken.isEmpty())window->setTitle(QStringLiteral("LyraReader performance ")+windowToken.left(80));
            // Optional grace for an external compositor-aware runner to activate this
            // process's own window. Qt's X11 active flag alone can be stale on XWayland.
            const auto activationGrace=qEnvironmentVariableIntValue("LYRA_READER_PERF_ACTIVATION_WAIT_MS");
            QVERIFY(activationGrace>=0 && activationGrace<=5000);
            if(activationGrace)QTest::qWait(activationGrace);
            const bool exposed=QTest::qWaitForWindowExposed(window,5000);
            if(exposed)window->requestActivate();
            if(!exposed || !QTest::qWaitForWindowActive(window,2500)) {
                QVERIFY(publish({{"schema",2},{"phase","preflight"},{"qt",qVersion()},{"platform",QGuiApplication::platformName()},
                    {"requestedBackend",graphicsBackend.isEmpty()?qEnvironmentVariable("QSG_RHI_BACKEND"):graphicsBackend},{"windowActive",window->isActive()},{"windowExposed",window->isExposed()},
                    {"interactivePresentationMeasured",false},{"inputBurstsAttempted",false},{"reason",exposed ? "Native window could not obtain keyboard focus; no interactive timing was attempted." : "Native window was not exposed within the preflight timeout; no interactive timing was attempted."}}));
                QSKIP("Native window was not exposed or active; input bursts were not attempted. Diagnostic JSON was saved.");
            }
        }
        Performance::Frames frames(window),visibleFrames(window);QList<double> inputIntervals,refinement,visibleRefinement,guiIntervals,inputPacing,burstDurations,zoomApply,navigationApply,eventPump;
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
        bool validTrialCount=true;
        const auto trialSetting=qEnvironmentVariable("LYRA_READER_PERF_TRIALS");
        const int trials=trialSetting.isEmpty()?30:trialSetting.toInt(&validTrialCount);
        QVERIFY2(validTrialCount && trials>=3 && trials<=30,"Diagnostic trial count must be 3...30; default remains 30");
        for(int trial=0;trial<trials;++trial) {
            frames.clear();visibleFrames.clear();const auto begin=Performance::now();qint64 lastInput=begin;
            for(int step=0;step<12;++step) {
                const auto inputTime=Performance::now();if(step)inputPacing.append((inputTime-lastInput)/1000.0);lastInput=inputTime;
                const auto scale=step%3==0?2.7:step%3==1?4.0:3.6;
                QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,scale),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
                const auto zoomDone=Performance::now();zoomApply.append((zoomDone-inputTime)/1000.0);
                view->setProperty("contentX",double((step+trial)%8*70));
                QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,pageIndex),Q_ARG(QVariant,double(200+(step+trial)%8*70)/scale)));
                const auto navigationDone=Performance::now();navigationApply.append((navigationDone-zoomDone)/1000.0);
                if(step<11){QTest::qWait(16);eventPump.append((Performance::now()-navigationDone)/1000.0);}
            }
            const auto endInput=Performance::now();burstDurations.append((endInput-begin)/1000.0);bool armed=false,visibleArmed=false;QTimer ready;ready.setInterval(5);
            connect(&ready,&QTimer::timeout,window,[&]{
                if(!textured())return;
                if(!visibleArmed){visibleArmed=true;visibleFrames.arm();window->update();}
                if(!armed && reader.pendingRasters()==0){armed=true;frames.arm();window->update();}
            });ready.start();
            QTimer::singleShot(2000,&ready,[&,trial] {
                auto *page=visualItem(window->contentItem(),QString("pdfPage%1").arg(pageIndex));
                QVariantMap state{{"trial",trial},{"currentPage",window->property("currentPage")},{"zoom",window->property("zoom")},{"contentY",view->property("contentY")},{"originY",view->property("originY")},{"pendingRasters",reader.pendingRasters()},{"error",reader.error()},{"jobs",RasterJobs::statistics()},{"budget",RenderBudget::statistics()}};
                if(page){state.insert("visibleRegion",page->property("visibleRegion"));state.insert("refined",page->property("refined"));state.insert("texturesReady",page->property("texturesReady"));state.insert("sceneY",page->mapToScene(QPointF(0,0)).y());}else state.insert("pageMissing",true);
                qInfo().noquote()<<"lyra-reader-performance-pending:"<<QJsonDocument::fromVariant(state).toJson(QJsonDocument::Compact);
            });
            QTRY_VERIFY_WITH_TIMEOUT(frames.queued()>0,30000);ready.stop();
            QTRY_VERIFY_WITH_TIMEOUT(visibleFrames.queued()>0,10000);
            refinement.append((frames.queued()-lastInput)/1000.0);visibleRefinement.append((visibleFrames.queued()-lastInput)/1000.0);inputIntervals.append(frames.intervals(begin,endInput));
            if(qEnvironmentVariableIsSet("LYRA_READER_PERF_TRACE"))qInfo()<<"lyra-reader-performance-trial:"<<trial+1<<"visible-ms"<<visibleRefinement.last()<<"drained-ms"<<refinement.last()<<"burst-ms"<<burstDurations.last()<<"active"<<window->isActive();
            if(!focusMaintained || (native && trial>=2 && inputIntervals.isEmpty()))break;
        }
        sampler.stop();
        QVariantMap report{{"schema",2},{"phase","bursts"},{"qt",qVersion()},{"platform",QGuiApplication::platformName()},{"graphicsApi",int(window->rendererInterface()->graphicsApi())},{"requestedBackend",graphicsBackend.isEmpty()?qEnvironmentVariable("QSG_RHI_BACKEND"):graphicsBackend},
            {"architecture",QSysInfo::currentCpuArchitecture()},{"fixture",QFileInfo(input).fileName()},{"pages",reader.pageCount()},{"pageIndex",pageIndex},{"windowWidth",window->width()},{"windowHeight",window->height()},{"devicePixelRatio",window->effectiveDevicePixelRatio()},
            {"pdfOpenToTexturedFrameQueueMs",openMs},{"lastInputToTexturedFrameQueueMs",Performance::distribution(refinement)},{"lastInputToVisibleTextureFrameQueueMs",Performance::distribution(visibleRefinement)},{"synchronousZoomApplyMs",Performance::distribution(zoomApply)},{"synchronousPanNavigateApplyMs",Performance::distribution(navigationApply)},{"requestedSixteenMsEventPumpMs",Performance::distribution(eventPump)},{"duringInputFrameQueueIntervalsMs",Performance::distribution(inputIntervals)},
            {"trialsRequested",trials},{"trialsCompleted",refinement.size()},{"inputsPerBurst",12},{"targetInputIntervalMs",16},{"actualInputIntervalsMs",Performance::distribution(inputPacing)},{"inputBurstDurationMs",Performance::distribution(burstDurations)},{"percentileMethod","lower order statistic"},
            {"guiTenMsTimerIntervalsMs",Performance::distribution(guiIntervals)},{"rssPeakSampledBytes",peakRss},{"rssFinalBytes",Performance::memory("VmRSS")},{"processLifetimeRssHighWaterBytes",Performance::memory("VmHWM")},
            {"renderResources",RenderBudget::statistics()},{"rasterJobs",RasterJobs::statistics()},{"cpuLruKiB",ReaderController::cpuCacheKiB()},
            {"interactivePresentationMeasured",inputIntervals.size()>=6 && focusMaintained},{"inputBurstsAttempted",true},{"nativeFocusRequired",native},{"focusMaintained",focusMaintained},{"windowExposed",window->isExposed()},{"windowActive",window->isActive()},
            {"measurementNotes","Up to thirty 12-input zoom/pan bursts targeting 16 ms; actual delivery intervals are recorded. Last input starts before applying its zoom/pan change and includes GUI handling and 5 ms readiness polling. The legacy textured latency also waits for all reader raster requests to drain; the additional visible-texture latency only waits for the current page textures and its next queued frame. Synchronous zoom/navigation calls and the requested 16 ms Qt event pump are timed separately; event-pump time includes GUI/render synchronization and queued event handling, not only sleep. Optional per-trial trace is emitted outside the input burst. frameSwapped measures queued presentation, not physical display FPS. Insufficient input-period frame callbacks or lost native focus invalidate the sample and stop further bursts; no cause for missing callbacks is inferred. RSS includes Qt, PDFium, fonts and index memory; unsupported OS values are -1. The source ledger includes pre-raster capacity reservations. Driver allocations and Qt chrome are outside the pixel payload ledger."}};
        QVERIFY(publish(report));
        QVERIFY(RenderBudget::statistics().value("residentPeakBytes").toLongLong()<=RenderBudget::residentLimit);
        QVERIFY(RenderBudget::statistics().value("texturePeakBytes").toLongLong()<=RenderBudget::textureLimit);
        QVERIFY(RasterJobs::statistics().value("peakRunning").toInt()<=RasterJobs::maximumRunning);
        if(inputIntervals.size()<6 || !focusMaintained)QSKIP("Insufficient input-period frames or lost native focus; interactive performance remains unmeasured. Diagnostic JSON was saved.");
    }
    void revisitBackdropCacheIsBoundedAndKeepsItsResidentLease() {
        QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong(),0,10000);
        const auto prefix=QUuid::createUuid().toString()+"/backdrop-test/";
        const auto cleanup=qScopeGuard([&]{RasterCache::clearPrefix(prefix);});
        QImage small(512,512,QImage::Format_ARGB32);small.fill(Qt::white);auto image=ResidentImage::retain(small);QVERIFY(!image.isNull());
        for(int i=0;i<8;++i)RasterCache::putBackdrop(prefix+QString::number(i),image);
        QCOMPARE(RasterCache::backdropCostKiB(),RasterCache::maximumBackdropKiB);QVERIFY(!RasterCache::backdrop(prefix+"0").isNull());
        RasterCache::putBackdrop(prefix+"8",image);QVERIFY(RasterCache::hasBackdrop(prefix+"0"));QVERIFY(!RasterCache::hasBackdrop(prefix+"1"));
        QImage large(2048,1152,QImage::Format_ARGB32);large.fill(Qt::white);auto oversized=ResidentImage::retain(large);QVERIFY(!oversized.isNull());RasterCache::putBackdrop(prefix+"oversized",oversized);QVERIFY(!RasterCache::hasBackdrop(prefix+"oversized"));QCOMPARE(RasterCache::backdropCostKiB(),RasterCache::maximumBackdropKiB);
        oversized={};large={};image={};small={};QCOMPARE(RenderBudget::statistics().value("residentBytes").toLongLong(),1024*1024);RasterCache::clearPrefix(prefix);QCOMPARE(RasterCache::backdropCostKiB(),0);QCOMPARE(RenderBudget::statistics().value("residentBytes").toLongLong(),0);
    }
    void distantRevisitsUseCachedContentAndUnloadedPaperFollowsAppearance() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/distant-pages.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/index-past-120.pdf",path));QFile input(path);QVERIFY(input.open(QIODevice::ReadOnly));const auto original=input.readAll();input.close();
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);reader.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(reader.pageCount()>100,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QTRY_VERIFY(!window->property("positionRestoring").toBool());window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        auto page=[&](int index){return qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage"+QString::number(index)));};
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,50),Q_ARG(QVariant,0)));QTRY_VERIFY_WITH_TIMEOUT(page(50) && page(50)->refined(),10000);QTRY_VERIFY(!reader.cachedBackdrop(50).isNull());QVERIFY(reader.cachedBackdrop(50,true).isNull());QVERIFY(reader.cachedBackdrop(50).width()<=512 && reader.cachedBackdrop(50).height()<=1024);
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,100),Q_ARG(QVariant,0)));QTRY_VERIFY_WITH_TIMEOUT(page(100) && page(100)->refined(),10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingRasters(),0,10000);QVERIFY(!reader.cachedBackdrop(50).isNull());
        // Shared synthetic buffers evict CPU-LRU costs without allocating 100 MiB of pixels.
        const auto filler=QUuid::createUuid().toString()+"/working-set-test/";const auto cleanup=qScopeGuard([&]{RasterCache::clearPrefix(filler);});QImage pixels(1024,512,QImage::Format_ARGB32);pixels.fill(Qt::white);for(int i=0;i<50;++i)RasterCache::put(filler+QString::number(i),pixels);QCOMPARE(RasterCache::costKiB(),RasterCache::maximumKiB);QVERIFY(!RasterCache::contains(filler+"0"));
        QSemaphore release;std::atomic_int started{0};QList<QFuture<void>> blockers;
        auto unblock=qScopeGuard([&]{release.release(RasterJobs::maximumRunning);for(auto &future:blockers)future.waitForFinished();});
        for(int i=0;i<RasterJobs::maximumRunning;++i)blockers.append(QtConcurrent::run(RasterJobs::pool(),[&]{++started;release.acquire();}));QTRY_COMPARE(started.load(),RasterJobs::maximumRunning);
        const auto completed=reader.completedRasters();QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,50),Q_ARG(QVariant,0)));QTRY_VERIFY_WITH_TIMEOUT(page(50) && page(50)->loaded() && page(50)->backdropVisible(),10000);QVERIFY(!page(50)->refined());QCOMPARE(reader.completedRasters(),completed);
        const auto evidence=qEnvironmentVariable("LYRA_READER_BACKDROP_SNAPSHOT");if(!evidence.isEmpty())QVERIFY(window->grabWindow().save(evidence));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,75),Q_ARG(QVariant,0)));QTRY_VERIFY(page(75));QVERIFY(!page(75)->loaded());
        for(const auto &appearance:{"original","warm","night"}) {
            window->setProperty("paperAppearance",appearance);const auto expected=reader.paperBackground(appearance);
            auto correctPaper=[&]{const auto frame=window->grabWindow();if(frame.isNull() || !page(75))return false;const auto p=page(75)->mapToScene(QPointF(10,10));const int x=qRound(p.x()*frame.width()/window->width()),y=qRound(p.y()*frame.height()/window->height());if(x<0 || y<0 || x>=frame.width() || y>=frame.height())return false;const auto c=frame.pixelColor(x,y);return qAbs(c.red()-expected.red())<=2 && qAbs(c.green()-expected.green())<=2 && qAbs(c.blue()-expected.blue())<=2;};
            QTRY_VERIFY_WITH_TIMEOUT(correctPaper(),10000);QVERIFY(!page(75)->loaded());QCOMPARE(reader.completedRasters(),completed);
        }
        if(!evidence.isEmpty())QVERIFY(window->grabWindow().save(evidence+".night.png"));
        release.release(RasterJobs::maximumRunning);for(auto &future:blockers)future.waitForFinished();unblock.dismiss();QTRY_VERIFY_WITH_TIMEOUT(page(75) && page(75)->refined() && page(75)->texturesReady(),15000);QVERIFY(!page(75)->backdropVisible());QVERIFY(RasterCache::backdropCostKiB()<=RasterCache::maximumBackdropKiB);QVERIFY(input.open(QIODevice::ReadOnly));QCOMPARE(input.readAll(),original);input.close();
        reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(reader.cachedBackdrop(50).isNull());
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
        // Hidden canvases release their working sets; the new byte-bounded revisit history
        // intentionally survives while its reader is open, and stays charged to the ledger.
        QTRY_VERIFY_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong()<=qint64(RasterCache::maximumBackdropKiB)*1024,10000);
        QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("textureBytes").toLongLong(),0,10000);
        one->show();QTRY_VERIFY_WITH_TIMEOUT(ready(one),15000);QVERIFY(!one->grabWindow().isNull());
        one->hide();one->releaseResources();first.closeTab(0);second.closeTab(0);QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("residentBytes").toLongLong(),0,10000);
    }
    void nativeTilePlanArrayLayoutSupportsMultiplePagesAndOwnsItsBuffer() {
        LyraReaderTilePlanRequest requests[2]{};for(auto &r:requests){r.width=595;r.height=842;r.visible={0,0,256,256};}requests[0].tier=4;requests[1].tier=-3;requests[1].page=7;
        {
            LyraReaderTilePlanBatch batch{};LyraReaderBuffer error{};const auto retire=qScopeGuard([&]{lyra_reader_desktop_tile_plan_free(batch);lyra_reader_desktop_buffer_free(error);});
            QVERIFY(lyra_reader_desktop_plan_tiles(requests,2,&batch,&error));QVERIFY(error.data==nullptr);QCOMPARE(batch.len,std::size_t(2));QVERIFY(batch.plans);QCOMPARE(reinterpret_cast<std::uintptr_t>(batch.plans)%alignof(LyraReaderPagePlan),std::uintptr_t(0));
            QCOMPARE(batch.plans[0].page,std::uint32_t(0));QCOMPARE(batch.plans[0].tile_count,std::size_t(1));QCOMPARE(batch.plans[0].tiles[0].target.width,256.0);
            QCOMPARE(batch.plans[1].page,std::uint32_t(7));QCOMPARE(batch.plans[1].tier,-3);QCOMPARE(batch.plans[1].scale,std::exp2(-.75));QCOMPARE(batch.plans[1].tile_count,std::size_t(1));
        }
        LyraReaderTilePlanBatch empty{};LyraReaderBuffer error{};const auto retire=qScopeGuard([&]{lyra_reader_desktop_tile_plan_free(empty);lyra_reader_desktop_buffer_free(error);});
        QVERIFY(lyra_reader_desktop_plan_tiles(nullptr,0,&empty,&error));QCOMPARE(empty.len,std::size_t(0));QVERIFY(empty.plans==nullptr);QVERIFY(error.data==nullptr);
    }
    void paperViewportMapsDisplayDemandWithoutDemandingConversationRows() {
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));
        QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);
        PageItem page;page.setController(&reader);page.setPageIndex(0);
        const auto height=reader.pages().first().toMap().value("height").toDouble();
        QVERIFY(page.configurePaper(height,200,80));const auto epoch=page.paperGeometryRevision();
        auto mapped=page.paperViewport(QRectF(10,190,120,100),epoch);QVERIFY(mapped.value("hit").toBool());QCOMPARE(mapped.value("rect").toRectF(),QRectF(10,190,120,20));
        mapped=page.paperViewport(QRectF(10,205,120,70),epoch);QVERIFY(!mapped.value("hit").toBool());QVERIFY(!mapped.contains("error"));
        mapped=page.paperViewport(QRectF(10,280,120,20),epoch);QCOMPARE(mapped.value("rect").toRectF(),QRectF(10,200,120,20));
        mapped=page.paperViewport(QRectF(10,-10,120,20),epoch);QCOMPARE(mapped.value("rect").toRectF(),QRectF(10,0,120,10));
        QVERIFY(page.paperViewport(QRectF(0,qQNaN(),1,1),epoch).contains("error"));
        QVERIFY(page.paperViewport(QRectF(0,0,-1,1),epoch).contains("error"));
        QVERIFY(page.configurePaper(height,200,90));QVERIFY(page.paperViewport(QRectF(0,0,100,100),epoch).contains("error"));
        page.clearPaperGeometry();mapped=page.paperViewport(QRectF(10,190,120,100),page.paperGeometryRevision());QCOMPARE(mapped.value("rect").toRectF(),QRectF(10,190,120,100));
        QCOMPARE(reader.completedRasters(),qulonglong(0));QCOMPARE(reader.pendingRasters(),0);
    }
    void nativePaperBatchPreservesPacketShapesAndRejectsPartialOutput() {
        static_assert(sizeof(LyraReaderPaperAxis)==16);
        static_assert(sizeof(LyraReaderPaperBand)==24 && offsetof(LyraReaderPaperBand,top)==8);
        static_assert(sizeof(LyraReaderPaperRegion)==104);
        static_assert(sizeof(LyraReaderPaperSegments)==72 && sizeof(LyraReaderPaperPoint)==16);
        PageItem unowned;unowned.setSize(QSizeF(160,240));QVERIFY(unowned.paperEraserSegments(QPointF(10,10),QPointF(20,20)).contains("error"));
        static_assert(sizeof(LyraReaderPaperLayout)==32 && sizeof(LyraReaderPaperQuad)==64 && sizeof(LyraReaderPaperQuadPair)==136);
        static_assert(sizeof(LyraReaderTilePlanRequest)==80 && offsetof(LyraReaderPaperQuadPair,pieces)==8);
        QCOMPARE(lyra_reader_desktop_abi_version(),LYRA_READER_DESKTOP_ABI_VERSION);
        LyraReaderPaperLayout layout{12,4,3,1,0};LyraReaderPaperQuad input[2]{{{0,0,8,12},{0,0,1,1}},{{0,2,8,6},{.25,.2,.5,.6}}};
        LyraReaderPaperQuadPair output[2]{};LyraReaderBuffer error{};
        QVERIFY(lyra_reader_desktop_paper_quads(layout,input,2,output,&error));QVERIFY(!error.data);
        QCOMPARE(output[0].count,std::uint32_t(2));QCOMPARE(output[0].pieces[0].target.height,4.0);QCOMPARE(output[0].pieces[1].target.y,7.0);
        QVERIFY(std::abs(output[1].pieces[1].source.y-.4)<1e-12);QVERIFY(std::abs(output[1].pieces[1].source.height-.4)<1e-12);
        output[0].count=99;output[1].count=98;input[1].source.width=qQNaN();
        QVERIFY(!lyra_reader_desktop_paper_quads(layout,input,2,output,&error));QVERIFY(error.data);lyra_reader_desktop_buffer_free(error);error={};
        QCOMPARE(output[0].count,std::uint32_t(99));QCOMPARE(output[1].count,std::uint32_t(98));
        QVERIFY(lyra_reader_desktop_paper_quads(layout,nullptr,0,nullptr,&error));QVERIFY(!error.data);
    }
    void paperArtworkUsesOneTextureAndOriginalUvs_data() {
        QTest::addColumn<double>("zoom");QTest::addColumn<QString>("appearance");
        QTest::newRow("100-original")<<1.0<<QString("original");QTest::newRow("125-night")<<1.25<<QString("night");
    }
    void paperArtworkUsesOneTextureAndOriginalUvs() {
        QFETCH(double,zoom);QFETCH(QString,appearance);
        QImage pixels(64,80,QImage::Format_RGBA8888);pixels.fill(Qt::transparent);{QPainter p(&pixels);p.fillRect(QRect(20,0,44,40),QColor(190,35,45));p.fillRect(QRect(20,40,44,40),QColor(35,155,75));}
        QByteArray png;QBuffer buffer(&png);QVERIFY(buffer.open(QIODevice::WriteOnly));QVERIFY(pixels.save(&buffer,"PNG"));
        QQuickWindow window;window.resize(260,340);window.setColor(QColor(11,19,29));window.setPersistentSceneGraph(false);if(QGuiApplication::platformName()!="offscreen")window.setMaximumSize(QSize(260,340));
        PageItem page;CropItem crop;crop.setParentItem(window.contentItem());crop.setPosition(QPointF(40*zoom,40*zoom));crop.setSize(QSizeF(80*zoom,100*zoom));crop.setPaperAppearance(appearance);crop.setOpacity(.7);crop.setSource(QUrl("data:image/png;base64,"+QString::fromLatin1(png.toBase64())));crop.setPaperMap(&page);crop.setPaperRect(QRectF(40,40,80,100));crop.setPaperOrigin(QPointF(40,40));crop.setPaperZoom(zoom);
        window.show();QTRY_COMPARE_WITH_TIMEOUT(crop.status(),1,15000);QTest::qWait(80);const auto before=window.grabWindow();QVERIFY(!before.isNull());QCOMPARE(crop.pixelSize(),pixels.size());
        const auto colour=[&](const QImage &image,double x,double y){return image.pixelColor(int(x*zoom*image.width()/window.width()),int(y*zoom*image.height()/window.height()));};const auto close=[](QColor a,QColor b){return std::abs(a.red()-b.red())<=2 && std::abs(a.green()-b.green())<=2 && std::abs(a.blue()-b.blue())<=2;};QVERIFY(!close(colour(before,100,50),window.color()));QVERIFY(close(colour(before,45,50),window.color()));
        const auto textures=RenderBudget::statistics().value("textureBytes").toLongLong(),resident=RenderBudget::statistics().value("residentBytes").toLongLong(),completed=RasterJobs::statistics().value("completed").toLongLong();QVERIFY(textures>0);QSignalSpy frames(&window,&QQuickWindow::frameSwapped);
        for(double gap:{.00001,20.0,60.0,30.0,0.0}) {
            const int previous=frames.size();QVERIFY(page.configurePaper(240,100,gap));crop.setHeight((100+gap)*zoom);window.update();QTRY_VERIFY_WITH_TIMEOUT(frames.size()>previous,3000);QTest::qWait(40);const auto opened=window.grabWindow();QVERIFY(!opened.isNull());const double shift=gap<.001?0:gap;
            for(double y:{50.0,75.0,95.0,115.0,135.0})QVERIFY2(close(colour(before,100,y),colour(opened,100,y+(y>=100?shift:0))),qPrintable(QString("Source sample %1 gap %2").arg(y).arg(gap)));
            if(gap>=20)QVERIFY(close(colour(opened,100,100+gap/2),window.color()));QVERIFY(close(colour(opened,45,50),window.color()));QVERIFY(crop.paperGeometryError().isEmpty());QCOMPARE(crop.pixelSize(),pixels.size());QCOMPARE(RenderBudget::statistics().value("textureBytes").toLongLong(),textures);QCOMPARE(RenderBudget::statistics().value("residentBytes").toLongLong(),resident);QCOMPARE(RasterJobs::statistics().value("completed").toLongLong(),completed);
            if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR") && gap==60){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QVERIFY(opened.save(dir+QString("/artwork-%1-%2.png").arg(zoom).arg(appearance)));}
        }
        crop.setPaperRect(QRectF(0,0,1e300,1e300));window.update();QTRY_VERIFY(!crop.paperGeometryError().isEmpty());QCOMPARE(RasterJobs::statistics().value("completed").toLongLong(),completed);crop.setPaperRect(QRectF(40,40,80,100));QTRY_VERIFY(crop.paperGeometryError().isEmpty());
        page.clearPaperGeometry();crop.setSize(QSizeF(80*zoom,100*zoom));window.update();QTest::qWait(40);QVERIFY(close(colour(window.grabWindow(),100,115),colour(before,100,115)));
        auto *borrowed=new PageItem;QVERIFY(borrowed->configurePaper(240,100,40));crop.setPaperMap(borrowed);QTest::qWait(40);QVERIFY(!window.grabWindow().isNull());delete borrowed;QTRY_VERIFY(!crop.paperMap());QTest::qWait(40);QVERIFY(close(colour(window.grabWindow(),100,115),colour(before,100,115)));
        window.hide();crop.setResourceActive(false);window.releaseResources();QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("textureBytes").toLongLong(),0,10000);
    }
    void paperArtworkDelegatesKeepDisplayCullingAndSourceRecords() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-artwork.pdf");{QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QSizeF(400,500),QPageSize::Point));pdf.setPageMargins(QMarginsF(0,0,0,0));QPainter p(&pdf);QVERIFY(p.isActive());p.fillRect(QRectF(0,0,400,500),Qt::white);}
        QImage picture(8,8,QImage::Format_RGBA8888);picture.fill(QColor(160,65,30));QByteArray png;QBuffer buffer(&png);QVERIFY(buffer.open(QIODevice::WriteOnly));QVERIFY(picture.save(&buffer,"PNG"));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE(reader->pendingCommands(),0);view.window->setProperty("secondaryRow","fill");QVERIFY(settleReaderViewport(view.window));view.window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(view.window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        for(const auto &kind:{QString("stamp"),QString("signature")}){QVariantMap mark{{"kind",kind},{"page",0},{"version",1},{"rect",QVariantMap{{"x",kind=="stamp"?20:220},{"y",200},{"width",160},{"height",100}}},{"color","#88611BFF"},{"note",kind=="stamp"?"APPROVED":""},{"stampStyle",kind=="stamp"?"approved":"image"}};if(kind=="signature")mark.insert("image",QString::fromLatin1(png.toBase64()));reader->submit("mark_create",{{"entry",mark}});QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));}
        const auto entries=reader->data().value("marks").toMap().value("annotations").toList();QCOMPARE(entries.size(),2);QString stampId,imageId;for(const auto &v:entries){const auto m=v.toMap();(m.value("kind")=="stamp"?stampId:imageId)=m.value("id").toString();}auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);QVERIFY(page->configurePaper(500,240,40));auto *rootItem=page->parentItem();auto *image=qobject_cast<CropItem *>(visualItem(rootItem,"signatureArt"+imageId));auto *stamp=visualItem(rootItem,"staticArtwork"+stampId);QVERIFY(image && stamp);QTRY_COMPARE_WITH_TIMEOUT(image->status(),1,15000);QTRY_VERIFY(stamp->isVisible());auto *lower=visualItem(stamp,"paperFragmentPaint1");QVERIFY(lower);QPointer<QQuickItem> paint;QTRY_VERIFY((paint=lower->property("item").value<QQuickItem *>()));auto *text=visualItem(paint,"staticStampText");QVERIFY(text);QTRY_VERIFY(text->width()>100);const auto font=text->property("font");const auto textWidth=text->width();const auto url=image->source();QTRY_COMPARE(reader->pendingRasters(),0);const auto completed=reader->completedRasters();QTest::qWait(100);const auto jobs=RasterJobs::statistics().value("completed").toLongLong();const QString status="Paper geometry ready";view.window->setProperty("operationStatus",status);
        for(double gap:{40.0,80.0,20.0}){QVERIFY(page->configurePaper(500,240,gap));QTRY_VERIFY(std::abs(image->height()-(100+gap))<.75);QCOMPARE(image->source(),url);QVERIFY(lower->property("item").value<QQuickItem *>()==paint);QTRY_VERIFY(std::abs(lower->y()+40)<.75);QVERIFY(image->isVisible() && image->paperGeometryError().isEmpty());QCOMPARE(text->property("font"),font);QCOMPARE(text->width(),textWidth);QVERIFY(std::abs(paint->width()-160)<.75);QCOMPARE(reader->completedRasters(),completed);QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList(),entries);QTest::qWait(90);QCOMPARE(RasterJobs::statistics().value("completed").toLongLong(),jobs);QCOMPARE(view.window->property("operationStatus").toString(),status);}
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QTest::qWait(40);QVERIFY(view.window->grabWindow().save(dir+"/artwork-delegates.png"));}
        auto *art=visualItem(rootItem,"artwork"+imageId);QVERIFY(art);auto *annotationLayer=art->parentItem();QVERIFY(annotationLayer && annotationLayer->property("visibleRegion").isValid());QVERIFY(QQmlProperty(annotationLayer,"visibleRegion").write(QRectF(210,310,180,50)));QVERIFY(page->configurePaper(500,240,80));QTRY_VERIFY(art->isVisible());QVERIFY(QQmlProperty(annotationLayer,"visibleRegion").write(QRectF(210,450,180,20)));QTRY_VERIFY(!art->isVisible());
    }
    void paperStaticTextPreservesSourceLayoutAndPaintInstances_data() {
        QTest::addColumn<double>("zoom");QTest::newRow("100-percent")<<1.0;QTest::newRow("125-percent")<<1.25;
    }
    void paperStaticTextPreservesSourceLayoutAndPaintInstances() {
        QFETCH(double,zoom);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-static.pdf");{QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QSizeF(400,500),QPageSize::Point));pdf.setPageMargins(QMarginsF(0,0,0,0));QPainter p(&pdf);QVERIFY(p.isActive());p.fillRect(QRectF(0,0,400,500),Qt::white);}
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE(reader->pendingCommands(),0);view.window->setProperty("secondaryRow","fill");QVERIFY(settleReaderViewport(view.window));view.window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(view.window,"changeZoom",Q_ARG(QVariant,zoom),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        const QString note="First line\nSecond line\nThird line";const QVariantMap text{{"kind","textBox"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",150},{"y",200},{"width",210},{"height",100}}},{"fontSize",18},{"color","#302B25FF"},{"note",note}};reader->submit("mark_create",{{"entry",text}});QTRY_COMPARE(reader->pendingCommands(),0);const QVariantMap sticky{{"kind","stickyNote"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",70},{"y",270},{"width",24},{"height",24}}},{"color","#88611BFF"},{"note","A sticky note"}};reader->submit("mark_create",{{"entry",sticky}});QTRY_COMPARE(reader->pendingCommands(),0);view.window->setProperty("selectedAnnotation",QVariant::fromValue(QJSValue(QJSValue::NullValue)));
        const auto entries=reader->data().value("marks").toMap().value("annotations").toList();QCOMPARE(entries.size(),2);QString id,stickyId;for(const auto &v:entries){const auto a=v.toMap();if(a.value("kind")=="textBox")id=a.value("id").toString();if(a.value("kind")=="stickyNote")stickyId=a.value("id").toString();}QVERIFY(!id.isEmpty() && !stickyId.isEmpty());auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);QVERIFY(page->paperSceneLimit()>1e6 && page->paperSceneLimit()<1e38);QTRY_COMPARE(reader->pendingRasters(),0);const auto completed=reader->completedRasters();QVERIFY(page->configurePaper(500,240,20));
        // The sidebar also paints these marks; scope the lookup to the actual main sheet.
        QQuickItem *region=nullptr,*lower=nullptr;QTRY_VERIFY((region=visualItem(page->parentItem(),"staticAnnotation"+id)) && region->isVisible());QTRY_VERIFY((lower=visualItem(page->parentItem(),"staticAnnotation"+stickyId)) && lower->isVisible());auto *loader0=visualItem(region,"paperFragmentPaint0"),*loader1=visualItem(region,"paperFragmentPaint1");QVERIFY(loader0 && loader1);
        QPointer<QQuickItem> body0,body1;QTRY_VERIFY((body0=loader0->property("item").value<QQuickItem *>()) && (body1=loader1->property("item").value<QQuickItem *>()));auto *text0=visualItem(body0,"staticNoteText"),*text1=visualItem(body1,"staticNoteText");QVERIFY(text0 && text1);const auto font=text0->property("font");
        for(double gap:{20.0,80.0,160.0,40.0}) {QVERIFY(page->configurePaper(500,240,gap));QTRY_VERIFY(std::abs(region->height()-(100+gap)*zoom)<.75);QTRY_VERIFY(std::abs(loader1->y()+40*zoom)<.75);QVERIFY(loader0->property("item").value<QQuickItem *>()==body0 && loader1->property("item").value<QQuickItem *>()==body1);QCOMPARE(text0->property("text").toString(),note);QCOMPARE(text1->property("text").toString(),note);QCOMPARE(text0->property("font"),font);QCOMPARE(text1->property("font"),font);QVERIFY(std::abs(text0->width()-210*zoom)<.75);QVERIFY(std::abs(text1->width()-210*zoom)<.75);QVERIFY(std::abs(lower->y()-(270+gap)*zoom)<.75);QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList(),entries);}
        QCOMPARE(reader->completedRasters(),completed);QCOMPARE(reader->pendingCommands(),0);
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QTest::qWait(40);QVERIFY(view.window->grabWindow().save(dir+QString("/static-text-%1.png").arg(zoom)));}
        const QRectF huge(0,0,1e300,1e300);QVERIFY(QQmlProperty(region,"sourceRect").write(huge));QCOMPARE(region->property("sourceRect").toRectF(),huge);QTRY_VERIFY(!region->isVisible());QTRY_VERIFY(!loader0->property("item").value<QQuickItem *>() && !loader1->property("item").value<QQuickItem *>());QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList(),entries);
    }
    void paperResizeHandlesMapCornersAndIgnoreGapSamples() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-handles.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE(reader->pendingCommands(),0);view.window->setProperty("secondaryRow","annotate");QVERIFY(settleReaderViewport(view.window));view.window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(view.window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        const QVariantMap mark{{"kind","square"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",100},{"y",280},{"width",120},{"height",50}}},{"strokeWidth",2},{"color","#1B7F3BFF"},{"note","paper handle fixture"}};reader->submit("mark_create",{{"entry",mark}});QTRY_COMPARE(reader->pendingCommands(),0);
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};const auto entries=[&]{return reader->data().value("marks").toMap().value("annotations").toList();};QCOMPARE(entries().size(),1);const auto original=entries();const auto normalized=value(view.window->property("annotations")).toList().first();QVERIFY(QMetaObject::invokeMethod(view.window,"selectAnnotation",Q_ARG(QVariant,normalized),Q_ARG(QVariant,false)));QVERIFY(settleReaderViewport(view.window));
        auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);const double height=reader->pages().first().toMap().value("height").toDouble();QVERIFY(page->configurePaper(height,150,80));QVERIFY(page->paperAxisY(1e300,true,page->paperGeometryRevision()).contains("error"));QCOMPARE(page->paperAxisY(height+20,true,page->paperGeometryRevision()).value("y").toDouble(),height+100);auto *grip=visualItem(view.window->contentItem(),"annotationHandle3");QVERIFY(grip && grip->isVisible());
        QTRY_VERIFY(std::abs(grip->mapToItem(page,QPointF(grip->width()/2,grip->height()/2)).y()-410*view.window->property("zoom").toDouble())<.75);
        const auto point=[&](double x,double y){const double zoom=view.window->property("zoom").toDouble();return page->mapToScene(QPointF(x*zoom,y*zoom)).toPoint();};
        QTest::mousePress(view.window,Qt::LeftButton,Qt::NoModifier,grip->mapToScene(QPointF(grip->width()/2,grip->height()/2)).toPoint());QTest::mouseMove(view.window,point(250,190),20);QVERIFY(value(view.window->property("annotationDraft")).isNull() || !value(view.window->property("annotationDraft")).isValid());QTest::mouseMove(view.window,point(250,450),20);QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,point(250,450),20);QTRY_COMPARE(reader->pendingCommands(),0);QCOMPARE(entries().size(),1);const auto rect=entries().first().toMap().value("rect").toMap();QVERIFY(std::abs(rect.value("height").toDouble()-90)<1);QVERIFY(std::abs(rect.value("width").toDouble()-150)<1);QCOMPARE(rect.value("y").toDouble(),280.0);
        reader->submit("marks_undo");QTRY_COMPARE(reader->pendingCommands(),0);QCOMPARE(entries(),original);
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QTest::qWait(40);QVERIFY(view.window->grabWindow().save(dir+"/resize-handles.png"));}
    }
    void paperContentPointerSkipsGapHitsAndKeepsRedactionInSourceSpace() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-content-pointer.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(settleReaderViewport(view.window));
        QVariantMap item;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("can_edit_text").toBool()){item=v.toMap();break;}QVERIFY(!item.isEmpty());auto *editor=view.window->findChild<QObject *>("contentEditing");QVERIFY(editor);auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);const auto bounds=item.value("bounds").toMap();const double x=bounds.value("x").toDouble(),y=bounds.value("y").toDouble(),width=bounds.value("width").toDouble(),h=bounds.value("height").toDouble(),cut=y-10,gap=100;QVERIFY(cut>20);QVERIFY(page->configurePaper(reader->pages().first().toMap().value("height").toDouble(),cut,gap));
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};const auto point=[&](double px,double py){const double zoom=view.window->property("zoom").toDouble();return page->mapToScene(QPointF(px*zoom,py*zoom)).toPoint();};
        QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,point(x+width/2,y+h/2));QVERIFY(!value(editor->property("selected")).isValid() || value(editor->property("selected")).isNull());QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,point(x+width/2,y+h/2+gap));QCOMPARE(value(editor->property("selected")).toMap().value("id"),item.value("id"));auto *frame=visualItem(view.window->contentItem(),"paperContentFrame0");QVERIFY(frame && frame->isVisible());QVERIFY(frame->property("paperMap").value<PageItem *>()==page);
        auto *drag=view.window->findChild<ContentDragItem *>("contentDragPreview");QVERIFY(drag);const auto selectedPoint=point(x+width/2,y+h/2+gap);QTest::mousePress(view.window,Qt::LeftButton,Qt::NoModifier,selectedPoint);QTest::mouseMove(view.window,selectedPoint+QPoint(10,15),20);QTRY_COMPARE_WITH_TIMEOUT(drag->status(),1,15000);QVERIFY(drag->active());QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,point(x+width/2,cut+gap/2),20);QTRY_VERIFY_WITH_TIMEOUT(!drag->active() && drag->residentBytes()==0,10000);QVERIFY(!reader->hasUnsavedChanges());
        QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"blackout")));QVERIFY(settleReaderViewport(view.window));QVERIFY(page->configurePaper(reader->pages().first().toMap().value("height").toDouble(),cut,gap));const double startY=cut-20,endY=y+h+20;QTest::mousePress(view.window,Qt::LeftButton,Qt::NoModifier,point(x,startY));QTest::mouseMove(view.window,point(x+80,endY+gap),20);auto gesture=value(editor->property("gesture")).toMap();QVERIFY(!gesture.isEmpty());QVERIFY(std::abs(gesture.value("height").toDouble()-(endY-startY))<1);QVERIFY(std::abs(gesture.value("y").toDouble()-startY)<1);
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QTest::qWait(40);QVERIFY(view.window->grabWindow().save(dir+"/content-preview.png"));}
        QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,point(x+80,cut+gap/2),20);QVERIFY(!value(editor->property("gesture")).isValid() || value(editor->property("gesture")).isNull());QCOMPARE(reader->pendingCommands(),0);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(!reader->hasEditDrafts());
    }
    void paperPlacedEditorKeepsNativeFocusAndNeverAuthorsTheGap() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-editor.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE(reader->pendingCommands(),0);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,150.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        auto *editing=view.window->findChild<QObject *>("placedTextEditing");QVERIFY(editing);QPointer<QQuickItem> input;QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());QVERIFY(settleReaderViewport(view.window));QTRY_COMPARE(reader->pendingCommands(),0);QTRY_COMPARE(reader->pendingRasters(),0);
        auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);const double height=reader->pages().first().toMap().value("height").toDouble();
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};
        const auto source=value(editing->property("rect")).toMap();const auto text=input->property("text").toString(),selected=input->property("selectedText").toString();const int cursor=input->property("cursorPosition").toInt();const auto completed=reader->completedRasters();auto *identity=input.data();
        for(double gap:{20.0,80.0,160.0,40.0}) {
            const auto previous=page->paperGeometryRevision();QVERIFY(page->configurePaper(height,150,gap));
            QTRY_VERIFY(std::abs(input->y()-(source.value("y").toDouble()+gap)*view.window->property("zoom").toDouble())<.75);
            QVERIFY(input.data()==identity && input->hasActiveFocus());QCOMPARE(input->property("text").toString(),text);QCOMPARE(input->property("selectedText").toString(),selected);QCOMPARE(input->property("cursorPosition").toInt(),cursor);QCOMPARE(value(editing->property("rect")).toMap(),source);QVERIFY(page->paperRegion(QRectF(0,0,10,10),previous).contains("error"));
        }
        const double cut=source.value("y").toDouble()+source.value("height").toDouble()/2;QVERIFY(page->configurePaper(height,cut,80));QTRY_VERIFY(std::abs(input->height()-(source.value("height").toDouble()+80)*view.window->property("zoom").toDouble())<.75);QVERIFY(input->hasActiveFocus());QCOMPARE(value(editing->property("rect")).toMap(),source);
        QVERIFY(page->configurePaper(height,150,80));QCOMPARE(reader->completedRasters(),completed);QCOMPARE(reader->pendingCommands(),0);
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QTest::qWait(40);QVERIFY(view.window->grabWindow().save(dir+"/placed-editor.png"));}
        QVERIFY(QMetaObject::invokeMethod(input,"selectAll"));for(char key:QByteArray("Kept native editor"))QTest::keyClick(view.window,key);QTest::keyClick(view.window,Qt::Key_Return,Qt::ControlModifier);QTRY_VERIFY(!editing->property("active").toBool());QTRY_COMPARE(reader->pendingCommands(),0);
        const auto entries=[&]{return reader->data().value("marks").toMap().value("annotations").toList();};QCOMPARE(entries().size(),1);QCOMPARE(entries().first().toMap().value("note").toString(),QString("Kept native editor"));QCOMPARE(entries().first().toMap().value("rect").toMap().value("y").toDouble(),source.value("y").toDouble());
        reader->submit("marks_undo");QTRY_COMPARE(reader->pendingCommands(),0);QCOMPARE(entries().first().toMap().value("note").toString(),text);reader->submit("marks_redo");QTRY_COMPARE(reader->pendingCommands(),0);
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE(reopened.pendingCommands(),0);QCOMPARE(reopened.data().value("annotations").toList().first().toMap().value("contents").toString(),QString("Kept native editor"));
    }
    void paperFormWidgetsRetainTheirNativeSelectionAndSourceRectangles() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-form.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/form-fields.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(QMetaObject::invokeMethod(view.window,"toggleForms"));QTRY_VERIFY(reader->data().contains("forms"));QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(settleReaderViewport(view.window));
        QVariantMap field,source;for(const auto &v:reader->data().value("forms").toMap().value("fields").toList()){const auto f=v.toMap();const auto widgets=f.value("widgets").toList();if(f.value("kind")=="text" && f.value("editable").toBool() && !f.value("multiline").toBool() && !widgets.isEmpty() && widgets.first().toMap().value("page").toInt()==0){field=f;source=widgets.first().toMap();break;}}
        QVERIFY(!field.isEmpty());QPointer<QQuickItem> input=visualItem(view.window->contentItem(),"formText_"+field.value("id").toString()+"_0");QVERIFY(input && input->isVisible());auto *widget=input->parentItem();auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);const auto height=reader->pages().first().toMap().value("height").toDouble(),y=source.value("y_pt").toDouble();QVERIFY(y>1);input->forceActiveFocus();QVERIFY(QMetaObject::invokeMethod(input,"selectAll"));const auto selected=input->property("selectedText");const auto text=input->property("text");auto *identity=input.data();
        for(double gap:{20.0,80.0,40.0}) {QVERIFY(page->configurePaper(height,y/2,gap));QTRY_VERIFY(std::abs(widget->y()-(y+gap)*view.window->property("zoom").toDouble())<.75);QVERIFY(input.data()==identity && input->hasActiveFocus());QCOMPARE(input->property("selectedText"),selected);QCOMPARE(input->property("text"),text);QVERIFY(reader->editDrafts().isEmpty());}
        const double sourceHeight=source.value("height_pt").toDouble();QVERIFY(page->configurePaper(height,y+sourceHeight/2,80));QTRY_VERIFY(std::abs(widget->height()-(sourceHeight+80)*view.window->property("zoom").toDouble())<.75);QVERIFY(input->hasActiveFocus());
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QTest::qWait(40);QVERIFY(view.window->grabWindow().save(dir+"/form-widget.png"));}
        QInputMethodEvent event;event.setCommitString("Paper form value");QCoreApplication::sendEvent(input,&event);QTRY_COMPARE(reader->editDrafts().value("forms").toMap().value(field.value("id").toString()).toMap().value("text").toString(),QString("Paper form value"));QVERIFY(page->configurePaper(height,y/2,40));QVERIFY(input.data()==identity);
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),2,10000);reopened.submit("forms");QTRY_COMPARE(reopened.pendingCommands(),0);QVariantMap saved;for(const auto &v:reopened.data().value("forms").toMap().value("fields").toList())if(v.toMap().value("name")==field.value("name"))saved=v.toMap();QVERIFY(!saved.isEmpty());QCOMPARE(saved.value("value").toString(),QString("Paper form value"));QCOMPARE(saved.value("widgets").toList().first().toMap().value("y_pt"),source.value("y_pt"));
    }
    void paperContentEditorMovesWithoutChangingItsPdfCommandBounds() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-content.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(settleReaderViewport(view.window));
        QVariantMap item;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("can_edit_text").toBool()){item=v.toMap();break;}QVERIFY(!item.isEmpty());auto *editor=view.window->findChild<QObject *>("contentEditing");QVERIFY(editor);QVERIFY(QMetaObject::invokeMethod(editor,"editText",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));
        QPointer<QQuickItem> input;QTRY_VERIFY((input=visualItem(view.window->contentItem(),"contentInlineText0")) && input->isVisible() && input->hasActiveFocus());auto *scroll=visualItem(view.window->contentItem(),"contentInlineScroll0");QVERIFY(scroll);auto *page=qobject_cast<PageItem *>(visualItem(view.window->contentItem(),"pdfPage0"));QVERIFY(page);
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};const auto source=value(editor->property("payload")).toMap().value("bounds").toMap();const double y=source.value("y").toDouble(),height=reader->pages().first().toMap().value("height").toDouble();QVERIFY(y>1);const auto text=input->property("text");QVERIFY(QMetaObject::invokeMethod(input,"selectAll"));const auto selected=input->property("selectedText");auto *identity=input.data();
        for(double gap:{20.0,80.0,40.0}){QVERIFY(page->configurePaper(height,y/2,gap));QTRY_VERIFY(std::abs(scroll->y()-(y+gap)*view.window->property("zoom").toDouble())<.75);QVERIFY(input.data()==identity && input->hasActiveFocus());QCOMPARE(input->property("text"),text);QCOMPARE(input->property("selectedText"),selected);QCOMPARE(value(editor->property("payload")).toMap().value("bounds").toMap(),source);}
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto dir=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(dir));QTest::qWait(40);QVERIFY(view.window->grabWindow().save(dir+"/content-editor.png"));}
        for(char key:QByteArray("Native content draft"))QTest::keyClick(view.window,key);QCOMPARE(value(editor->property("payload")).toMap().value("bounds").toMap(),source);QTest::keyClick(view.window,Qt::Key_Escape);QTRY_VERIFY(!reader->hasEditDrafts());QVERIFY(!reader->hasUnsavedChanges());
    }
    void paperPointerSelectionAndInkSkipTheGap_data() {
        QTest::addColumn<double>("zoom");QTest::newRow("100-percent")<<1.0;QTest::newRow("125-percent")<<1.25;
    }
    void paperPointerSelectionAndInkSkipTheGap() {
        QFETCH(double,zoom);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-pointer.pdf");
        {QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QSizeF(400,500),QPageSize::Point));pdf.setPageMargins(QMarginsF(0,0,0,0));QPainter painter(&pdf);QVERIFY(painter.isActive());painter.setFont(QFont("DejaVu Sans",16));painter.drawText(QPointF(50,90),"UPPER");painter.drawText(QPointF(50,270),"LOWER");}
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE(reader.pendingCommands(),0);QVERIFY(settleReaderViewport(window));
        // Opening the 46-point row can legitimately refit the viewport. Finish that change
        // before freezing the scale used for native pointer coordinates.
        window->setProperty("secondaryRow","annotate");QVERIFY(settleReaderViewport(window));window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,zoom),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTRY_VERIFY(std::abs(window->property("zoom").toDouble()-zoom)<.001);
        auto *page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);QVERIFY(page->configurePaper(500,150,80));reader.requestText(0);QTRY_VERIFY(reader.textPages().contains("0"));
        const auto entries=[&]{return reader.data().value("marks").toMap().value("annotations").toList();};
        const auto point=[&](double x,double y){return page->mapToScene(QPointF(x*zoom,y*zoom)).toPoint();};
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};
        QCOMPARE(page->paperPoint(QPointF(50,190)).value("hit").toBool(),false);QCOMPARE(page->paperPoint(QPointF(50,350)).value("y").toDouble(),270.0);QVERIFY(page->paperPoint(QPointF(qQNaN(),0)).contains("error"));
        window->setProperty("annotationTool","select");window->setProperty("selection",QVariant());QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point(70,190));QVERIFY(!value(window->property("selection")).isValid() || value(window->property("selection")).isNull());
        const auto chars=reader.textPages().value("0").toMap().value("chars").toList();QVariantMap lower;
        for(const auto &v:chars){const auto c=v.toMap();if(c.value("unicode").toInt()=='L' && c.value("y_pt").toDouble()>150){lower=c;break;}}
        QVERIFY(!lower.isEmpty());const auto lowerPoint=point(lower.value("x_pt").toDouble()+lower.value("width_pt").toDouble()/2,lower.value("y_pt").toDouble()+lower.value("height_pt").toDouble()/2+80);
        QTest::mouseDClick(window,Qt::LeftButton,Qt::NoModifier,lowerPoint,20);QVariant selected;QVERIFY(QMetaObject::invokeMethod(window,"selectedText",Q_RETURN_ARG(QVariant,selected)));QCOMPARE(selected.toString(),QString("LOWER"));
        auto *selection=visualItem(window->contentItem(),"paperTextSelection");QVERIFY(selection && selection->isVisible());QVERIFY(selection->property("paperMap").value<PageItem *>()==page);
        if(qEnvironmentVariableIsSet("LYRA_READER_PAPER_EVIDENCE_DIR")){const auto folder=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");QVERIFY(QDir().mkpath(folder));QTest::qWait(40);QVERIFY(window->grabWindow().save(folder+QString("/pointer-selection-%1.png").arg(zoom)));}
        window->setProperty("selection",QVariant());window->setProperty("annotationTool","ink");
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(50,130));QTest::mouseMove(window,point(180,190),20);QTest::mouseMove(window,point(80,350),20);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(80,350),20);QTRY_COMPARE(reader.pendingCommands(),0);QCOMPARE(entries().size(),1);
        auto points=entries().first().toMap().value("paths").toList().first().toList();QCOMPARE(points.size(),2);QVERIFY(std::abs(points.first().toMap().value("y").toDouble()-130)<1);QVERIFY(std::abs(points.last().toMap().value("y").toDouble()-270)<1);
        reader.submit("marks_undo");QTRY_COMPARE(reader.pendingCommands(),0);QVERIFY(entries().isEmpty());
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(50,350));QTest::mouseMove(window,point(80,360),20);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(80,360),20);QTRY_COMPARE(reader.pendingCommands(),0);QCOMPARE(entries().size(),1);points=entries().first().toMap().value("paths").toList().first().toList();QVERIFY(std::abs(points.first().toMap().value("y").toDouble()-270)<1);
        reader.submit("marks_undo");QTRY_COMPARE(reader.pendingCommands(),0);QVERIFY(entries().isEmpty());
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,point(50,190));QTest::mouseMove(window,point(80,350),20);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,point(80,350),20);QTRY_COMPARE(reader.pendingCommands(),0);QVERIFY(entries().isEmpty());
        qInfo()<<"paper-pointer graphicsApi"<<int(window->rendererInterface()->graphicsApi())<<QGuiApplication::platformName();
    }
    void eraserPaperGapDoesNotCutHiddenInkAndTheVisibleSweepHasOneUndo() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-eraser.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        ReaderController reader;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("reader",&reader);engine.load(QUrl("qrc:/qml/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE(reader.pendingCommands(),0);
        window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QTRY_VERIFY(visualItem(window->contentItem(),"pdfPage0"));auto *page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);
        const auto height=reader.pages().first().toMap().value("height").toDouble();QVERIFY(page->configurePaper(height,200,200));
        const auto entries=[&]{return reader.data().value("marks").toMap().value("annotations").toList();};
        const QVariantMap ink{{"kind","ink"},{"page",0},{"version",1},{"paths",QVariantList{QVariantList{QVariantMap{{"x",200},{"y",250}},QVariantMap{{"x",300},{"y",250}}}}},{"strokeWidth",2},{"color","#1B7F3BFF"},{"note","paper sweep fixture"}};
        reader.submit("mark_create",{{"entry",ink}});QTRY_COMPARE(reader.pendingCommands(),0);QCOMPARE(entries().size(),1);const auto original=entries();
        window->setProperty("annotationTool","eraser");
        const auto begin=[&](double y){const QVariant point=QVariantMap{{"x",250},{"y",y}};return QMetaObject::invokeMethod(window,"beginErase",Q_ARG(QVariant,0),Q_ARG(QVariant,point));};
        const auto finish=[&]{return QMetaObject::invokeMethod(window,"commitErase");};
        const auto idle=[&]{return reader.pendingCommands()==0 && window->property("eraserToken").toString().isEmpty();};
        QVERIFY(begin(250));QTRY_COMPARE(reader.pendingCommands(),0);QVERIFY(finish());QTRY_VERIFY_WITH_TIMEOUT(idle(),10000);QCOMPARE(entries(),original);
        QVERIFY(begin(450));QTRY_COMPARE(reader.pendingCommands(),0);
        const auto value=window->property("erasePreview");const auto preview=value.metaType()==QMetaType::fromType<QJSValue>()?value.value<QJSValue>().toVariant().toList():value.toList();QCOMPARE(preview.size(),2);
        QVERIFY(finish());QTRY_VERIFY_WITH_TIMEOUT(idle(),10000);QCOMPARE(entries().size(),2);
        for(int i=0;i<2;++i)QCOMPARE(entries()[i].toMap().value("paths"),preview[i].toMap().value("paths"));
        reader.submit("marks_undo");QTRY_COMPARE(reader.pendingCommands(),0);QCOMPARE(entries(),original);
        const auto invalid=page->paperEraserSegments(QPointF(qQNaN(),0),QPointF(0,0));QVERIFY(invalid.contains("error"));
    }
    void paperSegmentsKeepPixelsTexturePayloadAndRasterDemand_data() {
        QTest::addColumn<double>("zoom");QTest::addColumn<bool>("tiles");QTest::addColumn<QString>("appearance");QTest::addColumn<bool>("paintMarks");QTest::addColumn<double>("rotation");
        QTest::newRow("100-percent")<<1.0<<false<<QString("original")<<false<<0.0;QTest::newRow("150-percent")<<1.5<<false<<QString("original")<<false<<0.0;QTest::newRow("400-percent-tiles")<<4.0<<true<<QString("original")<<false<<0.0;
        QTest::newRow("100-percent-warm")<<1.0<<false<<QString("warm")<<false<<0.0;QTest::newRow("400-percent-night-tiles")<<4.0<<true<<QString("night")<<false<<0.0;
        QTest::newRow("100-percent-annotations")<<1.0<<false<<QString("original")<<true<<0.0;QTest::newRow("150-percent-annotations")<<1.5<<false<<QString("original")<<true<<0.0;QTest::newRow("400-percent-night-annotations")<<4.0<<true<<QString("night")<<true<<0.0;
        QTest::newRow("100-percent-rotated-annotations")<<1.0<<false<<QString("original")<<true<<10.0;
    }
    void paperSegmentsKeepPixelsTexturePayloadAndRasterDemand() {
        QFETCH(double,zoom);QFETCH(bool,tiles);QFETCH(QString,appearance);QFETCH(bool,paintMarks);QFETCH(double,rotation);const double paperWidth=tiles?480:160,paperHeight=tiles?720:240,split=tiles?40:84,gapLimit=tiles?30:60;QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("paper-stripes.pdf");
        {
            QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QSizeF(paperWidth,paperHeight),QPageSize::Point));pdf.setPageMargins(QMarginsF(0,0,0,0));
            QPainter painter(&pdf);QVERIFY(painter.isActive());
            for(int row=0;row<int(paperHeight/10);++row)painter.fillRect(QRectF(0,row*10,paperWidth,10),QColor(30+(row*37)%180,25+(row*53)%180,20+(row*71)%180));
        }
        QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto originalPdf=source.readAll();source.close();
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE(reader.pendingCommands(),0);
        const auto size=reader.pages().first().toMap();QCOMPARE(size.value("width").toDouble(),paperWidth);QCOMPARE(size.value("height").toDouble(),paperHeight);
        QQuickWindow window;window.resize(420,600);window.setColor(QColor(11,19,29));window.setPersistentSceneGraph(false);
        if(QGuiApplication::platformName()!="offscreen")window.setMaximumSize(QSize(420,600));
        QQuickItem group(window.contentItem());group.setPosition(QPointF(20,20));group.setTransformOrigin(QQuickItem::TopLeft);group.setRotation(rotation);
        PageItem page;page.setParentItem(&group);page.setPosition(QPointF(0,0));page.setSize(QSizeF(paperWidth*zoom,paperHeight*zoom));page.setRasterScale(zoom);page.setPaperAppearance(appearance);page.setController(&reader);page.setPageIndex(0);page.setTilesEnabled(true);page.setVisibleRegion(QRectF(0,0,qMin(paperWidth,400/zoom),qMin(paperHeight,580/zoom)));
        AnnotationOverlay annotations;annotations.setParentItem(&group);annotations.setPosition(page.position());annotations.setSize(page.size());annotations.setZoom(zoom);annotations.setPaperAppearance(appearance);annotations.setPaperMap(&page);
        if(paintMarks)annotations.setAnnotations({
            QVariantMap{{"id","tear-highlight"},{"kind","highlight"},{"color","#FFCC4080"},{"blend","multiply"},{"quads",QVariantList{QVariantMap{{"x",5},{"y",5},{"width",145},{"height",225}}}}},
            QVariantMap{{"id","tear-ink"},{"kind","ink"},{"color","#C03030FF"},{"strokeWidth",3},{"paths",QVariantList{QVariantList{QVariantMap{{"x",20},{"y",20}},QVariantMap{{"x",140},{"y",220}}}}}}
        });
        window.show();QTRY_VERIFY2_WITH_TIMEOUT(page.refined() && page.texturesReady(),qPrintable(QString("loaded=%1 refined=%2 pending=%3 error=%4").arg(page.loaded()).arg(page.refined()).arg(reader.pendingRasters()).arg(reader.error())),15000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingRasters(),0,15000);QTest::qWait(80);
        qInfo()<<"Paper segment graphics API:"<<window.rendererInterface()->graphicsApi()<<"platform:"<<QGuiApplication::platformName();
        if(tiles)QVERIFY(page.loadedTileCount()>0);const auto before=window.grabWindow();QVERIFY(!before.isNull());const auto evidence=qEnvironmentVariable("LYRA_READER_PAPER_EVIDENCE_DIR");const auto prefix=QString("/paper-%1-%2-%3-r%4").arg(int(zoom*100)).arg(appearance).arg(paintMarks?"annotations":"plain").arg(int(rotation));if(!evidence.isEmpty()){QVERIFY(QDir().mkpath(evidence));QVERIFY(before.save(evidence+prefix+"-before.png"));}const auto completed=reader.completedRasters();const auto textureBytes=RenderBudget::statistics().value("textureBytes").toLongLong();QVERIFY(textureBytes>0);
        const auto sample=[&](const QImage &image,double x,double y){const auto scene=group.mapToScene(QPointF(x-20,y-20));return image.pixelColor(qBound(0,int(scene.x()*image.width()/window.width()),image.width()-1),qBound(0,int(scene.y()*image.height()/window.height()),image.height()-1));};
        const auto closeColour=[](const QColor &a,const QColor &b){return std::abs(a.red()-b.red())<=2 && std::abs(a.green()-b.green())<=2 && std::abs(a.blue()-b.blue())<=2;};
        QVERIFY(!closeColour(sample(before,40,20+15*zoom),window.color()));
        QSignalSpy frames(&window,&QQuickWindow::frameSwapped);qulonglong stableBuilds=0;
        for(int step=0;step<=4;++step) {
            const double gap=gapLimit*step/4;const auto previous=frames.size();QVERIFY(page.configurePaper(paperHeight,split,gap));page.setHeight((paperHeight+gap)*zoom);annotations.setHeight(page.height());window.update();
            QTRY_VERIFY_WITH_TIMEOUT(frames.size()>previous,3000);QTest::qWait(40);const auto opened=window.grabWindow();QVERIFY(!opened.isNull());if(!evidence.isEmpty())QVERIFY(opened.save(evidence+prefix+QString("-step%1.png").arg(step)));
            for(int row:{0,2,5,7,10,13,17,22}) {
                const double originalY=row*10+5,shift=originalY>=split?gap:0;
                if(20+(originalY+shift)*zoom>=window.height()-10)continue;
                QVERIFY2(closeColour(sample(before,20+80*zoom,20+originalY*zoom),sample(opened,20+80*zoom,20+(originalY+shift)*zoom)),qPrintable(QString("row %1 gap %2 before %3 after %4").arg(row).arg(gap).arg(sample(before,20+80*zoom,20+originalY*zoom).name()).arg(sample(opened,20+80*zoom,20+(originalY+shift)*zoom).name())));
            }
            if(gap>0)QVERIFY(closeColour(sample(opened,20+80*zoom,20+(split+gap/2)*zoom),window.color()));
            QCOMPARE(reader.completedRasters(),completed);QCOMPARE(reader.pendingRasters(),0);QCOMPARE(RenderBudget::statistics().value("textureBytes").toLongLong(),textureBytes);QVERIFY(page.paperGeometryError().isEmpty());
            if(step==1)stableBuilds=annotations.geometryBuildCount();else if(step>1)QCOMPARE(annotations.geometryBuildCount(),stableBuilds);
        }
        QVERIFY(!page.configurePaper(paperHeight,split,qQNaN()));QVERIFY(page.paperGeometryActive());QVERIFY(!page.paperGeometryError().isEmpty());
        QVERIFY(!page.configurePaper(paperHeight,split,1e300));QVERIFY(!page.paperGeometryError().isEmpty());
        QVERIFY(page.configurePaper(paperHeight,split,gapLimit));QVERIFY(page.paperGeometryError().isEmpty());
        page.clearPaperGeometry();page.setHeight(paperHeight*zoom);annotations.setHeight(page.height());window.update();QTest::qWait(50);const auto closed=window.grabWindow();QVERIFY(!closed.isNull());
        for(int row:{2,7,10})QVERIFY(closeColour(sample(before,20+80*zoom,20+(row*10+5)*zoom),sample(closed,20+80*zoom,20+(row*10+5)*zoom)));
        QCOMPARE(reader.completedRasters(),completed);QVERIFY(page.configurePaper(paperHeight,split,gapLimit));reader.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(!reader.loading() && reader.pendingCommands()==0);QVERIFY(!page.paperGeometryActive());
        window.hide();window.releaseResources();page.setController(nullptr);QTRY_COMPARE_WITH_TIMEOUT(RenderBudget::statistics().value("textureBytes").toLongLong(),0,10000);
        QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),originalPdf);
    }
    void surfaceDensityPlansKeepTheResidentBudgetAndReportRejection() {
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf"));QTRY_VERIFY(reader.pageCount()==9 && !reader.loading() && reader.pendingCommands()==0);
        QTRY_VERIFY(RasterJobs::statistics().value("queued").toInt()==0 && RasterJobs::statistics().value("running").toInt()==0);
        std::vector<RasterJobs::Handle> admissions;while(auto ticket=RasterJobs::enqueue())admissions.push_back(ticket);
        const auto release=qScopeGuard([&]{reader.clearRasterDemand(987);for(auto &ticket:admissions){RasterJobs::Run run(ticket);}});
        const auto size=reader.pages().first().toMap();const QRectF visible(0,0,size.value("width").toDouble(),size.value("height").toDouble());
        const auto plan=reader.requestTilesForSurface(987,0,4.0,2*1024*1024,visible,{});QVERIFY(plan.accepted);QCOMPARE(plan.tiles.size(),1);QCOMPARE(plan.tiles.first().level,-3);
        const auto bad=reader.requestTilesForSurface(987,0,4.0,0,visible,{});QVERIFY(!bad.accepted);QVERIFY(bad.tiles.isEmpty());QVERIFY(!reader.error().isEmpty());
        const auto retried=reader.requestTilesForSurface(987,0,4.0,2*1024*1024,visible,{});QVERIFY(retried.accepted);QCOMPARE(retried.tiles.size(),1);
    }
    void densityGridMatchesThePreMigrationNativeRequests() {
        QFile golden(root+"/tests/fixtures/tile-plan/native-density.json");QVERIFY(golden.open(QIODevice::ReadOnly));
        const auto frozen=QJsonDocument::fromJson(golden.readAll()).object();const auto cases=frozen.value("cases").toArray();QCOMPARE(cases.size(),20);
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(QCoreApplication::applicationDirPath()+"/fixtures/qt-nine-pages.pdf"));
        QTRY_VERIFY(reader.pageCount()==9 && !reader.loading() && reader.pendingCommands()==0);
        const auto size=reader.pages().first().toMap();QCOMPARE(size.value("width").toDouble(),frozen.value("pageSize").toObject().value("width").toDouble());QCOMPARE(size.value("height").toDouble(),frozen.value("pageSize").toObject().value("height").toDouble());
        QTRY_VERIFY(RasterJobs::statistics().value("queued").toInt()==0 && RasterJobs::statistics().value("running").toInt()==0);
        std::vector<RasterJobs::Handle> admissions;while(auto ticket=RasterJobs::enqueue())admissions.push_back(ticket);
        const auto release=qScopeGuard([&]{reader.clearRasterDemand(988);for(auto &ticket:admissions){RasterJobs::Run run(ticket);}});
        QCOMPARE(admissions.size(),size_t(RasterJobs::maximumQueued));
        const auto rectangle=[](const QJsonObject &r){return QRectF(r.value("x").toDouble(qQNaN()),r.value("y").toDouble(qQNaN()),r.value("width").toDouble(qQNaN()),r.value("height").toDouble(qQNaN()));};
        const auto near=[](const QRectF &a,const QRectF &b){return std::abs(a.x()-b.x())<1e-8 && std::abs(a.y()-b.y())<1e-8 && std::abs(a.width()-b.width())<1e-8 && std::abs(a.height()-b.height())<1e-8;};
        for(const auto &item:cases){const auto c=item.toObject();const auto name=c.value("name").toString();const auto visible=rectangle(c.value("visible").toObject());
            const auto actual=reader.requestTiles(988,c.value("page").toInt(),c.value("requestedLevel").toInt(),visible,{});const auto expected=c.value("tiles").toArray();
            QCOMPARE(actual.size(),expected.size());QMap<QString,QJsonObject> byKey;for(const auto &e:expected)byKey.insert(e.toObject().value("key").toString(),e.toObject());
            double previous=-1;
            for(const auto &tile:actual){QVERIFY2(byKey.contains(tile.key),qPrintable(name+": "+tile.key));const auto e=byKey.take(tile.key);
                QCOMPARE(tile.page,e.value("page").toInt());QCOMPARE(tile.level,e.value("level").toInt());QCOMPARE(tile.column,e.value("column").toInt());QCOMPARE(tile.row,e.value("row").toInt());
                QVERIFY(std::abs(tile.scale-e.value("scale").toDouble())<1e-12);QVERIFY2(near(tile.target,rectangle(e.value("target").toObject())),qPrintable(name));QVERIFY2(near(tile.render,rectangle(e.value("render").toObject())),qPrintable(name));
                const auto clipped=visible.intersected(QRectF(0,0,size.value("width").toDouble(),size.value("height").toDouble()));const double distance=QLineF(tile.target.center(),clipped.center()).length();QVERIFY(distance+1e-8>=previous);previous=distance;
            }
            QVERIFY(byKey.isEmpty());QVERIFY(reader.error().isEmpty());reader.clearTileDemand(988);
        }
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
    void contentsLinksNavigateWhileChapterReferencesKeepTheirLocalPreviews() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        for(const auto &name:{"navigation-notes.pdf","chapter-previews.pdf"})
            QVERIFY(QFile::copy(root+"/tests/fixtures/"+name,scratch.path()+"/"+name));
        WorkspaceController workspace;QQmlApplicationEngine engine;
        engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);
        engine.rootContext()->setContextProperty("reader",workspace.activeReader());
        engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        auto *preview=workspace.preview();
        workspace.openFile(QUrl::fromLocalFile(scratch.path()+"/navigation-notes.pdf"));
        auto *reader=workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTRY_VERIFY(!window->property("positionRestoring").toBool());
        reader->submit("links",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto links=reader->data().value("links").toList();QCOMPARE(links.size(),2);
        const auto click=[&](const QVariantMap &hit) {
            return QMetaObject::invokeMethod(window,"pageClicked",Q_ARG(QVariant,0),
                Q_ARG(QVariant,hit.value("x_pt").toDouble()+hit.value("width_pt").toDouble()-2),
                Q_ARG(QVariant,hit.value("y_pt").toDouble()+hit.value("height_pt").toDouble()/2),
                Q_ARG(QVariant,320),Q_ARG(QVariant,200));
        };
        for(const auto &value:links) {
            const auto link=value.toMap();QVERIFY(link.value("navigation").toBool());
            QVERIFY(click(link));
            QTRY_COMPARE_WITH_TIMEOUT(window->property("currentPage").toInt(),link.value("page").toInt(),10000);
            QVERIFY(!preview->visible());QVERIFY(!preview->loading());
            QVERIFY(QMetaObject::invokeMethod(window,"goBack"));
            QTRY_COMPARE(window->property("currentPage").toInt(),0);
        }
        workspace.openFile(QUrl::fromLocalFile(scratch.path()+"/chapter-previews.pdf"));reader=workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),4,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("caption_mentions",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto mentions=reader->data().value("caption_mentions").toList();QCOMPARE(mentions.size(),4);
        for(const auto &value:mentions) {
            const auto mention=value.toMap();QVERIFY(click(mention));
            QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);
            QCOMPARE(preview->model().value("kind").toString(),QString("figure"));
            QCOMPARE(preview->model().value("title").toString(),mention.value("kind").toString()+" "+mention.value("label").toString());
            const auto region=preview->model().value("region").toMap();
            QVERIFY(region.value("height_pt").toDouble()>0 && region.value("height_pt").toDouble()<180);
            if(mention.value("kind").toString()=="Equation")QVERIFY(region.value("height_pt").toDouble()<50);
            preview->close();
        }
        reader->submit("citations",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto citations=reader->data().value("citations").toList();QVariantMap group;
        for(const auto &value:citations)if(value.toMap().value("labels").toList().size()==6)group=value.toMap();
        QVERIFY(!group.isEmpty());QVERIFY(click(group));QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);
        QCOMPARE(preview->model().value("kind").toString(),QString("reference"));
        QCOMPARE(preview->model().value("entries").toList().size(),6);
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
        const auto target=preview->model();QSignalSpy ordinaryWindow(&workspace,&WorkspaceController::newWindowRequested);preview->openWindow();QCOMPARE(ordinaryWindow.size(),0);
        auto *auxiliary=window->findChild<QQuickWindow *>("pdfPreviewWindow");QVERIFY(auxiliary);QTRY_VERIFY(auxiliary->isVisible());QCOMPARE(auxiliary->property("requestedPage").toInt(),target.value("page").toInt());QCOMPARE(auxiliary->property("targetRegion").toMap().value("y_pt"),target.value("region").toMap().value("y_pt"));if(qEnvironmentVariableIsSet("LYRA_READER_CHECK_PDF_AUX_OBSERVE"))QTest::qWait(1800);QVERIFY(auxiliary->close());if(qEnvironmentVariableIsSet("LYRA_READER_CHECK_PDF_AUX_OBSERVE"))QTest::qWait(800);
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
    void resizingEditablePdfTextKeepsItsFontSizeAndReflowsTheWords() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("text-reflow.pdf");
        {QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QSizeF(500,600),QPageSize::Point));pdf.setPageMargins(QMarginsF(0,0,0,0));QPainter painter(&pdf);QVERIFY(painter.isActive());painter.fillRect(QRect(0,0,500,600),Qt::white);QVERIFY(painter.end());}
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const QString words="alpha beta gamma delta epsilon zeta";
        const auto revision=reader->data().value("content_objects").toMap().value("revision");
        reader->submit("content_stage",{{"page",0},{"command",QVariantMap{{"InsertText",QVariantMap{{"revision",revision},{"text",words},{"bounds",QVariantMap{{"x",70},{"y",80},{"width",320},{"height",30}}},{"font","Helvetica"},{"size",12},{"colour",QVariantList{48,43,37,255}},{"alignment",0}}}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->hasUnsavedChanges(),15000);
        QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap item;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("kind")=="text"){item=v.toMap();break;}
        QVERIFY(!item.isEmpty());QVERIFY(item.value("can_edit_text").toBool());const auto size=item.value("size").toDouble();QVERIFY(qAbs(size-12)<.01);
        auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));
        const QVariantMap requested{{"x",70},{"y",80},{"width",90},{"height",140}};
        const auto generation=reader->documentGeneration();QVERIFY(QMetaObject::invokeMethod(editor,"applyGeometry",Q_ARG(QVariant,item),Q_ARG(QVariant,requested)));
        QTRY_VERIFY_WITH_TIMEOUT(reader->documentGeneration()!=generation && !reader->pendingCommands(),15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        reader->requestText(0);reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->textPages().contains("0"));
        const auto text=reader->textPages().value("0").toMap().value("text").toString();QCOMPARE(text.simplified(),words);QVERIFY(text.trimmed().split(QRegularExpression("[\\r\\n]+"),Qt::SkipEmptyParts).size()>1);
        int lines=0;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList()){const auto line=v.toMap();if(line.value("kind")=="text"){++lines;QVERIFY(qAbs(line.value("size").toDouble()-size)<.01);}}
        QVERIFY(lines>0);QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);source.close();
        QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);reader->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->textPages().value("0").toMap().value("text").toString().trimmed().split(QRegularExpression("[\\r\\n]+"),Qt::SkipEmptyParts).size(),1);
        QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->hasUnsavedChanges(),15000);reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(!reader->loading() && !reader->pendingCommands());reader->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto reopened=reader->textPages().value("0").toMap().value("text").toString();QCOMPARE(reopened.simplified(),words);QVERIFY(reopened.trimmed().split(QRegularExpression("[\\r\\n]+"),Qt::SkipEmptyParts).size()>1);
    }
    void contentCornersResizeOneSharedRevisionAndSave_data() {
        QTest::addColumn<int>("corner");QTest::addColumn<QString>("kind");QTest::addColumn<bool>("paper");for(const auto &kind:QStringList{"text","image","graphic","link"})for(int i=0;i<4;++i)QTest::newRow(qPrintable(kind+QString::number(i)))<<i<<kind<<false;QTest::newRow("text-across-paper-offset")<<3<<QString("text")<<true;QTest::newRow("graphic-across-paper-offset")<<0<<QString("graphic")<<true;QTest::newRow("link-across-paper-offset")<<1<<QString("link")<<true;
    }
    void contentCornersResizeOneSharedRevisionAndSave() {
        QFETCH(int,corner);QFETCH(QString,kind);QFETCH(bool,paper);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("resize-content.pdf");const auto fixture=kind=="graphic"?QString("form-text-pages.pdf"):kind=="link"?QString("link-borders.pdf"):QString("text-page.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/"+fixture,path));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));auto original=file.readAll();file.close();NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;if(qEnvironmentVariableIsSet("LYRA_READER_CORNER_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(kind=="image" ? 1000 : 700,600);}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(!reader->loading() && reader->pageCount()==(kind=="graphic"?2:1) && !reader->pendingCommands());QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);if(kind=="image"){const auto png=scratch.filePath("corner-pixels.png");QImage pixels(8,8,QImage::Format_RGBA8888);pixels.fill(Qt::red);{QPainter painter(&pixels);painter.fillRect(QRect(4,0,4,8),Qt::blue);}QVERIFY(pixels.save(png));reader->submit("content_stage",{{"page",0},{"command",QVariantMap{{"InsertImage",QVariantMap{{"revision",reader->data().value("content_objects").toMap().value("revision")},{"bounds",QVariantMap{{"x",200},{"y",300},{"width",120},{"height",120}}},{"image_path",png}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->hasUnsavedChanges(),15000);QVERIFY(file.open(QIODevice::ReadOnly));original=file.readAll();file.close();reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);}const auto model=reader->data().value("content_objects").toMap();QVariantMap item;for(const auto &v:model.value("items").toList()){const auto candidate=v.toMap(),r=candidate.value("bounds").toMap();if((kind=="text" && candidate.value("text").toString().contains("LyraReader fixture")) || (kind=="image" && candidate.value("kind")=="image") || (kind=="graphic" && candidate.value("kind")=="graphic") || (kind=="link" && candidate.value("kind")=="link")){item=candidate;break;}}QVERIFY2(!item.isEmpty(),qPrintable(QString::fromUtf8(QJsonDocument::fromVariant(model).toJson(QJsonDocument::Compact))));auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);if(kind=="link")QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"link")));QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));QVERIFY(QMetaObject::invokeMethod(window,"applyFit",Q_ARG(QVariant,"page"),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));if(paper){auto *map=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(map);QVERIFY(map->configurePaper(reader->pages().first().toMap().value("height").toDouble(),20,80));}QVERIFY(settleRasterWork(reader));auto *grip=visualItem(window->contentItem(),"contentResizeHandle"+QString::number(corner));auto *pointer=visualItem(window->contentItem(),"contentPointer0");QVERIFY(grip && pointer && grip->isVisible());const auto r=item.value("bounds").toMap();const double z=window->property("zoom").toDouble();const auto start=grip->mapToScene(grip->boundingRect().center()).toPoint();const bool left=corner%2==0,top=corner<2;const auto target=start+QPoint(left?-20:20,top?-15:15);const auto display=pointer->mapFromScene(QPointF(target))/z;const QPointF mapped(display.x(),display.y()-(paper?80:0));const auto pageSize=reader->pages().first().toMap();const QPointF end(qBound(0.0,mapped.x(),pageSize.value("width").toDouble()),qBound(0.0,mapped.y(),pageSize.value("height").toDouble()));const double x1=left?end.x():r.value("x").toDouble(),y1=top?end.y():r.value("y").toDouble(),x2=left?r.value("x").toDouble()+r.value("width").toDouble():end.x(),y2=top?r.value("y").toDouble()+r.value("height").toDouble():end.y();const QRectF expected(x1,y1,x2-x1,y2-y1);auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");QVERIFY(drag);const auto snapshots=qEnvironmentVariable("LYRA_READER_CONTENT_GEOMETRY_SNAPSHOTS");if(!snapshots.isEmpty() && corner==0 && !paper){QVERIFY(QDir().mkpath(snapshots));QVERIFY(window->grabWindow().save(snapshots+"/"+kind+"-handles.png"));}const auto requests=drag->requests(),rasters=reader->completedRasters();QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,start);auto *handles=visualItem(window->contentItem(),"contentResizeHandles0");QVERIFY(handles);const int pressedCorner=handles->property("corner").toInt();if(pressedCorner!=corner){QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,start);QCOMPARE(pressedCorner,corner);}QTest::mouseMove(window,target,20);QTest::qWait(40);QCOMPARE(reader->completedRasters(),rasters);QCOMPARE(drag->requests(),requests);QVERIFY(!reader->hasUnsavedChanges());QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,target);QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && reader->hasUnsavedChanges(),15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        const bool reflow=kind=="text" && item.value("can_edit_text").toBool();
        const auto textLayout=[](ReaderController *source){QVariantList result;for(const auto &v:source->data().value("content_objects").toMap().value("items").toList()){const auto entry=v.toMap();if(entry.value("kind")=="text"){QVariantMap run;for(const auto &key:QStringList{"bounds","baseline","text","size","colour"})run.insert(key,entry.value(key));result.append(run);}}return result;};
        QVariantList expectedTextLayout;
        if(reflow) {
            // A reflow frame differs from glyph ink bounds. Use the public typed
            // writer as the layout oracle, independently of the Qt command adapter.
            const auto oraclePath=scratch.filePath("typed-text-oracle.pdf");QSaveFile oracleFile(oraclePath);QVERIFY(oracleFile.open(QIODevice::WriteOnly));const auto bytes=original+"\n% independent-geometry-oracle\n";QCOMPARE(oracleFile.write(bytes),bytes.size());QVERIFY(oracleFile.commit());
            ReaderController oracle;oracle.openFile(QUrl::fromLocalFile(oraclePath));QTRY_VERIFY(!oracle.loading() && oracle.pageCount()==1 && !oracle.pendingCommands());oracle.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(oracle.pendingCommands(),0,10000);const auto oracleModel=oracle.data().value("content_objects").toMap();
            QVariantMap target;for(const auto &v:oracleModel.value("items").toList())if(v.toMap().value("text")==item.value("text")){target=v.toMap();break;}QVERIFY(!target.isEmpty());
            const QVariantMap bounds{{"x",expected.x()},{"y",expected.y()},{"width",expected.width()},{"height",expected.height()}};
            oracle.submit("content_stage",{{"page",0},{"command",QVariantMap{{"ReplaceText",QVariantMap{{"revision",oracleModel.value("revision")},{"target",target.value("id")},{"text",target.value("text")},{"bounds",bounds},{"font","Original"},{"size",target.value("size")},{"colour",target.value("colour")},{"alignment",0}}}}}});QTRY_COMPARE_WITH_TIMEOUT(oracle.pendingCommands(),0,15000);QVERIFY2(oracle.error().isEmpty(),qPrintable(oracle.error()));oracle.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(oracle.pendingCommands(),0,10000);expectedTextLayout=textLayout(&oracle);QVERIFY(!expectedTextLayout.isEmpty());
        }
        const auto find=[&](ReaderController *source){QVariantMap found;for(const auto &v:source->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("id")==item.value("id")){found=v.toMap();break;}return found;};const auto matches=[&](const QVariantMap &value,const QRectF &box){const auto b=value.value("bounds").toMap();return qAbs(b.value("x").toDouble()-box.x())<.1 && qAbs(b.value("y").toDouble()-box.y())<.1 && qAbs(b.value("width").toDouble()-box.width())<.1 && qAbs(b.value("height").toDouble()-box.height())<.1;};reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);if(reflow)QCOMPARE(textLayout(reader),expectedTextLayout);else QVERIFY2(matches(find(reader),expected),qPrintable(QString::fromUtf8(QJsonDocument::fromVariant(find(reader)).toJson(QJsonDocument::Compact))));if(kind=="link"){QCOMPARE(find(reader).value("link_uri"),item.value("link_uri"));QCOMPARE(find(reader).value("link_page"),item.value("link_page"));}QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);file.close();const auto snapshot=qEnvironmentVariable("LYRA_READER_CORNER_SNAPSHOT");if(!snapshot.isEmpty() && kind=="image" && corner==3)QVERIFY(window->grabWindow().save(snapshot));QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->hasUnsavedChanges(),15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(!reopened.loading() && reopened.pageCount()==(kind=="graphic"?2:1) && !reopened.pendingCommands());reopened.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);if(reflow)QCOMPARE(textLayout(&reopened),expectedTextLayout);else QVERIFY(matches(find(&reopened),expected));if(kind=="link"){QCOMPARE(find(&reopened).value("link_uri"),item.value("link_uri"));QCOMPARE(find(&reopened).value("link_page"),item.value("link_page"));}
    }
    void contentCornerCancelRejectsLateReleases_data() {
        QTest::addColumn<QString>("action");for(const auto &name:QStringList{"escape","zoom","scroll","mode","tab","reopen","gap","paper-change","minimum","link-tool","link-escape"})QTest::newRow(qPrintable(name))<<name;
    }
    void contentCornerCancelRejectsLateReleases() {
        QFETCH(QString,action);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("cancel-resize.pdf");const bool link=action.startsWith("link-");QVERIFY(QFile::copy(root+"/tests/fixtures/"+(link?QString("link-borders.pdf"):QString("text-page.pdf")),path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(!reader->loading() && reader->pageCount()==1 && !reader->pendingCommands());QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap title;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if((link && v.toMap().value("kind")=="link") || (!link && v.toMap().value("text").toString().contains("LyraReader fixture"))){title=v.toMap();break;}QVERIFY(!title.isEmpty());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);if(link)QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"link")));QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,title),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));auto *page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);if(action=="gap" || action=="paper-change")QVERIFY(page->configurePaper(reader->pages().first().toMap().value("height").toDouble(),action=="gap"?160:20,100));auto *grip=visualItem(window->contentItem(),"contentResizeHandle0");QVERIFY(grip && grip->isVisible());const auto start=grip->mapToScene(grip->boundingRect().center()).toPoint();QPoint end=start-QPoint(20,15);QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,start);QTest::mouseMove(window,end,20);const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};QVERIFY(!value(editor->property("gesture")).toMap().isEmpty());
        if(action=="escape" || action=="link-escape")QTest::keyClick(window,Qt::Key_Escape);
        else if(action=="link-tool")QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"link")));
        else if(action=="zoom")QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,.8),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        else if(action=="scroll"){auto *list=window->findChild<QObject *>("pageList");QVERIFY(list);list->setProperty("contentY",list->property("contentY").toDouble()+10);}
        else if(action=="mode")QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"annotate"),Q_ARG(QVariant,false)));
        else if(action=="tab")view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));
        else if(action=="reopen")reader->openFile(QUrl::fromLocalFile(path));
        else if(action=="paper-change")QVERIFY(page->configurePaper(reader->pages().first().toMap().value("height").toDouble(),20,20));
        else if(action=="gap")end=page->mapToScene(QPointF(100,210)*window->property("zoom").toDouble()).toPoint();
        else {const auto b=title.value("bounds").toMap();end=page->mapToScene(QPointF(b.value("x").toDouble()+b.value("width").toDouble()+50,b.value("y").toDouble()+b.value("height").toDouble()+50)*window->property("zoom").toDouble()).toPoint();QTest::mouseMove(window,end,20);const auto patch=value(editor->property("gesture")).toMap();const double minimum=2/window->property("zoom").toDouble();QVERIFY(qAbs(patch.value("width").toDouble()-minimum)<.001);QVERIFY(qAbs(patch.value("height").toDouble()-minimum)<.001);QTest::keyClick(window,Qt::Key_Escape);}
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,end);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTest::qWait(80);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(!reader->hasEditDrafts());QVERIFY(value(editor->property("gesture")).toMap().isEmpty());
    }
    void contentGuideCacheRejectsDenseTargetsAndClearsOnNavigation() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("guide-cache.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));
        const auto model=reader->data().value("content_objects").toMap();QVariantMap moving;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){moving=v.toMap();break;}QVERIFY(!moving.isEmpty());
        auto *editor=window->findChild<QObject *>("contentEditing");auto *guides=visualItem(window->contentItem(),"contentAlignmentGuides0");QVERIFY(editor && guides);QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,moving),Q_ARG(QVariant,0)));
        QVariantList dense;for(int i=0;i<4097;++i)dense.append(QVariantMap{{"id",QString::number(i)},{"bounds",QVariantMap{{"x",40},{"y",40},{"width",20},{"height",20}}}});
        QVariant prepared;QVERIFY(QMetaObject::invokeMethod(guides,"prepare",Q_RETURN_ARG(QVariant,prepared),Q_ARG(QVariant,dense)));QVERIFY(!prepared.toBool());QVERIFY(!guides->property("active").toBool());QVERIFY(window->property("operationStatus").toString().contains("dense"));QVERIFY(!reader->hasUnsavedChanges());
        QVERIFY(QMetaObject::invokeMethod(guides,"prepare",Q_RETURN_ARG(QVariant,prepared),Q_ARG(QVariant,model.value("items"))));QVERIFY(prepared.toBool());QVERIFY(guides->property("active").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,.8),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTRY_VERIFY(!guides->property("active").toBool());
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};QVERIFY(value(guides->property("xTargets")).toList().isEmpty());QVERIFY(value(guides->property("yTargets")).toList().isEmpty());
        QVERIFY(!reader->hasUnsavedChanges());
    }
    void contentObjectMoveRejectsStaleGesturesBeforeLateRelease_data() {
        QTest::addColumn<bool>("initialPaper");QTest::addColumn<QString>("action");QTest::newRow("existing-paper")<<true<<QString("paper");QTest::newRow("paper-inserted-during-drag")<<false<<QString("paper");
        for(const auto &action:QStringList{"escape","zoom","scroll","mode","tab","reopen"})QTest::newRow(qPrintable(action))<<false<<action;
    }
    void contentObjectMoveRejectsStaleGesturesBeforeLateRelease() {
        QFETCH(bool,initialPaper);QFETCH(QString,action);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("late-paper-drag.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));
        const auto model=reader->data().value("content_objects").toMap();QVariantMap moving;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){moving=v.toMap();break;}QVERIFY(!moving.isEmpty());
        auto *editor=window->findChild<QObject *>("contentEditing");auto *page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));auto *pointer=visualItem(window->contentItem(),"contentPointer0");auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");QVERIFY(editor && page && pointer && drag);
        QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,moving),Q_ARG(QVariant,0)));const double height=reader->pages().first().toMap().value("height").toDouble();if(initialPaper)QVERIFY(page->configurePaper(height,20,80));
        const auto b=moving.value("bounds").toMap();const double zoom=window->property("zoom").toDouble();const QPointF centre(b.value("x").toDouble()+b.value("width").toDouble()/2,b.value("y").toDouble()+b.value("height").toDouble()/2+(initialPaper?80:0));const auto start=pointer->mapToScene(centre*zoom).toPoint(),end=start+QPoint(35,40);
        QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,start);QTest::mouseMove(window,end,30);QTRY_VERIFY(drag->active());
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};QVERIFY(!value(editor->property("gesture")).toMap().isEmpty());
        if(action=="paper")QVERIFY(page->configurePaper(height,20,40));
        else if(action=="escape")QTest::keyClick(window,Qt::Key_Escape);
        else if(action=="zoom")QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,.8),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        else if(action=="scroll"){auto *list=window->findChild<QObject *>("pageList");list->setProperty("contentY",list->property("contentY").toDouble()+10);}
        else if(action=="mode")QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"annotate"),Q_ARG(QVariant,false)));
        else if(action=="tab")view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));
        else reader->openFile(QUrl::fromLocalFile(path));
        QTRY_VERIFY(value(editor->property("gesture")).toMap().isEmpty());QTRY_VERIFY(!drag->active());
        QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,end);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!reader->loading());QTest::qWait(80);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(!reader->hasEditDrafts());QVERIFY(window->findChild<QObject *>("pageList")->property("interactive").toBool());
    }
    void contentDragAlignmentGuidesSnapAndKeepOneSharedUndo_data() {
        QTest::addColumn<double>("zoom");QTest::addColumn<bool>("freeMove");QTest::addColumn<bool>("outside");QTest::addColumn<int>("rotation");QTest::addColumn<bool>("paper");
        QTest::newRow("snap-80")<<.8<<false<<false<<0<<false;
        QTest::newRow("snap-125")<<1.25<<false<<false<<0<<false;
        QTest::newRow("shift-free")<<1.0<<true<<false<<0<<false;
        QTest::newRow("shift-free-125")<<1.25<<true<<false<<0<<false;
        QTest::newRow("outside-four-pixels-125")<<1.25<<false<<true<<0<<false;
        QTest::newRow("outside-four-pixels")<<1.0<<false<<true<<0<<false;
        for(int r=1;r<4;++r)QTest::newRow(qPrintable(QString("rotation-%1").arg(r*90)))<<1.0<<false<<false<<r<<false;
        QTest::newRow("paper-gap")<<1.0<<false<<false<<0<<true;
    }
    void contentDragAlignmentGuidesSnapAndKeepOneSharedUndo() {
        QFETCH(double,zoom);QFETCH(bool,freeMove);QFETCH(bool,outside);QFETCH(int,rotation);QFETCH(bool,paper);
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.filePath("alignment.pdf");
        {QPdfWriter pdf(path);pdf.setResolution(72);pdf.setPageSize(QPageSize(QSizeF(500,600),QPageSize::Point));pdf.setPageMargins(QMarginsF(0,0,0,0));QPainter p(&pdf);QVERIFY(p.isActive());p.setFont(QFont("DejaVu Sans",16));p.drawText(QPointF(80,150),"Move 111");p.drawText(QPointF(300,180),"Move 222");p.drawText(QPointF(80,360),"Move 333");QVERIFY(p.end());}
        QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->resize(1100,900);if(qEnvironmentVariableIsSet("LYRA_READER_DRAG_DARK_NARROW")){window->setProperty("appearance","dark");window->setProperty("paperAppearance","night");window->resize(900,850);}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());
        if(rotation){reader->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",rotation}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));}
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,zoom),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(settleReaderViewport(window));
        const auto model=reader->data().value("content_objects").toMap();QVariantMap moving,target,targetY;
        for(const auto &v:model.value("items").toList()){const auto item=v.toMap();if(item.value("text").toString().contains("1"))moving=item;if(item.value("text").toString().contains("2"))target=item;if(item.value("text").toString().contains("3"))targetY=item;}
        QVERIFY2(!moving.isEmpty() && !target.isEmpty() && !targetY.isEmpty(),qPrintable(QString::fromUtf8(QJsonDocument::fromVariant(model).toJson(QJsonDocument::Compact))));
        const auto rect=[](const QVariantMap &item){const auto b=item.value("bounds").toMap();return QRectF(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble());};
        const auto source=rect(moving);const QRectF destination(rect(target).x(),rect(targetY).y(),rect(target).width(),rect(targetY).height());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);
        QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,moving),Q_ARG(QVariant,0)));
        auto *pointer=visualItem(window->contentItem(),"contentPointer0");auto *guides=visualItem(window->contentItem(),"contentAlignmentGuides0");auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");QVERIFY(pointer && guides && drag);
        const auto value=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>()?v.value<QJSValue>().toVariant():v;};
        auto *page=qobject_cast<PageItem *>(visualItem(window->contentItem(),"pdfPage0"));QVERIFY(page);if(paper)QVERIFY(page->configurePaper(600,20,80));
        if(zoom==1.25)window->findChild<QObject *>("pageList")->setProperty("contentY",1.25);
        QVERIFY(settleReaderViewport(window));
        const QPointF paperOffset(0,paper?80:0);
        const auto start=pointer->mapToScene((source.center()+paperOffset)*zoom).toPoint();const double near=outside?25:2;
        const auto end=pointer->mapToScene((source.center()+destination.topLeft()-source.topLeft()+paperOffset)*zoom+QPointF(near,near)).toPoint();
        const auto modifiers=freeMove?Qt::ShiftModifier:Qt::NoModifier;
        QTest::mousePress(window,Qt::LeftButton,modifiers,start);QTest::mouseMove(window,end,30);
        QVariant gestureCurrent;QMetaObject::invokeMethod(pointer,"currentGesture",Q_RETURN_ARG(QVariant,gestureCurrent));
        qInfo()<<"Alignment input"<<window->size()<<start<<end<<"zoom"<<window->property("zoom")<<"current"<<gestureCurrent<<"pressed"<<pointer->property("pressed")<<"began"<<pointer->property("began")<<"dragging"<<pointer->property("dragging")<<"gesture"<<value(editor->property("gesture"))<<"requests"<<drag->requests()<<"error"<<drag->error()<<"viewport"<<pointer->property("pressViewport")<<"scroll"<<pointer->property("pressScroll")<<"nowScroll"<<window->findChild<QObject *>("pageList")->property("contentY")<<"paper"<<pointer->property("pressPaperRevision")<<"revision"<<pointer->property("pressRevision")<<model.value("revision");
        QVERIFY(QRect(QPoint(0,0),window->size()).contains(start) && QRect(QPoint(0,0),window->size()).contains(end));
        QVERIFY2(drag->requests()>0,"A settled object press must survive the Flickable press adjustment");
        QVERIFY(!window->findChild<QObject *>("pageList")->property("interactive").toBool());
        QTRY_COMPARE_WITH_TIMEOUT(drag->status(),1,15000);QCOMPARE(drag->requests(),qulonglong(1));
        const auto patch=value(editor->property("gesture")).toMap();QVERIFY(!patch.isEmpty());
        const QPointF proposed=source.topLeft()+QPointF(end-start)/zoom,actual(patch.value("x").toDouble(),patch.value("y").toDouble());
        if(freeMove || outside)QVERIFY2(QLineF(actual,proposed).length()<.01,"Shift and out-of-range drags must remain free");
        else {
            double dx=1e9,dy=1e9;
            for(double a:{actual.x(),actual.x()+source.width()/2,actual.x()+source.width()})for(double b:{destination.left(),destination.center().x(),destination.right()})dx=qMin(dx,qAbs(a-b));
            for(double a:{actual.y(),actual.y()+source.height()/2,actual.y()+source.height()})for(double b:{destination.top(),destination.center().y(),destination.bottom()})dy=qMin(dy,qAbs(a-b));
            QVERIFY2(dx<.00001 && dy<.00001,"One vertical and horizontal object edge must align exactly");QVERIFY(qAbs(actual.x()-proposed.x())*zoom<4 && qAbs(actual.y()-proposed.y())*zoom<4);
        }
        const auto expected=actual;
        QCOMPARE(guides->property("hasGuides").toBool(),!freeMove && !outside);
        if(paper){QVariant pieces;QVERIFY(QMetaObject::invokeMethod(guides,"verticalSegments",Q_RETURN_ARG(QVariant,pieces)));const auto list=value(pieces).toList();QVERIFY(list.size()>=2);for(const auto &v:list){const auto segment=v.toMap();const double top=segment.value("y").toDouble(),bottom=top+segment.value("height").toDouble();QVERIFY(bottom<=20*zoom+.001 || top>=100*zoom-.001);}}
        const auto snapshot=qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");if(!snapshot.isEmpty() && !freeMove && !outside){QTest::qWait(80);QVERIFY(window->grabWindow().save(snapshot+"/lyrareader-content-guides-"+QTest::currentDataTag()+"-"+QGuiApplication::platformName()+"-"+QString::number(int(window->rendererInterface()->graphicsApi()))+".png"));}
        for(int i=0;i<8;++i)QTest::mouseMove(window,end,10);QCOMPARE(drag->requests(),qulonglong(1));
        QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);file.close();
        QTest::mouseRelease(window,Qt::LeftButton,modifiers,end);QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && reader->hasUnsavedChanges(),15000);
        QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!guides->property("active").toBool());QVERIFY(window->findChild<QObject *>("pageList")->property("interactive").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->data().value("content_objects").toMap().value("revision"),model.value("revision"));
        QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->hasUnsavedChanges(),15000);
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(!reopened.loading() && !reopened.pendingCommands());reopened.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);bool found=false;
        for(const auto &v:reopened.data().value("content_objects").toMap().value("items").toList()){const auto item=v.toMap();if(item.value("text").toString().contains("1")){QVERIFY(QLineF(rect(item).topLeft(),expected).length()<.1);found=true;}}QVERIFY2(found,qPrintable(QString::fromUtf8(QJsonDocument::fromVariant(reopened.data().value("content_objects")).toJson(QJsonDocument::Compact))));
    }

    void objectDragRendersPixelsOnceAndKeepsTheSharedTransform() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/drag.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->setProperty("paperAppearance","original");window->setProperty("appearance",qEnvironmentVariableIsSet("LYRA_READER_DRAG_DARK_NARROW") ? "dark" : "light");if(qEnvironmentVariableIsSet("LYRA_READER_DRAG_DARK_NARROW"))window->resize(700,600);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(settleReaderViewport(window));const auto model=reader->data().value("content_objects").toMap();QVariantMap title;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,title),Q_ARG(QVariant,0)));auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");auto *canvas=window->findChild<QQuickItem *>("documentCanvas");QVERIFY(drag && canvas);QCOMPARE(drag->parent(),canvas);
        auto *pointer=visualItem(window->contentItem(),"contentPointer0");QVERIFY(pointer);const auto b=title.value("bounds").toMap();const QRectF bounds(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble());const double viewZoom=window->property("zoom").toDouble();const auto start=pointer->mapToScene(bounds.center()*viewZoom).toPoint();const QPoint delta(0,qRound(300*viewZoom));const QPointF localDelta=QPointF(delta)/viewZoom;QTest::mousePress(window,Qt::LeftButton,Qt::ShiftModifier,start);QTest::mouseMove(window,start+delta,30);QVariant current;QMetaObject::invokeMethod(pointer,"currentGesture",Q_RETURN_ARG(QVariant,current));qInfo()<<"Drag input diagnostics"<<QVariantMap{{"gestureCurrent",current},{"began",pointer->property("began")},{"pressed",pointer->property("pressed")},{"dragging",pointer->property("dragging")},{"pressZoom",pointer->property("pressZoom")},{"zoom",window->property("zoom")},{"pressScroll",pointer->property("pressScroll")},{"pressViewport",pointer->property("pressViewport")},{"active",drag->active()},{"requests",drag->requests()},{"status",drag->status()},{"error",drag->error()}};QTRY_COMPARE_WITH_TIMEOUT(drag->status(),1,15000);QVERIFY(drag->active());QVERIFY(drag->residentBytes()>0 && drag->residentBytes()<=RenderBudget::maximumJobBytes);const auto requests=drag->requests();QCOMPARE(requests,qulonglong(1));QVERIFY(QLineF(drag->offset(),localDelta).length()<1.0/viewZoom);QVERIFY(!window->property("editInspectorVisible").toBool());
        const auto ink=[&](const QRectF &local){const auto image=window->grabWindow();if(image.isNull())return -1;const auto at=pointer->mapRectToScene(QRectF(local.topLeft()*viewZoom,local.size()*viewZoom));const double scale=double(image.width())/window->width();const QRect pixels(qFloor(at.x()*scale),qFloor(at.y()*scale),qCeil(at.width()*scale),qCeil(at.height()*scale));int n=0;for(int y=qMax(0,pixels.top());y<=qMin(image.height()-1,pixels.bottom());++y)for(int x=qMax(0,pixels.left());x<=qMin(image.width()-1,pixels.right());++x){const auto c=image.pixelColor(x,y);if(c.red()<90 && c.green()<90 && c.blue()<90)++n;}return n;};
        QTRY_VERIFY_WITH_TIMEOUT(ink(bounds.adjusted(1,1,-1,-1))<5,10000);QTRY_VERIFY_WITH_TIMEOUT(ink(bounds.translated(localDelta))>40,10000);const auto shot=window->grabWindow();const double pixelScale=double(shot.width())/window->width()*viewZoom;QVERIFY2(ink(bounds.translated(localDelta))<bounds.width()*bounds.height()*pixelScale*pixelScale*.8,"Transparent object pixels must not become a solid black rectangle");
        const auto snapshot=qEnvironmentVariable("LYRA_READER_DRAG_SNAPSHOT");if(!snapshot.isEmpty())QVERIFY(window->grabWindow().save(snapshot));
        for(int i=1;i<=12;++i)QTest::mouseMove(window,start+delta+QPoint(i,0),10);QVERIFY2(pointer->property("pressed").toBool(),"The page Flickable must not steal an active object gesture");QCOMPARE(drag->requests(),requests);QMetaObject::invokeMethod(pointer,"currentGesture",Q_RETURN_ARG(QVariant,current));qInfo()<<"Drag release diagnostics"<<current<<"pressed"<<pointer->property("pressed")<<"scroll"<<window->findChild<QObject *>("pageList")->property("contentY")<<"active"<<drag->active();QTest::mouseRelease(window,Qt::LeftButton,Qt::ShiftModifier,start+delta+QPoint(12,0));qInfo()<<"Released drag"<<"active"<<drag->active()<<"pending"<<reader->pendingCommands()<<"error"<<reader->error();QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && reader->hasUnsavedChanges(),15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QTRY_VERIFY_WITH_TIMEOUT(!drag->active() && drag->residentBytes()==0,15000);
        reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap moved;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){moved=v.toMap();break;}QVERIFY(!moved.isEmpty());const auto mb=moved.value("bounds").toMap();QVERIFY(qAbs(mb.value("x").toDouble()-bounds.x()-12/viewZoom)<.1);QVERIFY(qAbs(mb.value("y").toDouble()-bounds.y()-localDelta.y())<.1);QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);file.close();
        QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->data().value("content_objects").toMap().value("revision"),model.value("revision"));
        QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->hasUnsavedChanges(),15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(!reopened.loading() && reopened.pageCount()==1 && !reopened.pendingCommands());reopened.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);bool saved=false;for(const auto &v:reopened.data().value("content_objects").toMap().value("items").toList()){const auto item=v.toMap();if(item.value("text").toString().contains("LyraReader fixture")){const auto r=item.value("bounds").toMap();QVERIFY(qAbs(r.value("x").toDouble()-mb.value("x").toDouble())<.1);QVERIFY(qAbs(r.value("y").toDouble()-mb.value("y").toDouble())<.1);saved=true;}}QVERIFY(saved);
    }
    void objectDragCancelsOnNavigationModeReaderAndLateResults_data() {
        QTest::addColumn<QString>("action");for(const auto &name:QStringList{"escape","zoom","scroll","resize","hide","mode","tab","reopen","close","late"})QTest::newRow(qPrintable(name))<<name;
    }
    void objectDragCancelsOnNavigationModeReaderAndLateResults() {
        QFETCH(QString,action);QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/cancel-drag.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto model=reader->data().value("content_objects").toMap();QVariantMap title;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");QVERIFY(drag);const auto b=title.value("bounds").toMap();drag->prepare(0,title.value("id").toString(),model.value("revision").toString(),QRectF(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble()));QVERIFY(drag->active());
        if(action!="late")QTRY_COMPARE_WITH_TIMEOUT(drag->status(),1,15000);
        if(action=="escape"){auto *pointer=visualItem(window->contentItem(),"contentPointer0");auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(pointer && editor);QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,title),Q_ARG(QVariant,0)));const auto start=pointer->mapToScene(QPointF(b.value("x").toDouble()+b.value("width").toDouble()/2,b.value("y").toDouble()+b.value("height").toDouble()/2)*window->property("zoom").toDouble()).toPoint();QTest::mousePress(window,Qt::LeftButton,Qt::NoModifier,start);QTest::mouseMove(window,start+QPoint(0,15),20);QTRY_VERIFY(drag->active());QTest::keyClick(window,Qt::Key_Escape);QTest::mouseMove(window,start+QPoint(0,25),20);QTest::mouseRelease(window,Qt::LeftButton,Qt::NoModifier,start+QPoint(0,25));}
        else if(action=="zoom")QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,.8),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        else if(action=="scroll"){auto *list=window->findChild<QObject *>("pageList");QVERIFY(list);list->setProperty("contentY",list->property("contentY").toDouble()+10);}
        else if(action=="resize")window->resize(window->width()-50,window->height()-30);
        else if(action=="hide")window->hide();
        else if(action=="mode")QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"annotate"),Q_ARG(QVariant,false)));
        else if(action=="tab")view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));
        else if(action=="reopen")reader->openFile(QUrl::fromLocalFile(path));
        else if(action=="close")window->close();
        else drag->cancel();
        QTRY_VERIFY_WITH_TIMEOUT(!drag->active() && drag->residentBytes()==0,10000);QTest::qWait(80);QVERIFY(!drag->active() && drag->residentBytes()==0);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);
    }
    void failedObjectMoveReleasesItsPreviewWithoutChangingThePdf() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/failed-drag.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto model=reader->data().value("content_objects").toMap();QVariantMap title;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");QVERIFY(drag);const auto b=title.value("bounds").toMap();drag->prepare(0,title.value("id").toString(),model.value("revision").toString(),QRectF(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble()));QTRY_COMPARE_WITH_TIMEOUT(drag->status(),1,15000);drag->hold(reader->submit("content_stage",{{"page",0},{"command",QVariantMap{{"Delete",QVariantMap{{"revision",model.value("revision")},{"target","missing-drag-target"}}}}}}));QTRY_VERIFY_WITH_TIMEOUT(!reader->pendingCommands() && !reader->error().isEmpty(),10000);QTRY_VERIFY(!drag->active() && drag->residentBytes()==0);QVERIFY(!reader->hasUnsavedChanges());
    }
    void objectDragPublishesBothTexturesOrKeepsTheOriginalPage() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/budget-drag.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;window->setProperty("paperAppearance","original");view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(!reader->loading() && reader->pageCount()==1 && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(settleReaderViewport(window));const auto model=reader->data().value("content_objects").toMap();QVariantMap title;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());const auto b=title.value("bounds").toMap();const QRectF bounds(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble());auto *drag=window->findChild<ContentDragItem *>("contentDragPreview");auto *pointer=visualItem(window->contentItem(),"contentPointer0");QVERIFY(drag && pointer);const auto ink=[&](const QRectF &r){const auto image=window->grabWindow();if(image.isNull())return -1;const auto z=window->property("zoom").toDouble();const auto at=pointer->mapRectToScene(QRectF(r.topLeft()*z,r.size()*z));const double dpr=double(image.width())/window->width();const QRect px(qFloor(at.x()*dpr),qFloor(at.y()*dpr),qCeil(at.width()*dpr),qCeil(at.height()*dpr));int count=0;for(int y=qMax(0,px.top());y<=qMin(image.height()-1,px.bottom());++y)for(int x=qMax(0,px.left());x<=qMin(image.width()-1,px.right());++x){const auto c=image.pixelColor(x,y);if(c.red()<90 && c.green()<90 && c.blue()<90)++count;}return count;};QTRY_VERIFY(ink(bounds)>40);
        const auto region=bounds.adjusted(-2,-2,2,2);const auto one=qint64(std::ceil(region.width()*drag->zoom()*window->devicePixelRatio()))*qint64(std::ceil(region.height()*drag->zoom()*window->devicePixelRatio()))*4;const auto before=RenderBudget::statistics();auto block=RenderBudget::reserve(RenderBudget::Kind::Texture,RenderBudget::textureLimit-before.value("textureBytes").toLongLong()-one);QVERIFY(block);drag->prepare(0,title.value("id").toString(),model.value("revision").toString(),bounds);drag->setOffset(QPointF(0,300));QTRY_COMPARE_WITH_TIMEOUT(drag->status(),1,15000);QTRY_VERIFY_WITH_TIMEOUT(RenderBudget::statistics().value("textureDenied").toLongLong()>before.value("textureDenied").toLongLong(),10000);QVERIFY(ink(bounds)>40);const auto requests=drag->requests();block.reset();QTRY_VERIFY_WITH_TIMEOUT(ink(bounds.adjusted(1,1,-1,-1))<5,10000);qInfo()<<"Drag texture diagnostics"<<QVariantMap{{"active",drag->active()},{"status",drag->status()},{"residentBytes",drag->residentBytes()},{"offset",drag->offset()},{"zoom",drag->zoom()},{"requests",drag->requests()},{"error",drag->error()},{"budget",RenderBudget::statistics()}};QTRY_VERIFY_WITH_TIMEOUT(ink(bounds.translated(0,300))>40,10000);QCOMPARE(drag->requests(),requests);drag->cancel();QTRY_COMPARE(drag->residentBytes(),qint64(0));QVERIFY(!reader->hasUnsavedChanges());
    }
    void objectDragBridgeKeepsRotatedWorkingRevisionsAfterUndo() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/working-drag.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));ReaderController reader;reader.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(!reader.loading() && reader.pageCount()==1 && !reader.pendingCommands());
        for(int turn=0;turn<4;++turn){if(turn){reader.submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",turn}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY2(reader.error().isEmpty(),qPrintable(reader.error()));}reader.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);const auto model=reader.data().value("content_objects").toMap();QVariantMap title;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());const auto b=title.value("bounds").toMap();const QRectF region(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble());auto source=reader.renderSource();QVERIFY(source);if(turn){reader.submit("page_undo");QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(!reader.hasUnsavedChanges());}QString error;const auto pair=source->dragPreview(0,title.value("id").toString(),model.value("revision").toString(),region,1.25,&error);QVERIFY2(error.isEmpty(),qPrintable(error));QVERIFY(!pair.background.isNull() && !pair.foreground.isNull());int ink=0;for(int y=0;y<pair.foreground.height();++y)for(int x=0;x<pair.foreground.width();++x)if(pair.foreground.pixelColor(x,y).alpha()>100)++ink;QVERIFY2(ink>20,qPrintable(QString("rotation %1 lost its object").arg(turn)));}
    }
    void objectDragBridgeUsesPinnedBytesAcrossAtomicReplacement() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/frozen-drag.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));ReaderController reader;reader.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(reader.pageCount()==1 && !reader.loading() && !reader.pendingCommands());reader.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);const auto model=reader.data().value("content_objects").toMap();QVariantMap title;for(const auto &v:model.value("items").toList())if(v.toMap().value("text").toString().contains("LyraReader fixture")){title=v.toMap();break;}QVERIFY(!title.isEmpty());const auto source=reader.renderSource();QVERIFY(source);const auto b=title.value("bounds").toMap();const QRectF box(b.value("x").toDouble(),b.value("y").toDouble(),b.value("width").toDouble(),b.value("height").toDouble());
        QFile replacement(root+"/tests/fixtures/form-text-pages.pdf");QVERIFY(replacement.open(QIODevice::ReadOnly));QSaveFile swap(path);QVERIFY(swap.open(QIODevice::WriteOnly));const auto bytes=replacement.readAll();QCOMPARE(swap.write(bytes),qint64(bytes.size()));QVERIFY(swap.commit());
        QString error;const auto pair=source->dragPreview(0,title.value("id").toString(),model.value("revision").toString(),box,2,&error);QVERIFY2(error.isEmpty(),qPrintable(error));QVERIFY(!pair.background.isNull() && !pair.foreground.isNull());QCOMPARE(pair.background.size(),pair.foreground.size());int opaque=0,transparent=0;for(int y=0;y<pair.foreground.height();++y)for(int x=0;x<pair.foreground.width();++x){const auto alpha=pair.foreground.pixelColor(x,y).alpha();if(alpha==0)++transparent;else++opaque;}QVERIFY(opaque>20 && transparent>20);
        const auto rejected=source->dragPreview(0,title.value("id").toString(),QString(64,'0'),box,2,&error);QVERIFY(rejected.background.isNull() && !error.isEmpty());
    }
    void selectedTextWaitsForACaretAndOnlySelectOffersHover() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/content-hover.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;if(qEnvironmentVariableIsSet("LYRA_READER_EDIT_PANELS_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(700,600);}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto snapshot=reader->data().value("content_objects").toMap();QVariantMap text;for(const auto &v:snapshot.value("items").toList()){const auto item=v.toMap();if(text.isEmpty() && item.value("kind")=="text" && item.value("can_edit_text").toBool())text=item;}QVERIFY(!text.isEmpty());
        auto *editor=window->findChild<QObject *>("contentEditing");auto *canvas=window->findChild<QQuickItem *>("documentCanvas");QVERIFY(editor && canvas);const double originalWidth=canvas->width();
        QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,text),Q_ARG(QVariant,0)));QVERIFY(!window->property("editInspectorVisible").toBool());QTest::qWait(40);QCOMPARE(canvas->width(),originalWidth);
        auto *pointer=visualItem(window->contentItem(),"contentPointer0"),*layer=visualItem(window->contentItem(),"contentPageLayer0"),*hover=visualItem(window->contentItem(),"contentHoverFrame0");QVERIFY(pointer && layer && hover);
        const auto map=[](const QVariant &v){return v.metaType()==QMetaType::fromType<QJSValue>() ? v.value<QJSValue>().toVariant().toMap() : v.toMap();};
        const auto bounds=text.value("bounds").toMap();const auto point=pointer->mapToScene(QPointF(bounds.value("x").toDouble()+bounds.value("width").toDouble()/2,bounds.value("y").toDouble()+bounds.value("height").toDouble()/2)*window->property("zoom").toDouble()).toPoint();
        editor->setProperty("selected",QVariant::fromValue(static_cast<QObject *>(nullptr)));QSignalSpy commands(reader,&ReaderController::commandFinished);QTest::mouseMove(window,point+QPoint(1,0),20);QTest::mouseMove(window,point,20);QTRY_COMPARE(map(layer->property("hovered")).value("id"),text.value("id"));QVERIFY(hover->isVisible());const auto snapshotPrefix=qEnvironmentVariable("LYRA_READER_EDIT_PANELS_SNAPSHOT");if(!snapshotPrefix.isEmpty())QVERIFY(window->grabWindow().save(snapshotPrefix+"-hover.png"));for(const auto &row:commands)QVERIFY(row[1].toString()!="content_objects" && row[1].toString()!="content_drag_preview");
        QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"image")));QVERIFY(!pointer->property("hoverEnabled").toBool());QVERIFY(map(layer->property("hovered")).isEmpty());QVERIFY(!hover->isVisible());QTest::mouseMove(window,point+QPoint(3,0),20);QVERIFY(map(layer->property("hovered")).isEmpty());
        QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"image")));QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,text),Q_ARG(QVariant,0)));pointer->forceActiveFocus();QTest::keyClick(window,Qt::Key_Return);QTRY_VERIFY(editor->property("inlineEditing").toBool());QTRY_VERIFY(window->property("editInspectorVisible").toBool());QVERIFY(reader->hasEditDrafts());if(!snapshotPrefix.isEmpty())QVERIFY(window->grabWindow().save(snapshotPrefix+"-caret.png"));
        // A preserved draft still owns its recovery controls after the inline caret leaves.
        editor->setProperty("inlineEditing",false);QVERIFY(window->property("editInspectorVisible").toBool());QVERIFY(QMetaObject::invokeMethod(editor,"discard"));QTRY_VERIFY(!reader->hasEditDrafts());
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"annotate"),Q_ARG(QVariant,false)));QVERIFY(!window->property("editInspectorVisible").toBool());QVERIFY(map(layer->property("hovered")).isEmpty());QVERIFY(!reader->hasUnsavedChanges());
        const auto next=scratch.path()+"/graphic.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/form-text-pages.pdf",next));view.workspace.openFile(QUrl::fromLocalFile(next));reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==2 && !reader->loading() && !reader->pendingCommands());QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVariantMap graphic;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("kind")=="graphic"){graphic=v.toMap();break;}QVERIFY(!graphic.isEmpty());QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,graphic),Q_ARG(QVariant,0)));QVERIFY(window->property("editInspectorVisible").toBool());auto *graphicHandle=visualItem(window->contentItem(),"contentResizeHandle0");QVERIFY(graphicHandle && graphicHandle->isVisible());QVERIFY(!reader->hasUnsavedChanges());
    }
    void textGeometryKeepsTheInspectorClosedUntilARecoverableFailure() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/content-move-error.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;if(qEnvironmentVariableIsSet("LYRA_READER_EDIT_PANELS_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(700,600);}view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVariantMap text;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("kind")=="text"){text=v.toMap();break;}QVERIFY(!text.isEmpty());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,text),Q_ARG(QVariant,0)));
        auto stale=text;stale["id"]="missing-object-for-recovery-check";auto bounds=text.value("bounds").toMap();bounds["x"]=bounds.value("x").toDouble()+8;QVERIFY(QMetaObject::invokeMethod(editor,"applyGeometry",Q_ARG(QVariant,stale),Q_ARG(QVariant,bounds)));QVERIFY(reader->hasEditDrafts());QVERIFY(!window->property("editInspectorVisible").toBool());
        QTRY_VERIFY_WITH_TIMEOUT(!reader->error().isEmpty() && !reader->pendingCommands(),10000);QVERIFY(window->property("editInspectorVisible").toBool());QVERIFY(reader->hasEditDrafts());QVERIFY(reader->editDrafts().value("content").toMap().contains("error"));QVERIFY(window->property("operationStatus").toString().contains("Your draft is preserved"));QVERIFY(QMetaObject::invokeMethod(editor,"discard"));reader->dismissError();QVERIFY(!reader->hasEditDrafts() && !reader->hasUnsavedChanges());QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);
    }
    void everyLyraRowExitClosesItsDrawerAndRetainsTheWorkspace() {
        NativeCorpus::Viewer view;QVERIFY(view.window);auto *window=view.window;if(qEnvironmentVariableIsSet("LYRA_READER_EDIT_PANELS_DARK_NARROW")){window->setProperty("appearance","dark");window->resize(700,600);}view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));auto *reader=view.workspace.activeReader();QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && !reader->pendingCommands());QVERIFY(settleReaderViewport(window));reader->setAiInput("question","Synthetic retained draft");reader->setAiInput("view","translation");
        for(const auto &row:QStringList{"","annotate","edit","fill","export"}) {
            QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"lyra"),Q_ARG(QVariant,false)));QVERIFY(QMetaObject::invokeMethod(window,"showAiPanelMode",Q_ARG(QVariant,true),Q_ARG(QVariant,"notes")));QVERIFY(window->property("aiPanelVisible").toBool());
            QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,row),Q_ARG(QVariant,false)));QVERIFY2(!window->property("aiPanelVisible").toBool(),qPrintable(row));QCOMPARE(window->property("aiPanelMode").toString(),QString("notes"));QCOMPARE(reader->aiState().value("input").toMap().value("question").toString(),QString("Synthetic retained draft"));QCOMPARE(reader->aiState().value("input").toMap().value("view").toString(),QString("translation"));
        }
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"lyra"),Q_ARG(QVariant,false)));QVERIFY(QMetaObject::invokeMethod(window,"showAiPanelMode",Q_ARG(QVariant,true),Q_ARG(QVariant,"notes")));QVERIFY(window->setProperty("secondaryRow",QString("export")));QVERIFY(!window->property("aiPanelVisible").toBool());QCOMPARE(window->property("aiPanelMode").toString(),QString("notes"));QVERIFY(!reader->hasEditDrafts() && !reader->hasUnsavedChanges());
    }
    void fiveSecondaryRowsAndNativeContentEditingUseTheSharedTransaction() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/content.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *rows=window->findChild<QQuickItem *>("secondaryTools");QVERIFY(rows);
        for(const auto &row:{"annotate","edit","fill","export","lyra"}) {
            QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,row),Q_ARG(QVariant,false)));QTRY_COMPARE(window->property("secondaryRow").toString(),QString(row));QTRY_VERIFY(rows->isVisible());QCOMPARE(rows->height(),46.0);
            int visible=0;for(const auto &name:{"annotationToolRow","editToolRow","fillSignToolRow","exportToolRow","lyraToolRow"}){auto *item=rows->findChild<QQuickItem *>(name);QVERIFY(item);if(item->isVisible())++visible;}QCOMPARE(visible,1);
            if(qEnvironmentVariableIsSet("LYRA_READER_QT_UI_CAPTURE")) {const auto directory=qEnvironmentVariable("LYRA_READER_QT_UI_CAPTURE");QVERIFY(QDir().mkpath(directory));QTest::qWait(80);const auto image=window->grabWindow();QVERIFY(!image.isNull());QVERIFY(image.save(directory+"/row-"+row+".png"));}
        }
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!window->property("editInspectorVisible").toBool());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);
        QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"text")));QTRY_VERIFY(window->property("editInspectorVisible").toBool());
        const auto snapshot=reader->data().value("content_objects").toMap();QVERIFY(!snapshot.value("revision").toString().isEmpty());QVariantMap item;for(const auto &v:snapshot.value("items").toList()){const auto value=v.toMap();if(value.value("kind")=="text" && value.value("can_edit_text").toBool()){item=value;break;}}QVERIFY(!item.isEmpty());
        QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
        auto *page=visualItem(window->contentItem(),"pdfPage0");const auto bounds=item.value("bounds").toMap();const auto zoom=window->property("zoom").toDouble();const auto point=page->mapToScene(QPointF((bounds.value("x").toDouble()+5)*zoom,(bounds.value("y").toDouble()+bounds.value("height").toDouble()/2)*zoom)).toPoint();
        QTest::mouseDClick(window,Qt::LeftButton,Qt::NoModifier,point);QTRY_VERIFY(editor->property("inlineEditing").toBool());auto *text=visualItem(window->contentItem(),"contentInlineText0");QVERIFY(text);QTRY_VERIFY(text->isVisible());QTRY_VERIFY(text->hasActiveFocus());if(qEnvironmentVariableIsSet("LYRA_READER_QT_UI_CAPTURE")){QTest::qWait(80);QVERIFY(window->grabWindow().save(qEnvironmentVariable("LYRA_READER_QT_UI_CAPTURE")+"/content-inline.png"));}QTest::keyClick(window,Qt::Key_A,Qt::ControlModifier);for(const auto ch:QByteArray("Linux edit"))QTest::keyClick(window,ch);QCOMPARE(text->property("text").toString(),QString("Linux edit"));QTest::keyClick(window,Qt::Key_Return,Qt::ControlModifier);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QTRY_VERIFY(!reader->hasEditDrafts());QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(reader->hasUnsavedChanges());reader->requestText(0);QTRY_VERIFY2_WITH_TIMEOUT(reader->textPages().value("0").toMap().value("text").toString().contains("Linux edit"),qPrintable(reader->textPages().value("0").toMap().value("text").toString()),10000);
        QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);file.close();QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->requestText(0);QTRY_VERIFY_WITH_TIMEOUT(!reader->textPages().value("0").toMap().value("text").toString().contains("Linux edit"),10000);
        QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);reopened.requestText(0);QTRY_VERIFY_WITH_TIMEOUT(reopened.textPages().value("0").toMap().value("text").toString().contains("Linux edit"),10000);
    }
    void exportRowProvidesEightCommandsAndFreezesTheChosenDocument() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/export-source.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/flatten.pdf",path));QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"export"),Q_ARG(QVariant,false)));
        QTRY_VERIFY(reader->data().contains("document_info") && reader->data().contains("forms"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *row=visualItem(view.window->contentItem(),"exportToolRow");QVERIFY(row);QCOMPARE(row->height(),46.0);
        const QStringList ids{"save","saveAs","annotated","flattened","filledForm","formValues","annotations","print"};
        for(int width:{1200,700}) {
            view.window->setWidth(width);QTest::qWait(80);double previous=-1;
            for(const auto &id:ids) {
                auto *button=visualItem(view.window->contentItem(),"exportCommand"+id);QVERIFY(button && button->isVisible());
                const auto frame=button->mapRectToItem(view.window->contentItem(),button->boundingRect());QVERIFY(frame.left()>previous);QVERIFY(frame.left()>=0 && frame.right()<=width+1);previous=frame.left();
                auto *accessible=QAccessible::queryAccessibleInterface(button);QVERIFY(accessible && !accessible->text(QAccessible::Name).isEmpty());
            }
            const auto capture=qEnvironmentVariable("LYRA_READER_EXPORT_SNAPSHOT");
            if(!capture.isEmpty())QVERIFY(view.window->grabWindow().save(capture+QString::number(width)+".png"));
        }
        auto *flatten=visualItem(view.window->contentItem(),"exportCommandflattened");QVERIFY(flatten && flatten->isEnabled());
        auto *notice=view.window->findChild<QObject *>("flattenExportNotice"),*save=view.window->findChild<QObject *>("documentSaveDialog");QVERIFY(notice && save);
        QVERIFY(QMetaObject::invokeMethod(flatten,"clicked"));QTRY_VERIFY(notice->property("visible").toBool());QVERIFY(QMetaObject::invokeMethod(notice,"reject"));QVERIFY(!save->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(flatten,"clicked"));QVERIFY(QMetaObject::invokeMethod(notice,"accept"));QTRY_VERIFY(save->property("visible").toBool());
        const auto copy=scratch.path()+"/flattened.pdf";QSignalSpy completed(reader,&ReaderController::commandFinished);
        QVERIFY(QMetaObject::invokeMethod(view.window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(copy))));QVERIFY(QMetaObject::invokeMethod(save,"reject"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QVariantMap report;for(const auto &event:completed)if(event.at(1).toString()=="save_flattened_copy")report=event.at(2).toMap();QCOMPARE(report.value("flattened_annotations").toInt(),6);QVERIFY(QFileInfo::exists(copy));QVERIFY(view.window->property("operationStatus").toString().contains("Original unchanged"));
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","textBox"},{"version",1},{"page",0},{"rect",QVariantMap{{"x",20},{"y",20},{"width",100},{"height",30}}},{"fontSize",14},{"color","#000000ff"},{"note","Frozen export before"}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto entry=reader->data().value("marks").toMap().value("annotations").toList().last().toMap();QVariant expected;
        QVERIFY(QMetaObject::invokeMethod(view.window,"annotationExport",Q_RETURN_ARG(QVariant,expected),Q_ARG(QVariant,"csv")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"performExportAction",Q_ARG(QVariant,"annotations")));QTRY_VERIFY(save->property("visible").toBool());QCOMPARE(save->property("nameFilters").toStringList().size(),2);
        reader->submit("mark_update",{{"id",entry.value("id")},{"patch",QVariantMap{{"note","Changed after preview"}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setAnnotationExportFormat",Q_ARG(QVariant,1)));const auto csv=scratch.path()+"/annotations.csv";
        QVERIFY(QMetaObject::invokeMethod(view.window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(csv))));QVERIFY(QMetaObject::invokeMethod(save,"reject"));QFile exported(csv);QVERIFY(exported.open(QIODevice::ReadOnly));QCOMPARE(exported.readAll(),expected.toString().toUtf8());
        QVERIFY(QMetaObject::invokeMethod(view.window,"chooseExport",Q_ARG(QVariant,"annotations")));QTRY_VERIFY(save->property("visible").toBool());
        reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && reader->pendingCommands()==0);const auto stale=scratch.path()+"/stale.pdf";
        QVERIFY(QMetaObject::invokeMethod(view.window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(stale))));QVERIFY(!QFileInfo::exists(stale));QVERIFY(QMetaObject::invokeMethod(save,"reject"));
        QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);source.close();
        view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/xfa-refusal.pdf"));auto *xfa=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(xfa->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(xfa->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"export"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(xfa->pendingCommands(),0,10000);
        for(const auto &id:{"save","saveAs","annotated","flattened","filledForm","formValues"})QVERIFY(!visualItem(view.window->contentItem(),QString("exportCommand")+id)->isEnabled());
        QVERIFY(visualItem(view.window->contentItem(),"exportCommandprint")->isEnabled());
    }
    void formValuesActionSavesWithVerifiedBackupAndKeepsTheReaderUsable() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/form-values.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/form-fields.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"export"),Q_ARG(QVariant,false)));QTRY_VERIFY(reader->data().contains("forms"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVariantMap field;for(const auto &v:reader->data().value("forms").toMap().value("fields").toList())if(v.toMap().value("kind")=="text" && v.toMap().value("editable").toBool()){field=v.toMap();break;}QVERIFY(!field.isEmpty());
        QVERIFY(QMetaObject::invokeMethod(view.window,"updateFormValue",Q_ARG(QVariant,field.value("id")),Q_ARG(QVariant,QVariantMap({{"text","Saved through unified form action"}}))));
        auto *button=visualItem(view.window->contentItem(),"exportCommandformValues");QVERIFY(button);QTRY_VERIFY(button->isEnabled());
        QVERIFY(QMetaObject::invokeMethod(button,"clicked"));auto *confirmation=view.window->findChild<QObject *>("originalReplaceConfirmation");QVERIFY(confirmation);QTRY_VERIFY(confirmation->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(confirmation,"accept"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
        QVERIFY(view.window->property("operationStatus").toString().contains("Verified backup"));
        reader->submit("forms");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        bool found=false;for(const auto &v:reader->data().value("forms").toMap().value("fields").toList())if(v.toMap().value("id")==field.value("id"))found=v.toMap().value("value")=="Saved through unified form action";QVERIFY(found);
        reader->submit("bookmark_create",{{"page",0},{"title","Cache identity remains usable"}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(reader->hasUnsavedChanges());
    }
    void formReplacementConfirmationRejectsAReopenedReader() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/forms-source.pdf",other=scratch.path()+"/other.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/form-fields.pdf",path));QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",other));
        QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();QFile next(other);QVERIFY(next.open(QIODevice::ReadOnly));const auto otherBytes=next.readAll();next.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"export"),Q_ARG(QVariant,false)));QTRY_VERIFY(reader->data().contains("forms"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVariantMap field;for(const auto &v:reader->data().value("forms").toMap().value("fields").toList())if(v.toMap().value("kind")=="text" && v.toMap().value("editable").toBool()){field=v.toMap();break;}QVERIFY(!field.isEmpty());
        QVERIFY(QMetaObject::invokeMethod(view.window,"updateFormValue",Q_ARG(QVariant,field.value("id")),Q_ARG(QVariant,QVariantMap({{"text","Reviewed form value"}}))));
        auto *button=visualItem(view.window->contentItem(),"exportCommandformValues");QVERIFY(button);QTRY_VERIFY(button->isEnabled());QVERIFY(QMetaObject::invokeMethod(button,"clicked"));
        auto *confirmation=view.window->findChild<QObject *>("originalReplaceConfirmation");QVERIFY(confirmation);QTRY_VERIFY(confirmation->property("visible").toBool());
        reader->openFile(QUrl::fromLocalFile(other));QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && reader->pendingCommands()==0);
        QVERIFY(QMetaObject::invokeMethod(confirmation,"accept"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(view.window->property("operationStatus").toString().contains("Review the replacement again"));
        QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);QVERIFY(next.open(QIODevice::ReadOnly));QCOMPARE(next.readAll(),otherBytes);
    }
    void longContentDraftsStayScrollableAndGeometryFieldsKeepTheirIdentity() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/content-long-draft.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        NativeCorpus::Viewer view;QVERIFY(view.window);
        view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *editor=view.window->findChild<QObject *>("contentEditing");QVERIFY(editor);
        const auto objects=reader->data().value("content_objects").toMap();QVariantMap item;
        for(const auto &v:objects.value("items").toList())if(v.toMap().value("can_edit_text").toBool()){item=v.toMap();break;}
        QVERIFY(!item.isEmpty());
        QVERIFY(QMetaObject::invokeMethod(editor,"editText",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));
        auto *text=visualItem(view.window->contentItem(),"contentInlineText0");QVERIFY(text);
        QTRY_VERIFY(text->isVisible() && text->hasActiveFocus());
        const auto oldHeight=text->height();
        const QString longText=QString("A visible multiline PDF title and preserved draft. ").repeated(80);
        QTest::keyClick(view.window,Qt::Key_A,Qt::ControlModifier);
        QInputMethodEvent input;input.setCommitString(longText);QCoreApplication::sendEvent(view.window,&input);
        QTRY_COMPARE(text->property("text").toString(),longText);
        auto *scroll=visualItem(view.window->contentItem(),"contentInlineScroll0");
        QVERIFY2(scroll,"Long actual-PDF drafts need a bounded native scrolling editor");
        QTRY_VERIFY(scroll->height()>oldHeight);
        QTRY_VERIFY(scroll->property("contentHeight").toDouble()>scroll->property("availableHeight").toDouble());
        const auto cursorVisible=[&]{const auto cursor=text->mapRectToItem(scroll,text->property("cursorRectangle").toRectF());return cursor.top()>=-1 && cursor.bottom()<=scroll->height()+1;};
        QTRY_VERIFY2(cursorVisible(),"Typing at the end of a long draft must scroll the native caret into view");
        const auto frame=scroll->mapRectToItem(view.window->contentItem(),scroll->boundingRect());
        QVERIFY(frame.bottom()<=view.window->height()+1);
        const auto savedDraft=reader->editDrafts().value("content").toMap();
        QCOMPARE(savedDraft.value("command").toMap().value("ReplaceText").toMap().value("text").toString(),longText);
        QCOMPARE(savedDraft.value("command").toMap().value("ReplaceText").toMap().value("bounds"),item.value("bounds"));
        const auto evidence=qEnvironmentVariable("LYRA_READER_CONTENT_LONG_SNAPSHOT");
        if(!evidence.isEmpty()){QTest::qWait(80);QVERIFY(view.window->grabWindow().save(evidence));}
        QPointer<QQuickItem> retained=text;
        QVERIFY(QMetaObject::invokeMethod(text,"selectAll"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"setPageLayout",Q_ARG(QVariant,"Facing")));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY2(retained && retained==visualItem(view.window->contentItem(),"contentInlineText0"),"Page layout replacement must retain the native content editor");
        QTRY_VERIFY(retained->hasActiveFocus());
        QCOMPARE(retained->property("selectedText").toString(),longText);
        QVERIFY(QMetaObject::invokeMethod(editor,"commitDraft"));
        QVERIFY(reader->pendingCommands()>0);
        QVERIFY(QMetaObject::invokeMethod(editor,"discard"));
        QVERIFY(reader->hasEditDrafts());
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);
        QVERIFY2(!reader->error().isEmpty(),"The shared writer must reject a title that cannot fit its unchanged PDF bounds");
        QCOMPARE(reader->editDrafts().value("content").toMap().value("command").toMap().value("ReplaceText").toMap().value("text").toString(),longText);
        QTest::keyClick(view.window,Qt::Key_Escape);
        QTRY_VERIFY(!reader->hasEditDrafts());QTRY_VERIFY(!text->isVisible());
        QVERIFY(!text->hasActiveFocus());QVERIFY(!reader->hasUnsavedChanges());
        reader->dismissError();
        // Cancel returns to implicit selection, whose text inspector is intentionally
        // closed. An explicitly armed Text tool still offers object geometry controls.
        QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"text")));QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));QTRY_VERIFY(view.window->property("editInspectorVisible").toBool());
        const auto oldLocale=QLocale();QLocale::setDefault(QLocale(QLocale::German,QLocale::Germany));
        const auto restoreLocale=qScopeGuard([oldLocale]{QLocale::setDefault(oldLocale);});
        auto *x=visualItem(view.window->contentItem(),"contentGeometryX"),*y=visualItem(view.window->contentItem(),"contentGeometryY");
        auto *width=visualItem(view.window->contentItem(),"contentGeometryWidth"),*height=visualItem(view.window->contentItem(),"contentGeometryHeight");
        auto *apply=visualItem(view.window->contentItem(),"applyContentGeometry");QVERIFY(x && y && width && height && apply);
        for(const auto &name:{"contentGeometryXLabel","contentGeometryYLabel","contentGeometryWidthLabel","contentGeometryHeightLabel"}) {
            auto *label=visualItem(view.window->contentItem(),name);QVERIFY(label && label->isVisible());QVERIFY(!label->property("text").toString().isEmpty());
        }
        x->setProperty("text","1,234");QTRY_VERIFY(!apply->isEnabled());
        x->setProperty("text","nan");QTRY_VERIFY(!apply->isEnabled());
        const auto oldBounds=item.value("bounds").toMap();const auto newX=oldBounds.value("x").toDouble()+3.25;
        x->setProperty("text",QString::number(newX,'g',16));width->setProperty("text","0");QTRY_VERIFY(!apply->isEnabled());
        width->setProperty("text",QString::number(oldBounds.value("width").toDouble(),'g',16));QTRY_VERIFY(apply->isEnabled());
        QVERIFY(QMetaObject::invokeMethod(apply,"clicked"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);
        QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasEditDrafts());QVERIFY(reader->hasUnsavedChanges());
        const auto changed=reader->data().value("content_objects").toMap();QVERIFY(changed.value("revision")!=objects.value("revision"));
        bool moved=false;for(const auto &v:changed.value("items").toList())if(v.toMap().value("text")==item.value("text"))moved=qAbs(v.toMap().value("bounds").toMap().value("x").toDouble()-newX)<.1;
        QVERIFY(moved);QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);source.close();
        QVERIFY(QMetaObject::invokeMethod(view.window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(!reader->hasUnsavedChanges());
    }
    void percentageImageCropUsesTheSharedRevisionUndoAndSave() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/crop.pdf",png=scratch.path()+"/pixels.png";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QImage pixels(4,2,QImage::Format_RGBA8888);pixels.fill(Qt::blue);for(int y=0;y<2;++y)for(int x=0;x<2;++x)pixels.setPixelColor(x,y,Qt::red);QVERIFY(pixels.save(png));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto original=file.readAll();file.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto revision=reader->data().value("content_objects").toMap().value("revision");reader->submit("content_stage",{{"page",0},{"command",QVariantMap{{"InsertImage",QVariantMap{{"revision",revision},{"bounds",QVariantMap{{"x",72},{"y",500},{"width",100},{"height",50}}},{"image_path",png}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto imageFrom=[](const QVariantMap &snapshot){for(const auto &v:snapshot.value("items").toList())if(v.toMap().value("kind")=="image")return v.toMap();return QVariantMap{};};const auto before=reader->data().value("content_objects").toMap();const auto image=imageFrom(before);QVERIFY(!image.isEmpty());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,image),Q_ARG(QVariant,0)));QTRY_VERIFY(window->property("editInspectorVisible").toBool());auto *toggle=visualItem(window->contentItem(),"toggleContentCrop");auto *apply=visualItem(window->contentItem(),"applyContentCrop");auto *left=visualItem(window->contentItem(),"contentCropLeft");auto *right=visualItem(window->contentItem(),"contentCropRight");QVERIFY(toggle && apply && left && right);QTRY_VERIFY(toggle->isVisible());auto *thumbnail=qobject_cast<CropItem *>(visualItem(window->contentItem(),"contentImagePreview"));QVERIFY(thumbnail);QTRY_COMPARE_WITH_TIMEOUT(thumbnail->status(),1,15000);QCOMPARE(thumbnail->pixelSize(),QSize(4,2));const auto previewUrl=thumbnail->source();QVERIFY(previewUrl.toString().contains("kind=bitmap"));QString previewError;const auto onePixel=NativeImageProvider::rawImage(previewUrl,4,&previewError);QVERIFY2(previewError.isEmpty(),qPrintable(previewError));QCOMPARE(onePixel.size(),QSize(1,1));QVERIFY(onePixel.sizeInBytes()<=4);
        QUrl invalidPreview=previewUrl;QUrlQuery invalidQuery(invalidPreview);invalidQuery.removeAllQueryItems("revision");invalidQuery.addQueryItem("revision","stale");invalidPreview.setQuery(invalidQuery);thumbnail->setSource(invalidPreview);QTRY_COMPARE_WITH_TIMEOUT(thumbnail->status(),3,10000);QVERIFY(!thumbnail->error().isEmpty());thumbnail->setSource(previewUrl);QTRY_COMPARE_WITH_TIMEOUT(thumbnail->status(),1,10000);
        const auto previewFrame=window->grabWindow();const auto redPoint=thumbnail->mapToScene(QPointF(thumbnail->width()*.2,thumbnail->height()*.5));const auto color=previewFrame.pixelColor(qRound(redPoint.x()*previewFrame.width()/window->width()),qRound(redPoint.y()*previewFrame.height()/window->height()));QVERIFY(color.red()>200 && color.blue()<40);
        auto *exportButton=visualItem(window->contentItem(),"exportContentImage");auto *exportDialog=window->findChild<QObject *>("contentImageExportDialog");QVERIFY(exportButton && exportDialog);QVERIFY(QMetaObject::invokeMethod(exportButton,"clicked"));QTRY_VERIFY(exportDialog->property("visible").toBool());QVERIFY(QMetaObject::invokeMethod(exportDialog,"reject"));QVERIFY(editor->property("imageExportRequest").isNull() || editor->property("imageExportRequest").value<QJSValue>().isNull());
        QVERIFY(QMetaObject::invokeMethod(exportButton,"clicked"));const auto output=scratch.path()+"/export.png";QVERIFY(QMetaObject::invokeMethod(editor,"exportImageTo",Q_ARG(QVariant,QUrl::fromLocalFile(output))));QMetaObject::invokeMethod(exportDialog,"reject");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QImage exported(output);QCOMPARE(exported.size(),QSize(4,2));QCOMPARE(exported.pixelColor(0,0),QColor(Qt::red));QCOMPARE(exported.pixelColor(3,0),QColor(Qt::blue));QCOMPARE(reader->data().value("content_objects").toMap().value("revision"),before.value("revision"));
        QVERIFY(QMetaObject::invokeMethod(exportButton,"clicked"));editor->setProperty("imageExportRequest",QVariantMap{{"reader",QVariant::fromValue(reader)},{"revision","stale"},{"page",0},{"target",image.value("id")}});const auto staleOutput=scratch.path()+"/stale.png";QVERIFY(QMetaObject::invokeMethod(editor,"exportImageTo",Q_ARG(QVariant,QUrl::fromLocalFile(staleOutput))));QMetaObject::invokeMethod(exportDialog,"reject");QVERIFY(!QFileInfo::exists(staleOutput));QCOMPARE(reader->pendingCommands(),0);
        QVERIFY(QMetaObject::invokeMethod(toggle,"clicked"));QTRY_VERIFY(left->isVisible());left->setProperty("text","110");QTRY_VERIFY(!apply->isEnabled());left->setProperty("text","50");right->setProperty("text","40");QTRY_VERIFY(!apply->isEnabled());right->setProperty("text","100");QTRY_VERIFY(apply->isEnabled());QVERIFY(QMetaObject::invokeMethod(toggle,"clicked"));QVERIFY(!reader->hasEditDrafts());QCOMPARE(reader->data().value("content_objects").toMap().value("revision"),before.value("revision"));QVERIFY(QMetaObject::invokeMethod(toggle,"clicked"));
        // File dialogs can stop/restart the scene graph. Require the visible thumbnail again,
        // rather than taking evidence while its replacement texture is still pending.
        QTRY_COMPARE_WITH_TIMEOUT(thumbnail->status(),1,10000);
        auto previewIsRed=[&]{const auto frame=window->grabWindow();if(frame.isNull())return false;const auto point=thumbnail->mapToScene(QPointF(thumbnail->width()*.2,thumbnail->height()*.5));const auto pixel=frame.pixelColor(qRound(point.x()*frame.width()/window->width()),qRound(point.y()*frame.height()/window->height()));return pixel.red()>200 && pixel.blue()<40;};
        QTRY_VERIFY_WITH_TIMEOUT(previewIsRed(),10000);
        const auto evidence=qEnvironmentVariable("LYRA_READER_CONTENT_CROP_SNAPSHOT");if(!evidence.isEmpty())QVERIFY(window->grabWindow().save(evidence));QVERIFY(QMetaObject::invokeMethod(apply,"clicked"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QTRY_VERIFY(!reader->hasEditDrafts());QTRY_VERIFY(reader->data().value("content_objects").toMap().value("revision")!=before.value("revision"));const auto cropped=imageFrom(reader->data().value("content_objects").toMap()).value("bounds").toMap();QVERIFY(qAbs(cropped.value("width").toDouble()-50)<.1);QVERIFY(qAbs(cropped.value("x").toDouble()-122)<.1);QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll(),original);file.close();
        QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(qAbs(imageFrom(reader->data().value("content_objects").toMap()).value("bounds").toMap().value("width").toDouble()-100)<.1);QVERIFY(QMetaObject::invokeMethod(window,"redo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);reopened.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QVERIFY(qAbs(imageFrom(reopened.data().value("content_objects").toMap()).value("bounds").toMap().value("width").toDouble()-50)<.1);reopened.requestText(0);QTRY_VERIFY_WITH_TIMEOUT(reopened.textPages().value("0").toMap().value("text").toString().contains("LyraReader fixture"),10000);
    }
    void largeBitmapPreviewHonorsSizeAndBudgetAndRetiresWithTheReader() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/large-preview.pdf",png=scratch.path()+"/large-preview.png";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QImage pixels(2048,1024,QImage::Format_RGBA8888);pixels.fill(Qt::red);{QPainter painter(&pixels);painter.fillRect(QRect(1024,0,1024,1024),Qt::blue);}QVERIFY(pixels.save(png));
        ReaderController reader;reader.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);reader.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);const auto revision=reader.data().value("content_objects").toMap().value("revision");reader.submit("content_stage",{{"page",0},{"command",QVariantMap{{"InsertImage",QVariantMap{{"revision",revision},{"bounds",QVariantMap{{"x",72},{"y",500},{"width",100},{"height",50}}},{"image_path",png}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,15000);QVERIFY2(reader.error().isEmpty(),qPrintable(reader.error()));reader.submit("content_objects",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);const auto snapshot=reader.data().value("content_objects").toMap();QVariantMap image;for(const auto &v:snapshot.value("items").toList())if(v.toMap().value("kind")=="image"){image=v.toMap();break;}QVERIFY(!image.isEmpty());
        const auto url=reader.contentPreviewUrl(0,image.value("id").toString(),snapshot.value("revision").toString(),600,300,1);QVERIFY(!url.isEmpty());QString error;QElapsedTimer timer;timer.start();const auto thumbnail=NativeImageProvider::rawImage(url,256*1024,&error);QVERIFY2(!thumbnail.isNull(),qPrintable(error));QVERIFY(thumbnail.width()<=608 && thumbnail.height()<=320);QVERIFY(thumbnail.sizeInBytes()<=256*1024);QCOMPARE(thumbnail.width(),thumbnail.height()*2);QVERIFY(thumbnail.pixelColor(thumbnail.width()/5,thumbnail.height()/2).red()>200);QVERIFY(thumbnail.pixelColor(thumbnail.width()*4/5,thumbnail.height()/2).blue()>200);const auto onePixel=NativeImageProvider::rawImage(url,4,&error);QCOMPARE(onePixel.size(),QSize(1,1));qInfo()<<"content-preview synthetic 2048x1024; two memory PNG decode paths ms"<<timer.elapsed()<<"thumbnail payload bytes"<<thumbnail.sizeInBytes();
        const auto pinned=reader.renderSource();reader.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));QTRY_COMPARE_WITH_TIMEOUT(reader.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader.pendingCommands(),0,10000);QVERIFY(NativeImageProvider::rawImage(url).isNull());const auto frozen=pinned->contentImage(0,image.value("id").toString(),snapshot.value("revision").toString(),{300,150},256*1024,&error);QVERIFY2(!frozen.isNull(),qPrintable(error));
    }
    void graphicContentPreviewUsesTheWorkingSourceAndReleasesHiddenPixels() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/graphic.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/form-text-pages.pdf",path));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto snapshot=reader->data().value("content_objects").toMap();QVariantMap graphic;for(const auto &v:snapshot.value("items").toList())if(v.toMap().value("kind")=="graphic"){graphic=v.toMap();break;}QVERIFY(!graphic.isEmpty());
        auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);QVERIFY(QMetaObject::invokeMethod(editor,"select",Q_ARG(QVariant,graphic),Q_ARG(QVariant,0)));auto *thumbnail=qobject_cast<CropItem *>(visualItem(window->contentItem(),"contentImagePreview"));QVERIFY(thumbnail);QTRY_COMPARE_WITH_TIMEOUT(thumbnail->status(),1,15000);QVERIFY(!thumbnail->pixelSize().isEmpty());const auto url=thumbnail->source();QVERIFY(!url.toString().contains("kind=bitmap"));QCOMPARE(QUrlQuery(url).queryItemValue("annotations"),QString("0"));QString error;auto pixels=NativeImageProvider::rawImage(url,1024*1024,&error);QVERIFY2(!pixels.isNull(),qPrintable(error));int ink=0,paper=0;for(int y=0;y<pixels.height();++y)for(int x=0;x<pixels.width();++x){const auto c=pixels.pixelColor(x,y);if(c.red()>110 && c.red()<170 && c.green()>50 && c.green()<110 && c.blue()<90)++ink;if(c.red()>240 && c.green()>240 && c.blue()>240)++paper;}qInfo()<<"graphic crop diagnostic"<<graphic.value("bounds")<<pixels.size()<<"ink"<<ink<<"paper"<<paper;const auto diagnostic=qEnvironmentVariable("LYRA_READER_CONTENT_GRAPHIC_DIAGNOSTIC");if(!diagnostic.isEmpty())QVERIFY(pixels.save(diagnostic));QVERIFY(ink>10 && paper>100);
        // The form inherits the page stream's 0.55/0.30/0.20 fill. Preserve that brown ink;
        // a black-only test would reject the correct preview of this fixture.
        const auto evidence=qEnvironmentVariable("LYRA_READER_CONTENT_GRAPHIC_SNAPSHOT");if(!evidence.isEmpty()){QTest::qWait(100);QVERIFY(window->grabWindow().save(evidence));}
        auto *exportButton=visualItem(window->contentItem(),"exportContentImage");auto *exportDialog=window->findChild<QObject *>("contentImageExportDialog");QVERIFY(exportButton && exportDialog);QVERIFY(exportButton->isVisible());QVERIFY(QMetaObject::invokeMethod(exportButton,"clicked"));QTRY_VERIFY(exportDialog->property("visible").toBool());QVERIFY(QMetaObject::invokeMethod(exportDialog,"reject"));
        QVERIFY(QMetaObject::invokeMethod(exportButton,"clicked"));const auto output=scratch.path()+"/graphic.png";QVERIFY(QMetaObject::invokeMethod(editor,"exportImageTo",Q_ARG(QVariant,QUrl::fromLocalFile(output))));QMetaObject::invokeMethod(exportDialog,"reject");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QImage exported(output);QVERIFY(!exported.isNull());const auto bounds=graphic.value("bounds").toMap();QVERIFY(qAbs(exported.width()-bounds.value("width").toDouble()*2)<=1);QVERIFY(qAbs(exported.height()-bounds.value("height").toDouble()*2)<=1);int exportedInk=0;for(int y=0;y<exported.height();++y)for(int x=0;x<exported.width();++x){const auto c=exported.pixelColor(x,y);if(c.red()>110 && c.red()<170 && c.green()>50 && c.green()<110 && c.blue()<90)++exportedInk;}QVERIFY(exportedInk>10);QCOMPARE(reader->data().value("content_objects").toMap().value("revision"),snapshot.value("revision"));
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,""),Q_ARG(QVariant,false)));QTRY_COMPARE(thumbnail->status(),0);QVERIFY(thumbnail->pixelSize().isEmpty());
        const auto pinned=reader->renderSource();reader->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/text-page.pdf"));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(pinned);QVERIFY(NativeImageProvider::rawImage(url).isNull());
    }
    void failedAndLateContentDraftsPreventUnintendedModeOrTabChanges() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto firstPath=scratch.path()+"/first.pdf",secondPath=scratch.path()+"/second.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",firstPath));QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",secondPath));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(firstPath));auto *first=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(first->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);workspace.openFile(QUrl::fromLocalFile(secondPath));QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(workspace.activeReader()->pendingCommands(),0,10000);workspace.selectTab(0);
        QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);const auto snapshot=first->data().value("content_objects").toMap();QVariantMap item;for(const auto &v:snapshot.value("items").toList()){const auto value=v.toMap();if(value.value("kind")=="text" && value.value("can_edit_text").toBool()){item=value;break;}}QVERIFY(!item.isEmpty());auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);
        QVERIFY(QMetaObject::invokeMethod(editor,"editText",Q_ARG(QVariant,item),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(editor,"changeText",Q_ARG(QVariant,"Preserved native draft")));const QVariant badFont=QVariantMap{{"font","NoSuchPdfFont"}};QVERIFY(QMetaObject::invokeMethod(editor,"changeStyle",Q_ARG(QVariant,badFont)));QVERIFY(QMetaObject::invokeMethod(editor,"commitDraft"));QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);QTRY_VERIFY(!first->editDrafts().value("content").toMap().value("error").toString().isEmpty());
        QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"lyra")));QCOMPARE(window->property("secondaryRow").toString(),QString("edit"));QVERIFY(QMetaObject::invokeMethod(window,"selectReaderTab",Q_ARG(QVariant,1),Q_ARG(QVariant,false)));QCOMPARE(workspace.activeReader(),first);const auto source=QVariant::fromValue(workspace.tabs().last().toMap().value("reader").value<ReaderController *>()),before=QVariant::fromValue(first);QVERIFY(QMetaObject::invokeMethod(window,"reorderReaderTab",Q_ARG(QVariant,source),Q_ARG(QVariant,before),Q_ARG(QVariant,false)));QCOMPARE(workspace.activeReader(),first);QCOMPARE(workspace.tabs().first().toMap().value("reader").value<ReaderController *>(),first);
        const QVariant goodFont=QVariantMap{{"font","Helvetica"}};QVERIFY(QMetaObject::invokeMethod(editor,"changeStyle",Q_ARG(QVariant,goodFont)));first->dismissError();QVERIFY(QMetaObject::invokeMethod(window,"toggleSecondaryRow",Q_ARG(QVariant,"lyra")));QVERIFY(QMetaObject::invokeMethod(editor,"changeText",Q_ARG(QVariant,"Late words after submission")));QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,15000);QCOMPARE(window->property("secondaryRow").toString(),QString("edit"));QVERIFY(first->hasEditDrafts());QCOMPARE(first->editDrafts().value("content").toMap().value("command").toMap().value("ReplaceText").toMap().value("text").toString(),QString("Late words after submission"));QTRY_VERIFY(!editor->property("canCommit").toBool());
    }
    void nativeRedactionAsksBeforeRemovingAnEntirePageTextLayer() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/form.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/form-text-pages.pdf",path));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *editor=window->findChild<QObject *>("contentEditing");QVERIFY(editor);auto *confirmation=window->findChild<QObject *>("contentRasterConfirmation");QVERIFY(confirmation);QVERIFY(QMetaObject::invokeMethod(editor,"arm",Q_ARG(QVariant,"blackout")));
        QVariantMap item;for(const auto &v:reader->data().value("content_objects").toMap().value("items").toList())if(v.toMap().value("text").toString().contains("In shared form")){item=v.toMap();break;}QVERIFY(!item.isEmpty());const QVariant bounds=item.value("bounds");
        QVERIFY(QMetaObject::invokeMethod(editor,"redact",Q_ARG(QVariant,bounds),Q_ARG(QVariant,0)));QTRY_VERIFY_WITH_TIMEOUT(confirmation->property("opened").toBool(),10000);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(clickDialogButton(window,confirmation,"Cancel"));QTRY_VERIFY(!confirmation->property("visible").toBool());QVERIFY(!reader->hasUnsavedChanges());
        QVERIFY(QMetaObject::invokeMethod(editor,"redact",Q_ARG(QVariant,bounds),Q_ARG(QVariant,0)));QTRY_VERIFY_WITH_TIMEOUT(confirmation->property("opened").toBool(),10000);QVERIFY(clickDialogButton(window,confirmation,"OK"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(reader->hasUnsavedChanges());reader->requestText(0);reader->requestText(1);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->textPages().value("0").toMap().value("text").toString().trimmed().isEmpty());QVERIFY(!reader->textPages().value("1").toMap().value("text").toString().trimmed().isEmpty());
        QVERIFY(QMetaObject::invokeMethod(window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->requestText(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->textPages().value("0").toMap().value("text").toString().contains("In shared form"));
    }
    void dateFormatsUseNativeLocaleStylesWithoutChangingTheCivilDay() {
        ReaderController reader;
        const QString day="2026-10-28";
        const auto check=[&](const QString &style,const QString &locale,const QString &expected) {
            const auto result=reader.formattedDate(style,day,locale);
            QCOMPARE(result.value("text").toString(),expected);
            QVERIFY(!result.contains("error"));
            QVERIFY(result.value("width").toDouble()>16 && result.value("height").toDouble()>12);
        };
        check("medium","en_US","Oct 28, 2026");check("long","en_US","October 28, 2026");check("short","en_US","10/28/26");
        check("medium","de_DE","28.10.2026");check("medium","fr_FR","28 oct. 2026");check("long","zh_CN",QString::fromUtf8("2026年10月28日"));
        check("iso","th_TH","2026-10-28");check("iso","ar_EG","2026-10-28");
        QVERIFY(reader.formattedDate("medium",day,"th_TH").value("text").toString().contains("2569"));
        QVERIFY(reader.formattedDate("medium",day,"ar_EG").value("text").toString()!=day);
        for(const auto &bad: {QString("2026-02-30"),QString("2026-2-3"),QString(10000,'1')})QVERIFY(reader.formattedDate("iso",bad,"en_US").contains("error"));
        QVERIFY(reader.formattedDate("other",day,"en_US").contains("error"));
        QVERIFY(reader.formattedDate("medium",day,"not-a-real-locale").contains("error"));
        QVERIFY(!reader.hasUnsavedChanges());
    }
    void datePicturesRotateClockwiseAndKeepTransparentSamples() {
        ReaderController reader;
        const auto decode=[](const QVariantMap &value){return QImage::fromData(QByteArray::fromBase64(value.value("image").toByteArray())).convertToFormat(QImage::Format_RGBA8888);};
        const auto base=decode(reader.datePicture("Oct 28, 2026",0));QVERIFY(!base.isNull());QVERIFY(base.width()>base.height());QCOMPARE(base.pixelColor(0,0).alpha(),0);QCOMPARE(base.pixelColor(base.width()-1,base.height()-1).alpha(),0);
        int ink=0;for(int y=0;y<base.height();++y)for(int x=0;x<base.width();++x)if(base.pixelColor(x,y).alpha()>0)++ink;QVERIFY(ink>30);
        for(int angle:{90,180,270}) {
            const auto result=reader.datePicture("Oct 28, 2026",angle);const auto image=decode(result);QVERIFY2(!image.isNull(),qPrintable(result.value("error").toString()));
            QCOMPARE(image.size(),angle==180 ? base.size() : QSize(base.height(),base.width()));QCOMPARE(result.value("heightPt").toDouble(),image.height()/2.0);
            for(int y=0;y<base.height();++y)for(int x=0;x<base.width();++x) {
                const QPoint target=angle==90 ? QPoint(base.height()-1-y,x) : angle==180 ? QPoint(base.width()-1-x,base.height()-1-y) : QPoint(y,base.width()-1-x);
                QCOMPARE(image.pixelColor(target),base.pixelColor(x,y));
            }
        }
        for(const auto &bad:{QString(),QString("\n"),QString(10000,'W')})QVERIFY(reader.datePicture(bad,90).contains("error"));
        QVERIFY(reader.datePicture("Date",45).contains("error"));
        const auto bounded=reader.datePicture(QString(256,'W'),90);
        if(!bounded.contains("error")){const auto image=decode(bounded);QVERIFY(!image.isNull());QVERIFY(image.width()<=4096 && image.height()<=4096);QVERIFY(qint64(image.width())*image.height()<=1024*1024);}
    }
    void rotatedDatesUseOneImageMarkAndSurvivePdfSave() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/rotated-dates.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);view.window->setProperty("fillDateFormat","iso");
        QList<QImage> expected;
        for(int index=0;index<3;++index) {
            QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));auto *rotation=visualItem(view.window->contentItem(),"fillDateRotation");QVERIFY(rotation && rotation->isVisible());QVERIFY(QMetaObject::invokeMethod(rotation,"activated",Q_ARG(int,index+1)));
            const auto result=reader->datePicture(reader->formattedDate("iso").value("text").toString(),(index+1)*90);const auto image=QImage::fromData(QByteArray::fromBase64(result.value("image").toByteArray())).convertToFormat(QImage::Format_RGBA8888);QVERIFY(!image.isNull());expected.append(image);
            QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,120.0+index*160),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));const auto entries=reader->data().value("marks").toMap().value("annotations").toList();QCOMPARE(entries.size(),index+1);const auto entry=entries.last().toMap();QCOMPARE(entry.value("kind").toString(),QString("signature"));QCOMPARE(entry.value("stampStyle").toString(),QString("date"));const auto rect=entry.value("rect").toMap();QVERIFY(rect.value("x").toDouble()>=0 && rect.value("y").toDouble()>=0);QCOMPARE(rect.value("width").toDouble(),result.value("widthPt").toDouble());QCOMPARE(rect.value("height").toDouble(),result.value("heightPt").toDouble());QVERIFY(view.window->property("fillTool").toString().isEmpty());
        }
        reader->submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().size(),2);reader->submit("marks_redo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto snapshot=qEnvironmentVariable("LYRA_READER_DATE_SNAPSHOT");if(!snapshot.isEmpty()){QTest::qWait(100);QVERIFY(view.window->grabWindow().save(snapshot));}
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);const auto saved=reopened.data().value("annotations").toList();QCOMPARE(saved.size(),3);
        for(int index=0;index<saved.size();++index){const auto annotation=saved[index].toMap();QCOMPARE(annotation.value("kind").toString(),QString("stamp"));const auto png=annotation.value("stamp").toMap().value("image").toByteArray();const auto actual=QImage::fromData(QByteArray::fromBase64(png)).convertToFormat(QImage::Format_RGBA8888);QCOMPARE(actual,expected[index]);}
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));QVERIFY(QMetaObject::invokeMethod(view.window,"clearFillTool"));QVERIFY(!reader->hasUnsavedChanges());
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));const auto generation=reader->documentGeneration();reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(reader->pageCount()==1 && !reader->loading() && reader->pendingCommands()==0,10000);QVERIFY(reader->documentGeneration()!=generation);QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->hasUnsavedChanges());QCOMPARE(reader->data().value("annotations").toList().size(),3);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));const auto secondPath=scratch.path()+"/second-date-document.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",secondPath));view.workspace.openFile(QUrl::fromLocalFile(secondPath));auto *second=view.workspace.activeReader();QVERIFY(second!=reader);QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);QVERIFY(view.window->property("fillTool").toString().isEmpty());QCOMPARE(view.window->property("annotationTool").toString(),QString("select"));QVERIFY(!second->hasUnsavedChanges());
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));auto *rotation=visualItem(view.window->contentItem(),"fillDateRotation");QVERIFY(rotation);rotation->forceActiveFocus();QTRY_VERIFY(rotation->hasActiveFocus());QTest::keyClick(view.window,Qt::Key_Escape);QTRY_VERIFY(view.window->property("fillTool").toString().isEmpty());QCOMPARE(view.window->property("annotationTool").toString(),QString("select"));QVERIFY(!second->hasUnsavedChanges());
    }
    void annotateRowKeepsThreeGroupsAndPlacesArtworkWithoutOpeningFillAndSign() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/annotation-row.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"annotate"),Q_ARG(QVariant,false)));
        auto *row=visualItem(view.window->contentItem(),"annotationToolRow");QVERIFY(row);QCOMPARE(row->height(),46.0);
        const QStringList groups{"annotateGroupMarkup","annotateGroupPointer","annotateGroupPlacement"};
        const QStringList buttons{"annotateToolhighlight","annotateToolunderline","annotateToolstrikeout","annotateToolink","annotateTooleraser","annotateTooltextBox","annotateShapes","annotateToolstickyNote","annotateStamp","annotateSignature"};
        for(int width:{1200,700,640}) {
            view.window->setWidth(width);QTest::qWait(50);double right=-20;
            for(const auto &name:groups){auto *group=visualItem(row,name);QVERIFY(group);const auto frame=group->mapRectToItem(row,group->boundingRect());QCOMPARE(frame.left()-right,34.0);right=frame.right();}
            for(const auto &name:buttons){auto *button=visualItem(row,name);QVERIFY(button && button->isVisible());QCOMPARE(button->width(),34.0);QCOMPARE(button->height(),32.0);const auto frame=button->mapRectToItem(row,button->boundingRect());QVERIFY(frame.left()>=0 && frame.right()<=width);auto *accessible=QAccessible::queryAccessibleInterface(button);QVERIFY(accessible && !accessible->text(QAccessible::Name).isEmpty());}
            auto *colour=visualItem(row,"annotateColour");QVERIFY(colour);QVERIFY(colour->mapRectToItem(row,colour->boundingRect()).right()<=width);
            const auto capture=qEnvironmentVariable("LYRA_READER_ANNOTATE_SNAPSHOT");if(!capture.isEmpty())QVERIFY(view.window->grabWindow().save(capture+QString::number(width)+".png"));
        }
        QVERIFY(QMetaObject::invokeMethod(visualItem(row,"annotateShapes"),"clicked"));
        QQuickItem *shape=nullptr;QTRY_VERIFY((shape=visualItem(view.window->contentItem(),"annotateShapearrow")) && shape->isVisible());QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,shape->mapToScene(shape->boundingRect().center()).toPoint());QCOMPARE(view.window->property("annotationTool").toString(),QString("arrow"));
        QVERIFY(QMetaObject::invokeMethod(visualItem(row,"annotateStamp"),"clicked"));
        QQuickItem *stamp=nullptr;QTRY_VERIFY((stamp=visualItem(view.window->contentItem(),"annotateStampapproved")) && stamp->isVisible());QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,stamp->mapToScene(stamp->boundingRect().center()).toPoint());QCOMPARE(view.window->property("annotationTool").toString(),QString("stamp"));QCOMPARE(view.window->property("secondaryRow").toString(),QString("annotate"));QVERIFY(!view.window->property("fillInspectorVisible").toBool());
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,150.0),Q_ARG(QVariant,250.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().last().toMap().value("stampStyle").toString(),QString("approved"));QCOMPARE(view.window->property("secondaryRow").toString(),QString("annotate"));
        QVERIFY(QMetaObject::invokeMethod(visualItem(row,"annotateSignature"),"clicked"));QQuickItem *draw=nullptr;QTRY_VERIFY((draw=visualItem(view.window->contentItem(),"annotateDrawSignature")) && draw->isVisible());QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,draw->mapToScene(draw->boundingRect().center()).toPoint());QCOMPARE(view.window->property("annotationTool").toString(),QString("ink"));
        const auto imagePath=scratch.path()+"/signature.png";QImage image(4,2,QImage::Format_RGBA8888);image.fill(Qt::black);QVERIFY(image.save(imagePath));
        QVERIFY(QMetaObject::invokeMethod(row,"chooseSignature"));auto *picker=row->findChild<QObject *>("annotateSignatureImagePicker");QVERIFY(picker);QTRY_VERIFY(picker->property("visible").toBool());
        QVERIFY(picker->setProperty("selectedFile",QUrl::fromLocalFile(imagePath)));QVERIFY(QMetaObject::invokeMethod(picker,"accepted"));QVERIFY(QMetaObject::invokeMethod(picker,"close"));
        QCOMPARE(view.window->property("secondaryRow").toString(),QString("annotate"));QCOMPARE(view.window->property("annotationTool").toString(),QString("signature"));QVERIFY(!view.window->property("fillInspectorVisible").toBool());
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,250.0),Q_ARG(QVariant,350.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().last().toMap().value("kind").toString(),QString("signature"));
        QVERIFY(QMetaObject::invokeMethod(row,"chooseSignature"));QTRY_VERIFY(picker->property("visible").toBool());reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY(reader->pageCount()==1 && !reader->loading() && reader->pendingCommands()==0);
        QVERIFY(picker->setProperty("selectedFile",QUrl::fromLocalFile(imagePath)));QVERIFY(QMetaObject::invokeMethod(picker,"accepted"));QVERIFY(QMetaObject::invokeMethod(picker,"close"));QCOMPARE(view.window->property("annotationTool").toString(),QString("select"));QVERIFY(view.window->property("operationStatus").toString().contains("document changed"));
    }
    void ordinaryTextBoxesEditInlineAndCancelWithoutDeletingTheExistingMark() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/ordinary-text.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","textBox"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",80},{"y",250},{"width",180},{"height",60}}},{"color","#2B2B2EFF"},{"note","Existing annotation"},{"fontSize",14}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto before=reader->data().value("marks").toMap().value("annotations").toList().last().toMap();
        QVERIFY(QMetaObject::invokeMethod(view.window,"selectAnnotation",Q_ARG(QVariant,before),Q_ARG(QVariant,true)));
        auto *input=visualItem(view.window->contentItem(),"placedTextInput0");
        QTRY_VERIFY2(input && input->isVisible(),"Ordinary text boxes must use the page editor, just like placed dates");
        QTRY_VERIFY(input->hasActiveFocus());QCOMPARE(input->property("selectedText").toString(),QString());
        auto *editing=view.window->findChild<QObject *>("placedTextEditing");QVERIFY(editing);QVERIFY(!editing->property("created").toBool());
        QVERIFY(QMetaObject::invokeMethod(input,"selectAll"));for(char key:QByteArray("Cancelled replacement"))QTest::keyClick(view.window,key);
        QTest::qWait(650);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTest::keyClick(view.window,Qt::Key_Escape);QTRY_VERIFY(!editing->property("active").toBool());
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().last().toMap(),before);
        QVERIFY(QMetaObject::invokeMethod(view.window,"selectAnnotation",Q_ARG(QVariant,before),Q_ARG(QVariant,true)));
        QTRY_VERIFY(input->isVisible() && input->hasActiveFocus());QVERIFY(QMetaObject::invokeMethod(input,"selectAll"));
        for(char key:QByteArray("Committed annotation"))QTest::keyClick(view.window,key);QTest::keyClick(view.window,Qt::Key_Return,Qt::ControlModifier);
        QTRY_VERIFY(!editing->property("active").toBool());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().last().toMap().value("note").toString(),QString("Committed annotation"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"undo"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().last().toMap(),before);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"annotate"),Q_ARG(QVariant,false)));
        QVERIFY(QMetaObject::invokeMethod(view.window,"setAnnotationTool",Q_ARG(QVariant,"textBox")));
        view.window->setProperty("fitting",false);view.window->setProperty("zoom",1.54);
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,80.0),Q_ARG(QVariant,350.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QTRY_VERIFY(editing->property("active").toBool());QTRY_VERIFY(input->isVisible() && input->hasActiveFocus());QVERIFY(editing->property("created").toBool());
        QCOMPARE(view.window->property("annotationTool").toString(),QString("select"));
        for(char key:QByteArray("New annotation"))QTest::keyClick(view.window,key);
        QTRY_COMPARE(input->property("lineCount").toInt(),1);
        QTest::keyClick(view.window,Qt::Key_Escape);
        QTRY_VERIFY(!editing->property("active").toBool());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList(),QVariantList{before});
        auto *page=visualItem(view.window->contentItem(),"pdfPage0");QVERIFY(page);const double zoom=view.window->property("zoom").toDouble();
        QTest::mouseClick(view.window,Qt::RightButton,Qt::NoModifier,page->mapToScene(QPointF(100*zoom,270*zoom)).toPoint());
        QQuickItem *properties=nullptr;QTRY_VERIFY((properties=visualItem(view.window->contentItem(),"annotationPropertiesAction")) && properties->isVisible() && properties->isEnabled());
        QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,properties->mapToScene(properties->boundingRect().center()).toPoint());
        auto *dialog=view.window->findChild<QObject *>("annotationEditor");QVERIFY(dialog);QTRY_VERIFY(dialog->property("visible").toBool());
        auto *font=view.window->findChild<QQuickItem *>("annotationFontSize");QVERIFY(font);font->forceActiveFocus();QTest::keyClick(view.window,Qt::Key_Up);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().last().toMap().value("fontSize").toInt(),15);
        QVERIFY(QMetaObject::invokeMethod(dialog,"close"));
    }
    void savedFreeTextIsAdoptedForInlineEditingAndKeepsItsIdentityOnSave() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/saved-free-text.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","textBox"},{"page",0},{"version",1},{"rect",QVariantMap{{"x",80},{"y",250},{"width",180},{"height",60}}},{"color","#2B2B2EFF"},{"note","PDF-owned text"},{"fontSize",14},{"textAlignment","right"}}}});
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto identity=reader->data().value("marks").toMap().value("annotations").toList().first().toMap().value("id");
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        const auto all=view.window->property("annotations").value<QJSValue>().toVariant().toList();QCOMPARE(all.size(),1);const auto loaded=all.first().toMap();QVERIFY(loaded.value("foreign").toBool());QCOMPARE(loaded.value("kind").toString(),QString("textBox"));
        auto *propertiesDialog=view.window->findChild<QObject *>("annotationEditor");QVERIFY(propertiesDialog);QVERIFY(QMetaObject::invokeMethod(propertiesDialog,"close"));QTRY_VERIFY(!propertiesDialog->property("visible").toBool());
        auto *page=visualItem(view.window->contentItem(),"pdfPage0");QVERIFY(page);const double zoom=view.window->property("zoom").toDouble();const auto point=page->mapToScene(QPointF(150*zoom,280*zoom)).toPoint();
        QTest::mouseClick(view.window,Qt::LeftButton,Qt::NoModifier,point);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY2(!view.window->findChild<QObject *>("annotationEditor")->property("visible").toBool(),"The first click must not open a property dialog that consumes the second click");
        QTest::mouseDClick(view.window,Qt::LeftButton,Qt::NoModifier,point);
        QTest::mouseRelease(view.window,Qt::LeftButton,Qt::NoModifier,point);
        auto *editing=view.window->findChild<QObject *>("placedTextEditing");QVERIFY(editing);
        QTRY_VERIFY2(editing->property("active").toBool(),qPrintable(reader->error()+" / "+view.window->property("operationStatus").toString()));
        QTRY_VERIFY2(!editing->property("token").toString().isEmpty(),qPrintable(editing->property("error").toString()));
        QPointer<QQuickItem> input;QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        QVERIFY(!editing->property("created").toBool());QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        const auto entry=editing->property("entry");const auto entryMap=entry.metaType()==QMetaType::fromType<QJSValue>() ? entry.value<QJSValue>().toVariant().toMap() : entry.toMap();
        QCOMPARE(entryMap.value("fileIdentity").toString(),"nm:"+identity.toString());
        QCOMPARE(input->property("horizontalAlignment").toInt(),int(Qt::AlignRight));
        QVERIFY(!view.window->findChild<QObject *>("annotationEditor")->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(input,"selectAll"));for(char key:QByteArray("Saved after adoption"))QTest::keyClick(view.window,key);
        QTest::keyClick(view.window,Qt::Key_Return,Qt::ControlModifier);QTRY_VERIFY(!editing->property("active").toBool());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);
        const auto saved=reopened.data().value("annotations").toList();QCOMPARE(saved.size(),1);const auto annotation=saved.first().toMap();QCOMPARE(annotation.value("contents").toString(),QString("Saved after adoption"));QCOMPARE(annotation.value("id").toString(),"nm:"+identity.toString());
    }
    void nativeUndoAfterCancellingAnAdoptedTextEditLeavesAnIdleTransactionClean() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/idle-transaction.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/flatten.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",1}}}}},{"current_page",0},{"selected_pages",QVariantList{0}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);
        reader->submit("page_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
        QVariantMap annotation;const auto all=view.window->property("annotations").value<QJSValue>().toVariant().toList();for(const auto &value:all)if(value.toMap().value("kind")=="textBox"){annotation=value.toMap();break;}QVERIFY(!annotation.isEmpty());
        QVERIFY(QMetaObject::invokeMethod(view.window,"selectAnnotation",Q_ARG(QVariant,annotation),Q_ARG(QVariant,true)));
        auto *editing=view.window->findChild<QObject *>("placedTextEditing");QVERIFY(editing);QPointer<QQuickItem> input;QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        QVERIFY(QMetaObject::invokeMethod(input,"selectAll"));for(char key:QByteArray("Cancelled draft"))QTest::keyClick(view.window,key);QTest::qWait(650);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        const auto editRect=editing->property("rect").value<QJSValue>().toVariant().toMap();
        QVERIFY(editRect.value("height").toDouble()>=reader->data().value("annotation_rules").toMap().value("min_text_box_height_pt").toDouble());
        QTest::keyClick(view.window,Qt::Key_Escape);QTRY_VERIFY(!editing->property("active").toBool());QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTest::keyClick(view.window,Qt::Key_Z,Qt::ControlModifier);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY2(!reader->hasUnsavedChanges(),qPrintable(QString("Focus after cancellation: %1; marks: %2").arg(view.window->activeFocusItem() ? view.window->activeFocusItem()->objectName() : QString("none"),QString::fromUtf8(QJsonDocument::fromVariant(reader->data().value("marks")).toJson(QJsonDocument::Compact)))));
        QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());
    }
    void unrotatedDateStartsAnInlineEditorAndSelectsTheWholeDate() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/inline-date.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;
        QVERIFY(view.window);
        view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        view.window->setProperty("selection",QVariantMap{{"page",0},{"start",0},{"end",3}});
        QVERIFY(!view.window->property("selection").isNull());
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QPointer<QQuickItem> input=visualItem(view.window->contentItem(),"placedTextInput0");
        QVERIFY2(input,"A zero-degree date must open the editor over its own page box");
        QTRY_VERIFY(input->isVisible());
        QTRY_VERIFY(input->isVisible() && input->hasActiveFocus());
        QVERIFY2(view.window->property("selection").isNull(),"Editing a placed date must clear the underlying PDF text selection");
        const auto today=reader->formattedDate("medium").value("text").toString();
        QCOMPARE(input->property("selectedText").toString(),today);
        const auto snapshot=qEnvironmentVariable("LYRA_READER_INLINE_DATE_SNAPSHOT");
        if(!snapshot.isEmpty()){QTest::qWait(40);QVERIFY(view.window->grabWindow().save(snapshot));}
        view.window->setProperty("fitting",false);
        view.window->setProperty("zoom",1.54);
        for (char key : QByteArray("Typed through native Qt")) QTest::keyClick(view.window,key);
        QTest::qWait(80);
        QTRY_VERIFY2(input->property("contentHeight").toDouble()+input->property("topPadding").toDouble()+input->property("bottomPadding").toDouble()<=input->height()+1,
            "Every typed line must fit inside the automatically sized editor");
        QTest::keyClick(view.window,Qt::Key_Return,Qt::ControlModifier);
        QVERIFY2(!input || !input->isVisible() || input->property("readOnly").toBool(),"Finishing freezes the acknowledged text before the asynchronous end command");
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTRY_VERIFY(!input || !input->isVisible());
        QVERIFY2(!input || !input->hasActiveFocus(),"A closed text editor must release keyboard focus");
        QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        auto entries=reader->data().value("marks").toMap().value("annotations").toList();
        QCOMPARE(entries.size(),1);
        QCOMPARE(entries.first().toMap().value("note").toString(),QString("Typed through native Qt"));
        // All keystrokes in the editing session are one edit, separate from creation.
        reader->submit("marks_undo");
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().first().toMap().value("note").toString(),today);
        reader->submit("marks_redo");
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);
        QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QVERIFY(!reader->hasUnsavedChanges());
        ReaderController reopened;
        reopened.openFile(QUrl::fromLocalFile(path));
        QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);
        const auto embedded=reopened.data().value("annotations").toList();
        QCOMPARE(embedded.size(),1);
        QCOMPARE(embedded.first().toMap().value("contents").toString(),QString("Typed through native Qt"));
    }
    void inlineDateEscapeCancelsAllDurableFlushesAndTabSwitchCommitsTheLastText() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/inline-date.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;
        QVERIFY(view.window);
        view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QPointer<QQuickItem> input;

        QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        for(const auto &text:{QByteArray("first"),QByteArray("second")}) {
            QTest::keyClick(view.window,Qt::Key_A,Qt::ControlModifier);
            for(char key:text)QTest::keyClick(view.window,key);
            QTRY_COMPARE_WITH_TIMEOUT(reader->data().value("marks").toMap().value("annotations").toList().first().toMap().value("note").toString(),QString::fromLatin1(text),10000);
            QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        }
        QTest::keyClick(view.window,Qt::Key_Escape);
        QTRY_VERIFY(!input || !input->isVisible());
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(!reader->hasUnsavedChanges());
        QVERIFY(reader->noteDrafts().isEmpty());
        QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());
        QVERIFY(!reader->data().value("marks").toMap().value("can_undo").toBool());
        // Escape also cancels a placement whose creation acknowledgement is still queued.
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QTest::keyClick(view.window,Qt::Key_Escape);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());
        QVERIFY(!reader->hasUnsavedChanges());
        // Merely opening and finishing the editor must not add a geometry-only undo step.
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        QTest::keyClick(view.window,Qt::Key_Return,Qt::ControlModifier);
        QTRY_VERIFY(!input || !input->isVisible());
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("marks_undo");
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());
        QVERIFY(!reader->hasUnsavedChanges());
        // Returning the desktop to another tab is deferred until the last text is durable.
        view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));
        auto *other=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(other->pageCount(),3,10000);
        QTRY_COMPARE_WITH_TIMEOUT(other->pendingCommands(),0,10000);
        view.workspace.selectTab(0);
        QTRY_COMPARE(view.workspace.activeReader(),reader);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        input=visualItem(view.window->contentItem(),"placedTextInput0");
        QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        for(char key:QByteArray("Last text before switching tabs"))QTest::keyClick(view.window,key);
        QVERIFY(QMetaObject::invokeMethod(view.window,"selectReaderTab",Q_ARG(QVariant,1),Q_ARG(QVariant,false)));
        QTRY_COMPARE_WITH_TIMEOUT(view.workspace.activeReader(),other,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QCOMPARE(reader->data().value("marks").toMap().value("annotations").toList().first().toMap().value("note").toString(),QString("Last text before switching tabs"));
        QVERIFY(reader->noteDrafts().isEmpty());
        QVERIFY(!other->hasUnsavedChanges());
    }
    void inlineDatePreservesTheDraftWhenItsCacheChangedOutsideTheApp() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/date-conflict.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto pdfBefore=original.readAll();original.close();
        NativeCorpus::Viewer view;
        QVERIFY(view.window);
        view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QPointer<QQuickItem> input;
        QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QFile cache(reader->data().value("marks").toMap().value("path").toString());
        QVERIFY(cache.open(QIODevice::ReadOnly));const auto cacheBefore=cache.readAll();cache.close();
        QVERIFY(cache.open(QIODevice::WriteOnly));QCOMPARE(cache.write(cacheBefore+" "),cacheBefore.size()+1);cache.close();
        for(char key:QByteArray("Preserve this draft"))QTest::keyClick(view.window,key);
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));
        QTRY_VERIFY_WITH_TIMEOUT(!reader->error().isEmpty(),10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(input->isVisible());
        QCOMPARE(input->property("text").toString(),QString("Preserve this draft"));
        QVERIFY(!reader->noteDrafts().isEmpty());
        QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),pdfBefore);original.close();
        QVERIFY(cache.open(QIODevice::ReadOnly));QCOMPARE(cache.readAll(),cacheBefore+" ");cache.close();
        QTest::keyClick(view.window,Qt::Key_Escape);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(input->isVisible());
        // Restore the controlled fixture's bytes, then retry cancellation. Production never
        // performs this repair automatically or overwrites another process's cache changes.
        QVERIFY(cache.open(QIODevice::WriteOnly));QCOMPARE(cache.write(cacheBefore),cacheBefore.size());cache.close();
        QTest::keyClick(view.window,Qt::Key_Escape);
        QTRY_VERIFY_WITH_TIMEOUT(!input || !input->isVisible(),10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(!reader->hasUnsavedChanges());
    }
    void inlineDateSaveAndCloseDrainsThePendingTextSession() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/date-close.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;
        QVERIFY(view.window);
        view.workspace.openFile(QUrl::fromLocalFile(path));
        QPointer<ReaderController> reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QPointer<QQuickItem> input;
        QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        for(char key:QByteArray("Closed without losing the last text"))QTest::keyClick(view.window,key);
        view.workspace.closeTab(0);
        auto *confirmation=view.window->findChild<QObject *>("closeChangesConfirmation");
        QVERIFY(confirmation);QTRY_VERIFY_WITH_TIMEOUT(confirmation->property("opened").toBool(),10000);
        QVERIFY(clickDialogButton(view.window,confirmation,"Save"));
        QTRY_VERIFY_WITH_TIMEOUT(reader.isNull(),15000);
        ReaderController reopened;
        reopened.openFile(QUrl::fromLocalFile(path));
        QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);
        QVERIFY2(reopened.error().isEmpty(),qPrintable(reopened.error()));
        const auto embedded=reopened.data().value("annotations").toList();
        QCOMPARE(embedded.size(),1);
        QCOMPARE(embedded.first().toMap().value("contents").toString(),QString("Closed without losing the last text"));
        QVERIFY(!reopened.hasUnsavedChanges());
    }
    void lateDatePlacementDoesNotOpenAnEditorAfterChangingToolRowsOrReaders() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/date-owner.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;
        QVERIFY(view.window);
        view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *first=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(first->pageCount(),1,10000);
        QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QVERIFY(QMetaObject::invokeMethod(view.window,"setSecondaryRow",Q_ARG(QVariant,"edit"),Q_ARG(QVariant,true)));
        QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        auto *editor=view.window->findChild<QObject *>("placedTextEditing");
        auto *dialog=view.window->findChild<QObject *>("annotationEditor");
        QVERIFY(editor && dialog);
        QVERIFY(!editor->property("active").toBool());
        QVERIFY(!dialog->property("visible").toBool());
        QCOMPARE(view.window->property("secondaryRow").toString(),QString("edit"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        view.workspace.openFile(QUrl::fromLocalFile(root+"/tests/fixtures/multipage.pdf"));
        auto *other=view.workspace.activeReader();
        QVERIFY(other!=first);
        QTRY_COMPARE_WITH_TIMEOUT(other->pageCount(),3,10000);
        QTRY_COMPARE_WITH_TIMEOUT(other->pendingCommands(),0,10000);
        QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        QVERIFY(!editor->property("active").toBool());
        QVERIFY(!editor->property("waitingForCreation").toBool());
        QVERIFY(!dialog->property("visible").toBool());
        QVERIFY(!other->hasUnsavedChanges());
    }
    void inlineDateKeepsFocusAndSelectionWhenPageRowsAreRebuilt() {
        QTemporaryDir scratch;
        QVERIFY(scratch.isValid());
        const auto path=scratch.path()+"/date-reflow.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        NativeCorpus::Viewer view;
        QVERIFY(view.window);
        view.workspace.openFile(QUrl::fromLocalFile(path));
        auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QPointer<QQuickItem> input;
        QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        const auto selected=input->property("selectedText").toString();
        QVERIFY(!selected.isEmpty());
        reader->setLayout("Facing",12);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QTRY_VERIFY((input=visualItem(view.window->contentItem(),"placedTextInput0")) && input->isVisible() && input->hasActiveFocus());
        QCOMPARE(input->property("selectedText").toString(),selected);
        QTest::keyClick(view.window,Qt::Key_Escape);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(!reader->hasUnsavedChanges());
    }
    void dateFormatInspectorPlacesEditableTextAndRejectsAReopenedDocument() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/date.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));
        auto *format=visualItem(view.window->contentItem(),"fillDateFormat"),*preview=visualItem(view.window->contentItem(),"fillDatePreview");QVERIFY(format && preview);QVERIFY(format->isVisible());
        QVERIFY(QMetaObject::invokeMethod(format,"activated",Q_ARG(int,3)));QCOMPARE(view.window->property("fillDateFormat").toString(),QString("iso"));
        const auto today=reader->formattedDate("iso").value("text").toString();QCOMPARE(preview->property("text").toString(),today);
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        const auto entries=reader->data().value("marks").toMap().value("annotations").toList();QCOMPARE(entries.size(),1);const auto date=entries.first().toMap();QCOMPARE(date.value("kind").toString(),QString("textBox"));QCOMPARE(date.value("note").toString(),today);QCOMPARE(date.value("fontSize").toInt(),14);
        reader->submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->hasUnsavedChanges());reader->submit("marks_redo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(view.window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);const auto saved=reopened.data().value("annotations").toList();QCOMPARE(saved.size(),1);QCOMPARE(saved.first().toMap().value("kind").toString(),QString("freeText"));
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));const auto generation=reader->documentGeneration();reader->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(!reader->loading() && reader->pendingCommands()==0 && reader->pageCount()==1,10000);QVERIFY(reader->documentGeneration()!=generation);
        QVERIFY(QMetaObject::invokeMethod(view.window,"pageClicked",Q_ARG(QVariant,0),Q_ARG(QVariant,200.0),Q_ARG(QVariant,300.0),Q_ARG(QVariant,400.0),Q_ARG(QVariant,400.0)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->hasUnsavedChanges());QVERIFY(reader->data().value("marks").toMap().value("annotations").toList().isEmpty());QCOMPARE(reader->data().value("annotations").toList().size(),1);
        QVERIFY(QMetaObject::invokeMethod(view.window,"setFillTool",Q_ARG(QVariant,"date")));QVERIFY(QMetaObject::invokeMethod(view.window,"clearFillTool"));QVERIFY(!reader->hasUnsavedChanges());
    }
    void fillAndSignUsesSevenToolsAndVectorCheckmarks() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/fill.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(QMetaObject::invokeMethod(window,"setSecondaryRow",Q_ARG(QVariant,"fill"),Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        for(const auto &name:{"fillTooltext","signatureToolButton","fillTooldate","fillToolcheck","fillToolcross","stampToolButton","fillToolimage"}){auto *button=visualItem(window->contentItem(),name);QVERIFY2(button,name);QVERIFY(button->isVisible());}
        QVERIFY(!window->property("fillInspectorVisible").toBool());QTRY_VERIFY(!window->property("positionRestoring").toBool());window->setProperty("fitting",false);QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,0.75),Q_ARG(QVariant,300),Q_ARG(QVariant,300)));
        int expected=0;for(const auto &kind:{"check","cross","date","text"}) {
            QVERIFY(QMetaObject::invokeMethod(window,"setFillTool",Q_ARG(QVariant,kind)));QTRY_VERIFY(window->property("fillInspectorVisible").toBool());QTRY_VERIFY_WITH_TIMEOUT(visualItem(window->contentItem(),"pdfPage0") && visualItem(window->contentItem(),"pdfPage0")->property("texturesReady").toBool(),10000);
            auto *page=visualItem(window->contentItem(),"pdfPage0");const double zoom=window->property("zoom").toDouble();const QPoint point=page->mapToScene(QPointF(200*zoom,(300+expected*40)*zoom)).toPoint();QVERIFY2(QRect(0,0,window->width(),window->height()).contains(point),qPrintable(QString("Placement point %1,%2 outside %3x%4 at zoom %5").arg(point.x()).arg(point.y()).arg(window->width()).arg(window->height()).arg(zoom)));QTest::mouseClick(window,Qt::LeftButton,Qt::NoModifier,point);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto entries=reader->data().value("marks").toMap().value("annotations").toList();QCOMPARE(entries.size(),++expected);QCOMPARE(entries.last().toMap().value("kind").toString(),QString(expected<=2 ? "ink" : "textBox"));QVERIFY(window->property("fillTool").toString().isEmpty());
        }
        QVERIFY(QMetaObject::invokeMethod(window,"saveDocument",Q_ARG(QVariant,false)));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(!reader->hasUnsavedChanges());
    }
    void xfaWriteControlsStayReadOnlyAndLocalBookmarksRemainUsable() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/xfa.pdf",output=scratch.path()+"/blocked.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/xfa-refusal.pdf",path));QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_VERIFY_WITH_TIMEOUT(reader->pageCount()>0,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(window->property("xfaReadOnly").toBool());QVERIFY(!window->property("canModifyPdf").toBool());
        for(const auto &name:{"annotateButton","fillSignButton","saveDocumentAction","saveDocumentAsAction"}){auto *control=window->findChild<QObject *>(name);QVERIFY2(control,name);QVERIFY(!control->property("enabled").toBool());}
        const auto idle=reader->pendingCommands();QVERIFY(QMetaObject::invokeMethod(window,"setAnnotationTool",Q_ARG(QVariant,"ink")));QCOMPARE(window->property("annotationTool").toString(),QString("select"));QVERIFY(QMetaObject::invokeMethod(window,"toggleForms"));QVERIFY(!window->property("formToolActive").toBool());
        const QVariant pageEdit=QVariantMap{{"InsertBlank",QVariantMap{{"index",0}}}};QVERIFY(QMetaObject::invokeMethod(window,"pageOperation",Q_ARG(QVariant,pageEdit)));QCOMPARE(reader->pendingCommands(),idle);QVERIFY(!window->property("pageEditBusy").toBool());
        auto *save=window->findChild<QObject *>("documentSaveDialog");QVERIFY(save);QVERIFY(QMetaObject::invokeMethod(window,"chooseExport",Q_ARG(QVariant,"annotations")));QVERIFY(!save->property("visible").toBool());
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","stickyNote"},{"page",0}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);const auto reason=reader->data().value("xfa_status").toMap().value("read_only_reason").toString();QCOMPARE(reader->error(),reason);
        reader->submit("save_current_annotations",{{"destination",output}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->error(),reason);QVERIFY(!QFile::exists(output));reader->dismissError();
        QVERIFY(QMetaObject::invokeMethod(window,"addBookmark"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QCOMPARE(reader->data().value("marks").toMap().value("bookmarks").toList().size(),1);QVERIFY(!reader->hasUnsavedChanges());
        reader->submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->data().value("marks").toMap().value("bookmarks").toList().isEmpty());reader->submit("marks_redo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->data().value("marks").toMap().value("bookmarks").toList().size(),1);
        reader->submit("text",{{"page",0}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(reader->error().isEmpty());QPointer<ReaderController> closing=reader;workspace.closeTab(0);QTRY_VERIFY_WITH_TIMEOUT(closing.isNull(),10000);auto *confirmation=window->findChild<QObject *>("closeChangesConfirmation");QVERIFY(confirmation);QVERIFY(!confirmation->property("visible").toBool());
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(reopened.pageCount()>0,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QCOMPARE(reopened.data().value("marks").toMap().value("bookmarks").toList().size(),1);QVERIFY(!reopened.hasUnsavedChanges());QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);
    }
    void cachedDraftCloseSavesOnlyTheChosenBackgroundTab() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto firstPath=scratch.path()+"/first.pdf",secondPath=scratch.path()+"/second.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",firstPath));QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",secondPath));QFile source(firstPath);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(firstPath));auto *first=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(first->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        first->submit("bookmark_create",{{"page",0},{"title","Saved from background tab"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);QVERIFY(first->hasUnsavedChanges());
        first->submit("marks_undo");QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);QVERIFY(!first->hasUnsavedChanges());first->submit("marks_redo");QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);QVERIFY(first->hasUnsavedChanges());
        workspace.openFile(QUrl::fromLocalFile(secondPath));auto *second=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);QVERIFY(!second->hasUnsavedChanges());
        QPointer<ReaderController> closing=first;workspace.closeTab(0);auto *dialog=window->findChild<QObject *>("closeChangesConfirmation");QVERIFY(dialog);QTRY_VERIFY(dialog->property("opened").toBool());
        QVERIFY(clickDialogButton(window,dialog,"Save"));QTRY_VERIFY_WITH_TIMEOUT(closing.isNull(),15000);QCOMPARE(workspace.activeReader(),second);QCOMPARE(workspace.tabs().size(),1);
        ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(firstPath));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QVERIFY(!reopened.hasUnsavedChanges());QCOMPARE(reopened.data().value("marks").toMap().value("bookmarks").toList().first().toMap().value("title").toString(),QString("Saved from background tab"));
        QVERIFY(source.open(QIODevice::ReadOnly));QVERIFY(source.readAll()!=original);
    }
    void discardCloseKeepsOpaqueRecordsAndPreservesDraftsOnMetadataFailure() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/discard.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));
        QString recordsPath;{ReaderController probe;probe.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(probe.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(probe.pendingCommands(),0,10000);recordsPath=probe.data().value("marks").toMap().value("path").toString();}
        const QByteArray foreign=R"({ "kind":"future", "id":"9CD73B7D-7A3A-4FB0-814A-AF0211B7DDEF", "page":0, "raw":1.0000000000000001 })";
        QFile records(recordsPath);QVERIFY(records.open(QIODevice::WriteOnly));records.write("["+foreign+"]\n");records.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("bookmark_create",{{"page",0},{"title","Keep on failure"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QFile pending(QFileInfo(recordsPath).dir().filePath("changes.json"));QVERIFY(pending.open(QIODevice::ReadOnly));const auto baseline=pending.readAll();pending.close();QVERIFY(pending.open(QIODevice::WriteOnly));const auto external=baseline+" \n";pending.write(external);pending.close();
        reader->setNoteDraft("pending-note","Keep this note");reader->setEditDraft("forms",QVariantMap{{"pending",true}});
        workspace.closeTab(0);auto *dialog=window->findChild<QObject *>("closeChangesConfirmation");QVERIFY(dialog);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Discard"));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!reader->error().isEmpty());QCOMPARE(workspace.activeReader(),reader);QVERIFY(reader->hasUnsavedChanges());QVERIFY(!reader->noteDrafts().isEmpty());QVERIFY(reader->hasEditDrafts());
        QVERIFY(pending.open(QIODevice::ReadOnly));QCOMPARE(pending.readAll(),external);pending.close();QVERIFY(pending.open(QIODevice::WriteOnly));pending.write(baseline);pending.close();
        QPointer<ReaderController> closing=reader;workspace.closeTab(0);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Discard"));QTRY_VERIFY_WITH_TIMEOUT(closing.isNull(),10000);
        QVERIFY(records.open(QIODevice::ReadOnly));QVERIFY(records.readAll().contains(foreign));records.close();ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QVERIFY(!reopened.hasUnsavedChanges());QCOMPARE(reopened.data().value("marks").toMap().value("preserved").toInt(),1);QVERIFY(reopened.data().value("marks").toMap().value("bookmarks").toList().isEmpty());
    }
    void closeReviewAndFailedOrStaleSavesKeepTheDocumentOpen() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/review.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/form-fields.pdf",path));QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->setEditDraft("forms",QVariantMap{{"review",true}});
        workspace.closeTab(0);auto *dialog=window->findChild<QObject *>("closeChangesConfirmation");QVERIFY(dialog);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Review"));QTRY_VERIFY(window->property("formToolActive").toBool());QVERIFY(reader->hasEditDrafts());QCOMPARE(workspace.activeReader(),reader);
        reader->setEditDraft("forms",{});reader->submit("bookmark_create",{{"page",0},{"title","Close save"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(source.open(QIODevice::Append));source.write("\n% external change\n");source.close();QVERIFY(source.open(QIODevice::ReadOnly));const auto external=source.readAll();source.close();
        workspace.closeTab(0);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Save"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!reader->error().isEmpty());QCOMPARE(workspace.activeReader(),reader);QVERIFY(reader->hasUnsavedChanges());QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),external);source.close();
        QVERIFY(source.open(QIODevice::WriteOnly));source.write(original);source.close();workspace.closeTab(0);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Save"));reader->setNoteDraft("late-note","Typed after Save was requested");
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QTRY_VERIFY(window->property("operationStatus").toString().contains("New changes"));QCOMPARE(workspace.activeReader(),reader);QVERIFY(reader->noteDrafts().contains("late-note"));
    }
    void signedCloseCopyCancellationAndSuccessProtectTheOriginal() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/signed.pdf",copy=scratch.path()+"/unsigned.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/signed-signature.pdf",path));QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();QTRY_VERIFY_WITH_TIMEOUT(reader->pageCount()>0,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("bookmark_create",{{"page",0},{"title","Unsigned copy bookmark"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *dialog=window->findChild<QObject *>("closeChangesConfirmation"),*save=window->findChild<QObject *>("documentSaveDialog");QVERIFY(dialog && save);workspace.closeTab(0);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Save"));QTRY_VERIFY(save->property("visible").toBool());
        QVERIFY(QMetaObject::invokeMethod(save,"rejected"));QVERIFY(QMetaObject::invokeMethod(save,"close"));QCOMPARE(workspace.activeReader(),reader);QVERIFY(reader->hasUnsavedChanges());
        QPointer<ReaderController> closing=reader;workspace.closeTab(0);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Save"));QTRY_VERIFY(save->property("visible").toBool());QVERIFY(QMetaObject::invokeMethod(window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(copy))));QTRY_VERIFY_WITH_TIMEOUT(closing.isNull(),15000);QMetaObject::invokeMethod(save,"close");
        QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(copy));QTRY_VERIFY_WITH_TIMEOUT(reopened.pageCount()>0,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QVERIFY(!reopened.data().value("signature_status").toMap().value("signed").toBool());QVERIFY(!reopened.hasUnsavedChanges());QCOMPARE(reopened.data().value("marks").toMap().value("bookmarks").toList().first().toMap().value("title").toString(),QString("Unsigned copy bookmark"));
    }
    void quitCollectsEveryWindowBeforeCancelOrDiscard() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());
        const auto firstPath=scratch.path()+"/quit-first.pdf",secondPath=scratch.path()+"/quit-second.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",firstPath));QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",secondPath));
        auto bytes=[](const QString &path){QFile file(path);return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};};
        const auto firstBytes=bytes(firstPath),secondBytes=bytes(secondPath);QVERIFY(!firstBytes.isEmpty() && !secondBytes.isEmpty());
        std::weak_ptr<LyraReaderDesktopDocument> documentA,documentB;
        {
        NativeCorpus::Viewer first,second,clean;QVERIFY(first.window && second.window && clean.window);
        if(qEnvironmentVariableIsSet("LYRA_READER_QUIT_DARK_NARROW")){first.window->setProperty("appearance","dark");first.window->resize(640,480);}
        first.workspace.openFile(QUrl::fromLocalFile(firstPath));second.workspace.openFile(QUrl::fromLocalFile(secondPath));
        auto *a=first.workspace.activeReader(),*b=second.workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(a->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(b->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(a->pendingCommands()+b->pendingCommands(),0,10000);
        documentA=a->documentHandle();documentB=b->documentHandle();
        a->submit("bookmark_create",{{"page",0},{"title","Discarded bookmark"},{"yPt",20}});
        b->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{1}},{"quarter_turns",1}}}}}});
        auto *quit=first.workspace.quitCoordinator();QSignalSpy accepted(quit,&QuitCoordinator::accepted);
        const auto cleanup=qScopeGuard([&]{quit->cancel();});
        first.workspace.requestQuit();QTRY_COMPARE_WITH_TIMEOUT(quit->phase(),QString("prompt"),15000);QCOMPARE(quit->documents().size(),2);
        auto *dialog=first.window->findChild<QObject *>("quitChangesConfirmation");QVERIFY(dialog);QTRY_VERIFY(dialog->property("opened").toBool());
        QCOMPARE(quit->documents()[0].toMap().value("title").toString(),a->title());QVERIFY(quit->documents()[1].toMap().value("summary").toString().contains("page edits"));
        const auto screenshot=qEnvironmentVariable("LYRA_READER_QUIT_SNAPSHOT");if(!screenshot.isEmpty())QVERIFY(first.window->grabWindow().save(screenshot));
        QVERIFY(!second.window->contentItem()->isEnabled());QVERIFY(clean.window->isVisible());
        QVERIFY(clickDialogButton(first.window,dialog,"Cancel"));QTRY_VERIFY(!quit->busy());QCOMPARE(accepted.count(),0);
        QVERIFY(first.window->isVisible() && second.window->isVisible() && clean.window->isVisible());QVERIFY(second.window->contentItem()->isEnabled());
        QVERIFY(a->hasUnsavedChanges() && b->hasUnsavedChanges());QCOMPARE(bytes(firstPath),firstBytes);QCOMPARE(bytes(secondPath),secondBytes);
        first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(first.window,dialog,"Discard All Changes"));
        QTRY_COMPARE_WITH_TIMEOUT(accepted.count(),1,15000);QVERIFY(!first.window->isVisible() && !second.window->isVisible() && !clean.window->isVisible());
        QCOMPARE(bytes(firstPath),firstBytes);QCOMPARE(bytes(secondPath),secondBytes);QVERIFY(a->hasUnsavedChanges() && b->hasUnsavedChanges());
        }
        // Simulate the next launch after the closed editor objects and their
        // outstanding workers have released the editable document handles.
        QTRY_VERIFY(documentA.expired() && documentB.expired());
        ReaderController reopenedA,reopenedB;reopenedA.openFile(QUrl::fromLocalFile(firstPath));reopenedB.openFile(QUrl::fromLocalFile(secondPath));
        QTRY_COMPARE_WITH_TIMEOUT(reopenedA.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopenedB.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reopenedA.pendingCommands()+reopenedB.pendingCommands(),0,10000);
        QVERIFY(reopenedA.data().value("marks").toMap().value("error").isNull());QVERIFY(reopenedB.data().value("marks").toMap().value("error").isNull());
        QVERIFY(!reopenedA.hasUnsavedChanges() && !reopenedB.hasUnsavedChanges());QVERIFY(reopenedA.data().value("marks").toMap().value("bookmarks").toList().isEmpty());QVERIFY(!reopenedB.data().value("marks").toMap().value("page_session_active").toBool());
    }
    void quitSavesInactiveTabsAndCollectsAllCopyDestinationsBeforeWriting() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/quit-normal.pdf",signedPath=scratch.path()+"/quit-signed.pdf",copyPath=scratch.path()+"/quit-copy.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));QVERIFY(QFile::copy(root+"/tests/fixtures/signed-signature.pdf",signedPath));
        auto bytes=[](const QString &path){QFile file(path);return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};};const auto original=bytes(path),signedBytes=bytes(signedPath);
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *normal=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(normal->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(normal->pendingCommands(),0,10000);normal->submit("bookmark_create",{{"page",0},{"title","Inactive tab saved"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(normal->pendingCommands(),0,10000);
        view.workspace.openFile(QUrl::fromLocalFile(signedPath));auto *signedReader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(signedReader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(signedReader->pendingCommands(),0,10000);signedReader->submit("bookmark_create",{{"page",0},{"title","Copy saved"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(signedReader->pendingCommands(),0,10000);
        auto *quit=view.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);
        auto *dialog=view.window->findChild<QObject *>("quitChangesConfirmation"),*picker=view.window->findChild<QObject *>("quitSaveCopyDialog");QVERIFY(dialog && picker);
        view.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(view.window,dialog,"Save All"));QTRY_COMPARE(quit->phase(),QString("copy"));QTRY_VERIFY(picker->property("visible").toBool());
        QCOMPARE(bytes(path),original);QCOMPARE(bytes(signedPath),signedBytes);QVERIFY(QMetaObject::invokeMethod(picker,"rejected"));QTRY_VERIFY(!quit->busy());QVERIFY(view.window->isVisible());QVERIFY(normal->hasUnsavedChanges() && signedReader->hasUnsavedChanges());QCOMPARE(view.workspace.activeReader(),signedReader);
        view.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("save");QTRY_COMPARE(quit->phase(),QString("copy"));quit->chooseCopy(QUrl::fromLocalFile(path));QTRY_VERIFY(!quit->busy());QVERIFY(quit->message().contains("open original"));QCOMPARE(bytes(path),original);QVERIFY(!QFile::exists(copyPath));
        view.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("save");QTRY_COMPARE(quit->phase(),QString("copy"));quit->chooseCopy(QUrl::fromLocalFile(copyPath));
        QTRY_COMPARE_WITH_TIMEOUT(accepted.count(),1,20000);QVERIFY(!view.window->isVisible());QCOMPARE(bytes(signedPath),signedBytes);QVERIFY(bytes(path)!=original);QVERIFY(QFile::exists(copyPath));
        ReaderController reopened,copy;reopened.openFile(QUrl::fromLocalFile(signedPath));copy.openFile(QUrl::fromLocalFile(copyPath));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(copy.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands()+copy.pendingCommands(),0,10000);QVERIFY(!reopened.hasUnsavedChanges());QVERIFY(reopened.data().value("marks").toMap().value("bookmarks").toList().isEmpty());QVERIFY(!copy.data().value("signature_status").toMap().value("signed").toBool());QCOMPARE(copy.data().value("marks").toMap().value("bookmarks").toList().first().toMap().value("title").toString(),QString("Copy saved"));
    }
    void quitDiscardFailureKeepsEveryDocumentDraftAndRecoveryBytes() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto one=scratch.filePath("quit-discard-one.pdf"),two=scratch.filePath("quit-discard-two.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",one));QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",two));
        NativeCorpus::Viewer first,second;QVERIFY(first.window && second.window);first.workspace.openFile(QUrl::fromLocalFile(one));second.workspace.openFile(QUrl::fromLocalFile(two));auto *a=first.workspace.activeReader(),*b=second.workspace.activeReader();QTRY_COMPARE(a->pageCount()+b->pageCount(),2);QTRY_COMPARE(a->pendingCommands()+b->pendingCommands(),0);
        for(auto *reader:{a,b})reader->submit("bookmark_create",{{"page",0},{"title","Keep the entire quit batch"},{"yPt",20}});QTRY_COMPARE(a->pendingCommands()+b->pendingCommands(),0);QVERIFY(a->hasUnsavedChanges() && b->hasUnsavedChanges());
        const auto read=[](const QString &path){QFile f(path);return f.open(QIODevice::ReadOnly)?f.readAll():QByteArray();};
        const auto aPath=a->data().value("marks").toMap().value("path").toString(),bPath=b->data().value("marks").toMap().value("path").toString();const auto aPending=QFileInfo(aPath).dir().filePath("changes.json"),bPending=QFileInfo(bPath).dir().filePath("changes.json");
        const auto aRecords=read(aPath),aState=read(aPending),bRecords=read(bPath),bState=read(bPending);QVERIFY(!aRecords.isEmpty() && !aState.isEmpty() && !bState.isEmpty());const auto pdfOne=read(one),pdfTwo=read(two);
        const auto external=bState+" \n";QFile changed(bPending);QVERIFY(changed.open(QIODevice::WriteOnly));QCOMPARE(changed.write(external),external.size());changed.close();
        auto *quit=first.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("discard");QTRY_VERIFY_WITH_TIMEOUT(!quit->busy(),15000);
        QCOMPARE(accepted.count(),0);QVERIFY(first.window->isVisible() && second.window->isVisible());QVERIFY2(a->hasUnsavedChanges(),"A later discard failure must not retire an earlier document draft");QVERIFY(b->hasUnsavedChanges());QCOMPARE(read(aPath),aRecords);QCOMPARE(read(aPending),aState);QCOMPARE(read(bPath),bRecords);QCOMPARE(read(bPending),external);QCOMPARE(read(one),pdfOne);QCOMPARE(read(two),pdfTwo);
    }
    void quitLateDraftCancelsTheExactCommittedBatchAndPreservesRecovery() {
        QTemporaryDir scratch;const auto path=scratch.filePath("quit-late-receipt.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE(reader->pageCount(),1);QTRY_COMPARE(reader->pendingCommands(),0);
        reader->submit("bookmark_create",{{"page",0},{"title","Recover after cancelled decision"},{"yPt",20}});QTRY_COMPARE(reader->pendingCommands(),0);QVERIFY(reader->hasUnsavedChanges());
        auto *quit=view.workspace.quitCoordinator();bool injected=false;const auto late=connect(quit,&QuitCoordinator::changed,&view.workspace,[&]{if(quit->phase()=="recording" && !injected){injected=true;reader->setNoteDraft("late","Keep this later draft");}});
        const auto cleanup=qScopeGuard([&]{disconnect(late);quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);view.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("discard");QTRY_VERIFY_WITH_TIMEOUT(!quit->busy(),15000);QVERIFY(injected);QCOMPARE(accepted.count(),0);QVERIFY(view.window->isVisible());QVERIFY(quit->message().contains("New changes"));QCOMPARE(reader->noteDrafts().value("late").toString(),QString("Keep this later draft"));
        ReaderController recovered;recovered.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(recovered.pageCount(),1);QTRY_COMPARE(recovered.pendingCommands(),0);QVERIFY(recovered.hasUnsavedChanges());QCOMPARE(recovered.data().value("marks").toMap().value("bookmarks").toList().size(),1);
    }
    void quitNewWorkspaceDuringRecordingCancelsWithoutClosingReaders() {
        QTemporaryDir scratch;const auto path=scratch.filePath("quit-new-workspace.pdf");QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE(reader->pageCount(),1);QTRY_COMPARE(reader->pendingCommands(),0);reader->submit("bookmark_create",{{"page",0},{"title","Retain while another reader is created"},{"yPt",20}});QTRY_COMPARE(reader->pendingCommands(),0);
        auto *quit=view.workspace.quitCoordinator();std::unique_ptr<WorkspaceController> lateWorkspace;
        const auto late=connect(quit,&QuitCoordinator::changed,&view.workspace,[&]{if(quit->phase()=="recording" && !lateWorkspace)lateWorkspace=std::make_unique<WorkspaceController>();});
        const auto cleanup=qScopeGuard([&]{disconnect(late);quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);view.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("discard");QTRY_VERIFY_WITH_TIMEOUT(!quit->busy(),15000);QVERIFY(lateWorkspace);QCOMPARE(accepted.count(),0);QVERIFY(view.window->isVisible());QVERIFY(reader->hasUnsavedChanges());
        ReaderController recovered;recovered.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE(recovered.pageCount(),1);QTRY_COMPARE(recovered.pendingCommands(),0);QVERIFY(recovered.hasUnsavedChanges());
    }
    void quitPreflightsDraftsAndReportsPartialSuccessWithoutClosingWindows() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto one=scratch.path()+"/quit-one.pdf",two=scratch.path()+"/quit-two.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",one));QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",two));
        NativeCorpus::Viewer first,second;QVERIFY(first.window && second.window);first.workspace.openFile(QUrl::fromLocalFile(one));second.workspace.openFile(QUrl::fromLocalFile(two));auto *a=first.workspace.activeReader(),*b=second.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(a->pageCount()+b->pageCount(),4,10000);QTRY_COMPARE_WITH_TIMEOUT(a->pendingCommands()+b->pendingCommands(),0,10000);
        for(auto *reader:{a,b})reader->submit("bookmark_create",{{"page",0},{"title","Keep unresolved"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(a->pendingCommands()+b->pendingCommands(),0,10000);
        a->submit("page_stage",{{"operation",QVariantMap{{"Rotate",QVariantMap{{"pages",QVariantList{0}},{"quarter_turns",1}}}}},{"current_page",0}});QTRY_COMPARE_WITH_TIMEOUT(a->pendingCommands(),0,10000);QTRY_VERIFY(!first.window->property("positionRestoring").toBool());QVERIFY(QMetaObject::invokeMethod(first.window,"navigate",Q_ARG(QVariant,2),Q_ARG(QVariant,40)));QTRY_COMPARE(first.window->property("currentPage").toInt(),2);QTRY_COMPARE_WITH_TIMEOUT(a->pendingCommands(),0,10000);
        QVERIFY(visualItem(first.window->contentItem(),"pdfPage2"));QVERIFY(QMetaObject::invokeMethod(first.window,"saveReadingPosition"));const auto anchor=first.workspace.viewState(a).value("viewportAnchor").toMap();QCOMPARE(anchor.value("page").toInt(),2);QVERIFY(anchor.contains("y"));
        auto *quit=first.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);
        b->setEditDraft("content",QVariantMap{{"text","Unfinished text"}});first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("save");QTRY_VERIFY(!quit->busy());QVERIFY(quit->message().contains("Review"));QVERIFY(a->hasUnsavedChanges() && b->hasUnsavedChanges());
        b->setEditDraft("content",{});first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));b->setNoteDraft("late-note","Do not lose this");quit->decide("discard");QTRY_VERIFY(!quit->busy());QVERIFY(quit->message().contains("changed"));QVERIFY(!b->noteDrafts().isEmpty());b->clearNoteDraft("late-note");
        const auto recordPath=b->data().value("marks").toMap().value("path").toString();QFile pending(QFileInfo(recordPath).dir().filePath("changes.json"));QVERIFY(pending.open(QIODevice::ReadOnly));const auto baseline=pending.readAll();pending.close();QVERIFY(pending.open(QIODevice::WriteOnly));const auto external=baseline+" \n";pending.write(external);pending.close();
        first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("save");QTRY_VERIFY_WITH_TIMEOUT(!quit->busy(),15000);QCOMPARE(accepted.count(),0);QVERIFY(first.window->isVisible() && second.window->isVisible());QVERIFY(!a->hasUnsavedChanges());QVERIFY(b->hasUnsavedChanges());QVERIFY(quit->message().contains("Earlier successful"));QVERIFY(second.window->contentItem()->isEnabled());QVERIFY(pending.open(QIODevice::ReadOnly));QCOMPARE(pending.readAll(),external);pending.close();QTRY_VERIFY(!first.window->property("positionRestoring").toBool());QCOMPARE(first.window->property("currentPage").toInt(),2);QVERIFY(QMetaObject::invokeMethod(first.window,"saveReadingPosition"));const auto after=first.workspace.viewState(a).value("viewportAnchor").toMap();QCOMPARE(after.value("page"),anchor.value("page"));QVERIFY2(qAbs(after.value("y").toDouble()-anchor.value("y").toDouble())<2,qPrintable(QString("before=%1 after=%2").arg(QString::fromUtf8(QJsonDocument::fromVariant(anchor).toJson(QJsonDocument::Compact)),QString::fromUtf8(QJsonDocument::fromVariant(after).toJson(QJsonDocument::Compact)))));
        QVERIFY(pending.open(QIODevice::WriteOnly));pending.write(baseline);pending.close();first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("discard");QTRY_COMPARE_WITH_TIMEOUT(accepted.count(),1,15000);
    }
    void quitResolutionAndCrashRecoverySurviveARealProcessBoundary() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto previous=qgetenv("LYRA_READER_DOCUMENT_CACHE_DIR");const auto restore=qScopeGuard([&]{qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",previous);});
        for(const QString mode:{"crash","discard","discard-event","save"}) {
            const auto path=scratch.path()+"/"+mode+".pdf",cache=scratch.path()+"/"+mode+"-cache";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));QFile file(path);QVERIFY(file.open(QIODevice::ReadOnly));const auto before=file.readAll();file.close();
            QProcess child;auto env=QProcessEnvironment::systemEnvironment();env.insert("QT_QPA_PLATFORM","offscreen");env.insert("QT_QUICK_BACKEND","software");env.remove("LYRA_READER_REQUIRE_NATIVE_QT");child.setProcessEnvironment(env);child.start(QCoreApplication::applicationFilePath(),{"--quit-recovery-child",mode,path,cache});QVERIFY(child.waitForStarted(5000));QVERIFY(child.waitForFinished(45000));QVERIFY2(child.exitCode()==9,child.readAllStandardError().constData());
            qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",cache.toUtf8());ReaderController reopened;reopened.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reopened.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reopened.pendingCommands(),0,10000);QVERIFY2(reopened.error().isEmpty(),qPrintable(reopened.error()));const auto marks=reopened.data().value("marks").toMap();
            QCOMPARE(reopened.hasUnsavedChanges(),mode=="crash");QCOMPARE(marks.value("page_session_active").toBool(),mode=="crash");
            if(mode.startsWith("discard"))QVERIFY(marks.value("bookmarks").toList().isEmpty());else QCOMPARE(marks.value("bookmarks").toList().first().toMap().value("title").toString(),QString("Process-boundary bookmark"));
            QVERIFY(file.open(QIODevice::ReadOnly));QCOMPARE(file.readAll()==before,mode!="save");file.close();
        }
    }
    void quitRejectsAmbiguousDuplicateSourcesAndReopenedReaderHandles() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/duplicates.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer first,second;QVERIFY(first.window && second.window);
        first.workspace.openFile(QUrl::fromLocalFile(path));auto *a=first.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(a->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(a->pendingCommands(),0,10000);a->submit("bookmark_create",{{"page",0},{"title","Two windows"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(a->pendingCommands(),0,10000);
        second.workspace.openFile(QUrl::fromLocalFile(path));auto *b=second.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(b->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(b->pendingCommands(),0,10000);QVERIFY(a->hasUnsavedChanges() && b->hasUnsavedChanges());
        auto *quit=first.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{quit->cancel();});first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("save");QTRY_VERIFY(!quit->busy());QVERIFY(quit->message().contains("more than one"));QVERIFY(a->hasUnsavedChanges() && b->hasUnsavedChanges());
        first.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));const auto old=b->documentHandle();b->openFile(QUrl::fromLocalFile(path));QTRY_VERIFY_WITH_TIMEOUT(!b->loading() && b->pendingCommands()==0 && b->hasUnsavedChanges(),10000);QVERIFY(old!=b->documentHandle());quit->decide("discard");QTRY_VERIFY(!quit->busy());QVERIFY(quit->message().contains("changed"));QVERIFY(a->hasUnsavedChanges() && b->hasUnsavedChanges());
    }
    void quitKeepsLateNotesWhenACopyCompletes() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/late-signed.pdf",copy=scratch.path()+"/late-copy.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/signed-signature.pdf",path));
        NativeCorpus::Viewer view;QVERIFY(view.window);view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("bookmark_create",{{"page",0},{"title","Saved copy"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        const auto late=connect(reader,&ReaderController::commandFinished,&view.workspace,[&](quint64,const QString &operation,const QVariant &,const QString &error){if(operation=="save_document_copy" && error.isEmpty())reader->setNoteDraft("late","New work after the copy started");});
        auto *quit=view.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{disconnect(late);quit->cancel();});QSignalSpy accepted(quit,&QuitCoordinator::accepted);
        view.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("save");QTRY_COMPARE(quit->phase(),QString("copy"));quit->chooseCopy(QUrl::fromLocalFile(copy));QTRY_VERIFY_WITH_TIMEOUT(!quit->busy(),15000);QCOMPARE(accepted.count(),0);QVERIFY(view.window->isVisible());QVERIFY(QFile::exists(copy));QCOMPARE(reader->noteDrafts().value("late").toString(),QString("New work after the copy started"));QVERIFY(reader->hasUnsavedChanges());QVERIFY(quit->message().contains("New changes"));QVERIFY(quit->message().contains("Earlier successful"));
    }
    void quitApplicationEventsUseTheFocusedReadersOwner() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/focused-owner.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",path));NativeCorpus::Viewer first,focused;QVERIFY(first.window && focused.window);first.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=first.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("bookmark_create",{{"page",0},{"title","Global quit"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        auto *quit=first.workspace.quitCoordinator();qApp->installEventFilter(quit);const auto cleanup=qScopeGuard([&]{quit->cancel();qApp->removeEventFilter(quit);});focused.window->requestActivate();QTRY_COMPARE(QGuiApplication::focusWindow(),focused.window);
        QEvent event(QEvent::Quit);QCoreApplication::sendEvent(qApp,&event);QTRY_COMPARE(quit->phase(),QString("prompt"));QCOMPARE(quit->owner(),&focused.workspace);QCOMPARE(quit->documents().size(),1);auto *dialog=focused.window->findChild<QObject *>("quitChangesConfirmation");QVERIFY(dialog);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(focused.window,dialog,"Cancel"));QTRY_VERIFY(!quit->busy());QVERIFY(first.window->isVisible() && focused.window->isVisible());QVERIFY(reader->hasUnsavedChanges());
    }
    void quitWaitsForTheLastCopyPanelBeforeWritingAnyPdf() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());NativeCorpus::Viewer view;QVERIFY(view.window);QList<ReaderController *> readers;
        for(int i=0;i<2;++i){const auto path=scratch.path()+QString("/signed-%1.pdf").arg(i);QVERIFY(QFile::copy(root+"/tests/fixtures/signed-signature.pdf",path));view.workspace.openFile(QUrl::fromLocalFile(path));auto *reader=view.workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);reader->submit("bookmark_create",{{"page",0},{"title",QString("Copy %1").arg(i)},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);readers.append(reader);}
        auto *quit=view.workspace.quitCoordinator();const auto cleanup=qScopeGuard([&]{quit->cancel();});QSignalSpy copies(quit,&QuitCoordinator::copyRequested);view.workspace.requestQuit();QTRY_COMPARE(quit->phase(),QString("prompt"));quit->decide("save");QTRY_COMPARE(copies.count(),1);auto *picker=view.window->findChild<QObject *>("quitSaveCopyDialog");QVERIFY(picker);QTRY_VERIFY(picker->property("visible").toBool());
        const auto firstCopy=scratch.path()+"/copy-0.pdf";QVERIFY(picker->setProperty("currentFile",QUrl::fromLocalFile(firstCopy)));QVERIFY(QMetaObject::invokeMethod(picker,"accept"));QTRY_COMPARE(copies.count(),2);QTRY_VERIFY(picker->property("visible").toBool());QVERIFY(!QFile::exists(firstCopy));QVERIFY(QMetaObject::invokeMethod(picker,"reject"));QTRY_VERIFY(!quit->busy());QVERIFY(!QFile::exists(firstCopy));QVERIFY(view.window->isVisible());for(auto *reader:readers)QVERIFY(reader->hasUnsavedChanges());
    }
    void windowCloseReviewsEachDirtyTabAndCancelKeepsTheRemainder() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto firstPath=scratch.path()+"/first.pdf",secondPath=scratch.path()+"/second.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",firstPath));QVERIFY(QFile::copy(root+"/tests/fixtures/text-page.pdf",secondPath));
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        workspace.openFile(QUrl::fromLocalFile(firstPath));auto *first=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(first->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);first->submit("bookmark_create",{{"page",0},{"title","Discard first"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(first->pendingCommands(),0,10000);
        workspace.openFile(QUrl::fromLocalFile(secondPath));auto *second=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(second->pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);second->submit("bookmark_create",{{"page",0},{"title","Save second"},{"yPt",20}});QTRY_COMPARE_WITH_TIMEOUT(second->pendingCommands(),0,10000);
        auto *dialog=window->findChild<QObject *>("closeChangesConfirmation");QVERIFY(dialog);QPointer<ReaderController> firstClosing=first;QVERIFY(QMetaObject::invokeMethod(window,"close"));QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Discard"));QTRY_VERIFY_WITH_TIMEOUT(firstClosing.isNull(),10000);QTRY_COMPARE(workspace.tabs().size(),1);QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(QMetaObject::invokeMethod(dialog,"reject"));QVERIFY(window->isVisible());QCOMPARE(workspace.activeReader(),second);QVERIFY(second->hasUnsavedChanges());
        QPointer<ReaderController> secondClosing=second;QVERIFY(QMetaObject::invokeMethod(window,"close"));QTRY_VERIFY(dialog->property("opened").toBool());QVERIFY(clickDialogButton(window,dialog,"Save"));QTRY_VERIFY_WITH_TIMEOUT(secondClosing.isNull(),15000);QTRY_VERIFY(!window->isVisible());
        ReaderController untouched;untouched.openFile(QUrl::fromLocalFile(firstPath));QTRY_COMPARE_WITH_TIMEOUT(untouched.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(untouched.pendingCommands(),0,10000);QVERIFY(untouched.data().value("marks").toMap().value("bookmarks").toList().isEmpty());
        ReaderController saved;saved.openFile(QUrl::fromLocalFile(secondPath));QTRY_COMPARE_WITH_TIMEOUT(saved.pageCount(),1,10000);QTRY_COMPARE_WITH_TIMEOUT(saved.pendingCommands(),0,10000);QVERIFY(!saved.hasUnsavedChanges());QCOMPARE(saved.data().value("marks").toMap().value("bookmarks").toList().first().toMap().value("title").toString(),QString("Save second"));
    }
    void unifiedSaveCombinesTheActiveRevisionAndDraftsAndReopensRenderedContent() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/save.pdf",copy=scratch.path()+"/copy.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/form-fields.pdf",path));QFile source(path);QVERIFY(source.open(QIODevice::ReadOnly));const auto original=source.readAll();source.close();
        WorkspaceController workspace;auto *reader=workspace.activeReader();QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("page_stage",{{"operation",QVariantMap{{"InsertBlank",QVariantMap{{"index",0}}}}}});QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        reader->submit("mark_create",{{"entry",QVariantMap{{"kind","square"},{"version",1},{"page",1},{"rect",QVariantMap{{"x",20},{"y",50},{"width",80},{"height",40}}},{"strokeWidth",2},{"color","#E8BC5580"},{"note","Unified shape"}}}});
        reader->submit("bookmark_create",{{"page",1},{"title","Unified bookmark"},{"yPt",20}});reader->submit("forms");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QVariantMap field;for(const auto &entry:reader->data().value("forms").toMap().value("fields").toList())if(entry.toMap().value("kind")==QString("text")){field=entry.toMap();break;}QVERIFY(!field.isEmpty());
        QVERIFY(QMetaObject::invokeMethod(window,"updateFormValue",Q_ARG(QVariant,field.value("id")),Q_ARG(QVariant,(QVariantMap{{"text","Unified Qt form"}}))));
        const auto drafts=reader->editDrafts().value("forms").toMap();QVariantList forms;for(const auto &entry:drafts)forms.append(entry);
        window->setProperty("exportContext",QVariantMap{{"reader",QVariant::fromValue(reader)},{"revision",reader->data().value("document_revision")},{"kind","document"},{"forms",forms}});
        QVERIFY(QMetaObject::invokeMethod(window,"exportTo",Q_ARG(QVariant,QUrl::fromLocalFile(copy))));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));QVERIFY(reader->hasEditDrafts());
        ReaderController copied;copied.openFile(QUrl::fromLocalFile(copy));QTRY_COMPARE_WITH_TIMEOUT(copied.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(copied.pendingCommands(),0,10000);QCOMPARE(copied.data().value("annotations").toList().size(),1);
        QVERIFY(source.open(QIODevice::ReadOnly));QCOMPARE(source.readAll(),original);source.close();
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,1),Q_ARG(QVariant,120)));QTRY_COMPARE(window->property("currentPage").toInt(),1);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!window->property("positionRestoring").toBool());
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto beforeSave=workspace.viewState(reader);
        auto *action=window->findChild<QObject *>("saveDocumentAction");QVERIFY(action);QTRY_VERIFY(action->property("enabled").toBool());QVERIFY(QMetaObject::invokeMethod(action,"trigger"));
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,15000);QTRY_VERIFY(reader->editDrafts().isEmpty());QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QVERIFY(!reader->data().value("marks").toMap().value("page_session_active").toBool());QCOMPARE(reader->pageCount(),3);QTRY_COMPARE(window->property("currentPage").toInt(),1);
        QTRY_VERIFY(!window->property("positionRestoring").toBool());QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));
        QVERIFY(qAbs(workspace.viewState(reader).value("offset").toDouble()-beforeSave.value("offset").toDouble())<2.0);
        reader->submit("annotations");reader->submit("forms");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->data().value("annotations").toList().size(),1);
        bool filled=false;for(const auto &entry:reader->data().value("forms").toMap().value("fields").toList())filled|=entry.toMap().value("value")==QString("Unified Qt form");QVERIFY(filled);
        const auto result=reader->data().value("marks").toMap();QVERIFY(result.value("annotations").toList().isEmpty());QCOMPARE(result.value("bookmarks").toList().first().toMap().value("page").toInt(),1);
        reader->openFile(QUrl::fromLocalFile(root+"/tests/fixtures/xfa-refusal.pdf"));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(reader->pageCount()>0);
        QVERIFY(reader->data().value("xfa_status").toMap().value("is_xfa").toBool());QVERIFY(!action->property("enabled").toBool());
        auto *saveAs=window->findChild<QObject *>("saveDocumentAsAction");QVERIFY(saveAs);QVERIFY(!saveAs->property("enabled").toBool());
    }
    void recoveredPageSessionsRestoreLocationAndDiscardBeforeTabClosure() {
        QTemporaryDir scratch;QVERIFY(scratch.isValid());const auto path=scratch.path()+"/recovery.pdf";
        QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        QFile original(path);QVERIFY(original.open(QIODevice::ReadOnly));const auto bytes=original.readAll();original.close();
        {
            ReaderController interrupted;interrupted.openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(interrupted.pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(interrupted.pendingCommands(),0,10000);
            interrupted.submit("page_stage",{{"operation",QVariantMap{{"Move",QVariantMap{{"pages",QVariantList{2}},{"destination",0}}}}},{"current_page",2},{"selected_pages",QVariantList{0,2}}});
            QTRY_COMPARE_WITH_TIMEOUT(interrupted.pendingCommands(),0,10000);QVERIFY2(interrupted.error().isEmpty(),qPrintable(interrupted.error()));
            interrupted.submit("page_stage",{{"operation",QVariantMap{{"Delete",QVariantMap{{"pages",QVariantList{1}}}}}},{"current_page",1},{"selected_pages",QVariantList{1,2}}});
            QTRY_COMPARE_WITH_TIMEOUT(interrupted.pendingCommands(),0,10000);QCOMPARE(interrupted.pageCount(),2);
        }
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());
        auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);workspace.openFile(QUrl::fromLocalFile(path));auto *reader=workspace.activeReader();
        QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY2(reader->error().isEmpty(),qPrintable(reader->error()));
        QTRY_VERIFY(!window->property("positionRestoring").toBool());QCOMPARE(window->property("currentPage").toInt(),1);
        QVERIFY(reader->data().value("marks").toMap().value("can_page_undo").toBool());
        reader->submit("page_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QCOMPARE(reader->pageCount(),3);
        QTRY_COMPARE(window->property("selectedPages").toList(),QVariantList({1,2}));
        // Even a session whose undo reaches the original must be retired on explicit discard.
        reader->submit("page_undo");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QVERIFY(!reader->data().value("marks").toMap().value("page_pending").toBool());
        QVERIFY(reader->data().value("marks").toMap().value("page_session_active").toBool());
        reader->setEditDraft("forms",QVariantMap{{"dummy",true}});
        QPointer<ReaderController> closing=reader;
        QVERIFY(QMetaObject::invokeMethod(window,"discardAndClose",Q_ARG(QVariant,0)));
        QTRY_VERIFY_WITH_TIMEOUT(closing.isNull(),10000);
        workspace.openFile(QUrl::fromLocalFile(path));reader=workspace.activeReader();QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(!reader->data().value("marks").toMap().value("page_session_active").toBool());
        QVERIFY(reader->data().value("recovery").toMap().isEmpty());
        QVERIFY(original.open(QIODevice::ReadOnly));QCOMPARE(original.readAll(),bytes);
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
    if(argc>1 && QByteArray(argv[1])=="--quit-recovery-child")return quitRecoveryChild(argc,argv);
    if(argc>1 && QByteArray(argv[1])=="--region-autosave-crash-child")return regionAutosaveCrashChild(argc,argv);
    QTemporaryDir documentCacheDirectory;
    if(!documentCacheDirectory.isValid())return 2;
    qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",documentCacheDirectory.path().toUtf8());
    qputenv("LYRA_READER_INDEX_CACHE","disabled");
    QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
    QApplication application(argc, argv);
    application.setQuitOnLastWindowClosed(false);
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/LyraReaderSansSC-Regular.ttf"));
    QCoreApplication::setOrganizationName("LyraReaderChecks");
    QCoreApplication::setApplicationName("LyraReaderChecks");
    QGuiApplication::setDesktopFileName("com.alex.LyraReaderChecks");
    QTemporaryDir settingsDirectory;
    if(!settingsDirectory.isValid())return 2;
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat,QSettings::UserScope,qEnvironmentVariable("LYRA_READER_CHECK_SETTINGS_ROOT",settingsDirectory.path()));
    QQuickStyle::setStyle("Fusion");
    if (argc < 2) return 2;
    ReaderChecks checks;
    checks.root = QDir(QString::fromLocal8Bit(argv[1])).absolutePath();
    // Remove the fixture root; preserve QTest's optional function/filter arguments.
    QList<char *> testArguments{argv[0]};
    for(int i=2;i<argc;++i) {
        if(QByteArray(argv[i])!="--graphics"){testArguments.append(argv[i]);continue;}
        if(!checks.graphicsBackend.isEmpty() || i+1>=argc){qCritical("Specify --graphics once, followed by auto, vulkan, opengl or software.");return 2;}
        checks.graphicsBackend=QString::fromLocal8Bit(argv[++i]);
        if(checks.graphicsBackend=="vulkan")QQuickWindow::setGraphicsApi(QSGRendererInterface::Vulkan);
        else if(checks.graphicsBackend=="opengl")QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
        else if(checks.graphicsBackend=="software")QQuickWindow::setSceneGraphBackend(QStringLiteral("software"));
        else if(checks.graphicsBackend!="auto"){qCritical("Unknown graphics backend. Use auto, vulkan, opengl or software.");return 2;}
    }
    return QTest::qExec(&checks,int(testArguments.size()),testArguments.data());
}
#include "ReaderChecks.moc"
