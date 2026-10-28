#include "DisplayCalibration.h"
#include "AuxiliaryWindowPolicy.h"
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
#include <QPainter>
#include "AnnotationOverlay.h"
#include "WorkspaceController.h"
#include <QApplication>
#include <QClipboard>
#include <QAccessible>
#include <QFontDatabase>
#include <QDir>
#include <QSignalSpy>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QJSValue>
#include <QUrlQuery>
#include <QInputMethodEvent>
#include <QProcess>
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

class ReaderChecks : public QObject {
    Q_OBJECT
public:
    QString root;
private slots:
    void initTestCase() {
        QCOMPARE(lyra_reader_desktop_abi_version(),LYRA_READER_DESKTOP_ABI_VERSION);
        qInfo() << "Qt test platform:" << QGuiApplication::platformName();
        if (qEnvironmentVariableIsSet("LYRA_READER_REQUIRE_NATIVE_QT")) {
            QVERIFY(QGuiApplication::platformName() == "wayland" || QGuiApplication::platformName() == "xcb");
        }
        qmlRegisterUncreatableType<ReaderController>("LyraReader", 1, 0, "ReaderController", "Created by host");
        qmlRegisterType<DisplayCalibration>("LyraReader",1,0,"DisplayCalibration");
        qmlRegisterType<AuxiliaryWindowPolicy>("LyraReader",1,0,"AuxiliaryWindowPolicy");
        qmlRegisterType<PageItem>("LyraReader", 1, 0, "PdfPage");
        qmlRegisterType<CropItem>("LyraReader",1,0,"PdfCrop");
        qmlRegisterType<AnnotationOverlay>("LyraReader",1,0,"PdfAnnotations");
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
        auto *snapshot=qobject_cast<ReaderController *>(children[1]->property("previewReader").value<QObject *>());QVERIFY(snapshot);std::weak_ptr<NativeRasterSource> lifetime=snapshot->renderSource();snapshot->requestText(0);QVERIFY(snapshot->pendingCommands()>0);window->hide();QTRY_VERIFY_WITH_TIMEOUT(children[1].isNull(),10000);QTRY_VERIFY_WITH_TIMEOUT(lifetime.expired(),10000);
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
    void settingsAreIndependentTransientWindowsWithSafeReopenAndOwnerLifetime() {
        WorkspaceController workspace;QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",workspace.activeReader());engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        auto *settings=window->findChild<QQuickWindow *>("settingsWindow");QVERIFY(settings);QVERIFY(!settings->isVisible());bool preparedAtFirstShow=false;
        connect(settings,&QWindow::visibleChanged,this,[&](bool shown){if(shown)preparedAtFirstShow=settings->transientParent()==window && settings->type()==Qt::Dialog && settings->modality()==Qt::NonModal;});
        workspace.setPreference("auxiliarySettingsGeometry",QVariantMap{{"width",1e300},{"height",-10},{"x",-1e300},{"y",1e300}});
        QVERIFY(QMetaObject::invokeMethod(window,"showSettings"));QTRY_VERIFY(settings->isVisible());QVERIFY(preparedAtFirstShow);QVERIFY(settings->minimumWidth()<settings->maximumWidth());QVERIFY(settings->minimumHeight()<settings->maximumHeight());
        const auto available=settings->screen()->availableGeometry();QVERIFY(settings->width()<=available.width());QVERIFY(settings->height()<=available.height());QVERIFY(!(settings->flags() & Qt::WindowStaysOnTopHint));
        if(qEnvironmentVariableIsSet("LYRA_READER_CHECK_AUX_OBSERVE"))QTest::qWait(1800);
        if(qEnvironmentVariableIsSet("LYRA_READER_CHECK_AUX_SNAPSHOT")){QTest::qWait(80);QVERIFY(settings->grabWindow().save(qEnvironmentVariable("LYRA_READER_CHECK_AUX_SNAPSHOT")));}
        auto *url=settings->findChild<QObject *>("settingsBaseUrl");auto *key=settings->findChild<QObject *>("settingsApiKey");QVERIFY(url && key);url->setProperty("text","http://127.0.0.1:1/cancelled");key->setProperty("text","synthetic-local-draft");QVERIFY(settings->close());QTRY_VERIFY(!settings->isVisible());QVERIFY(key->property("text").toString().isEmpty());
        QVERIFY(QMetaObject::invokeMethod(window,"showSettings"));QTRY_VERIFY(settings->isVisible());QVERIFY(url->property("text").toString()!="http://127.0.0.1:1/cancelled");
        const auto newSize=QSize(qMax(settings->minimumWidth(),settings->width()-40),qMax(settings->minimumHeight(),settings->height()-30));settings->resize(newSize);QTRY_COMPARE(settings->size(),newSize);QVERIFY(settings->close());
        QVERIFY(QMetaObject::invokeMethod(window,"showSettings"));QTRY_VERIFY(settings->isVisible());QCOMPARE(settings->size(),newSize);url->setProperty("text","http://127.0.0.1:1/saved");QVERIFY(QMetaObject::invokeMethod(settings,"save"));QTRY_VERIFY(!settings->isVisible());QCOMPARE(workspace.preference("ai").toMap().value("baseUrl").toString(),QString("http://127.0.0.1:1/saved"));
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
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,0)));QTRY_COMPARE(window->property("currentPage").toInt(),6);
        QVERIFY(QMetaObject::invokeMethod(window,"actualSize"));const auto factor=window->property("calibrationFactor").toDouble();
        QVERIFY(std::abs(window->property("zoom").toDouble()-factor)<1e-9);QVERIFY(std::abs(window->property("zoomPercent").toDouble()-100)<1e-9);
        QVERIFY(QMetaObject::invokeMethod(window,"zoomBy",Q_ARG(QVariant,1.2)));QVERIFY(std::abs(window->property("zoomPercent").toDouble()-110)<1e-9);
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));QVERIFY(std::abs(workspace.viewState(reader).value("zoomPercent").toDouble()-110)<1e-9);
        QVERIFY(QMetaObject::invokeMethod(window,"fitPage"));QTRY_COMPARE(window->property("currentPage").toInt(),6);QCOMPARE(window->property("fitPreset").toString(),QStringLiteral("page"));
        const double fit=window->property("zoom").toDouble();auto *view=visualItem(window->contentItem(),"pageList");QVERIFY(view);
        const auto page=reader->pages().at(6).toMap();QVERIFY(page.value("height").toDouble()*fit<=view->height()-16+.01);
        QVERIFY(QMetaObject::invokeMethod(window,"fitPage"));QCOMPARE(window->property("zoom").toDouble(),fit);QCOMPARE(window->property("currentPage").toInt(),6);
        QVERIFY(QMetaObject::invokeMethod(window,"saveReadingPosition"));const auto saved=workspace.viewState(reader);QCOMPARE(saved.value("fitPreset").toString(),QStringLiteral("page"));
        workspace.newTab();workspace.selectTab(0);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);QTRY_VERIFY(!window->property("positionRestoring").toBool());
        QCOMPARE(window->property("fitPreset").toString(),QStringLiteral("page"));QCOMPARE(window->property("currentPage").toInt(),6);
        QVERIFY(QMetaObject::invokeMethod(window,"fitWidth"));QCOMPARE(window->property("fitPreset").toString(),QStringLiteral("width"));
        QVERIFY(QMetaObject::invokeMethod(window,"setPageLayout",Q_ARG(QVariant,QStringLiteral("Facing"))));QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,6),Q_ARG(QVariant,0)));QVERIFY(QMetaObject::invokeMethod(window,"fitWidth"));
        const auto placements=reader->pages();const double top=placements.at(6).toMap().value("top").toDouble();double left=1e9,right=-1e9;
        for(const auto &entry:placements){const auto p=entry.toMap();if(std::abs(p.value("top").toDouble()-top)<.01){left=std::min(left,p.value("left").toDouble());right=std::max(right,p.value("left").toDouble()+p.value("width").toDouble());}}
        QVERIFY((right-left)*window->property("zoom").toDouble()<=view->width()-64+.01);
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
        window->setProperty("fitting",false);window->setProperty("paperAppearance","original");
        QVERIFY(QMetaObject::invokeMethod(window,"changeZoom",Q_ARG(QVariant,1.0),Q_ARG(QVariant,0),Q_ARG(QVariant,0)));
        QVERIFY(QMetaObject::invokeMethod(window,"navigate",Q_ARG(QVariant,0),Q_ARG(QVariant,0)));QTest::qWait(150);
        const auto point=[&](double x,double y){return visualItem(window->contentItem(),"pdfPage0")->mapToScene(QPointF(x,y)).toPoint();};
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
        QCOMPARE(artworkItem(),crop);QCOMPARE(crop->parentItem()->x(),rect.value("x").toDouble());
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
        const auto frame=window->grabWindow();QVERIFY(!frame.isNull());
        const auto pixel=[&](double x,double y){const auto p=point(x,y);return frame.pixelColor(qRound(p.x()*frame.width()/double(window->width())),qRound(p.y()*frame.height()/double(window->height())));};
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
    void documentQuestionUsesRetrievedSourcesAndRejectsUnsentCitations() {
        MockChatServer server;QVERIFY(server.listen());server.responses.append({{MockChatServer::delta({{"content","Document answer [p.1], invented [p.99], invalid [p.0]."}}),MockChatServer::usage(),QByteArray("data: [DONE]\n\n")},20,200});
        QTemporaryDir scratch;const auto path=scratch.path()+"/question.pdf";QVERIFY(QFile::copy(root+"/tests/fixtures/multipage.pdf",path));
        WorkspaceController workspace;auto *reader=workspace.activeReader();QQmlApplicationEngine engine;engine.addImageProvider("lyrapreview",new NativeImageProvider);engine.rootContext()->setContextProperty("workspace",&workspace);engine.rootContext()->setContextProperty("reader",reader);engine.load(QUrl("qrc:/qml/Main.qml"));QVERIFY(!engine.rootObjects().isEmpty());auto *window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());QVERIFY(window);
        reader->openFile(QUrl::fromLocalFile(path));QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
        window->setProperty("aiSettings",QVariantMap{{"baseUrl",server.baseUrl()},{"model","fixture"}});reader->setAiInput("action",4);reader->setAiInput("question",QStringLiteral("Which page contains body text and caching?"));
        auto *panel=window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY2_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),qPrintable(reader->aiState().value("status").toString()),10000);const auto plan=reader->aiState().value("plan").toMap();QCOMPARE(plan.value("action").toString(),QStringLiteral("DocumentChat"));const auto sources=plan.value("sources").toList();QVERIFY(!sources.isEmpty());QCOMPARE(server.requests.size(),0);
        const auto wireBody=plan.value("parts").toList().first().toMap().value("wire_body").toString().toUtf8();QVERIFY(!wireBody.isEmpty());
        auto *payload=window->findChild<QObject *>("aiWirePayload");QVERIFY(payload);QCOMPARE(payload->property("text").toString().toUtf8(),wireBody);
        QVERIFY(reader->startAi("local",plan));QTRY_VERIFY_WITH_TIMEOUT(!reader->aiState().value("running").toBool(),10000);QVERIFY(reader->aiState().value("output").toString().contains("Document answer"));
        QCOMPARE(server.requests.size(),1);const auto sent=server.requests.first();const auto headerEnd=sent.indexOf("\r\n\r\n");QVERIFY(headerEnd>=0);QCOMPARE(sent.mid(headerEnd+4),wireBody);
        reader->setAiInput("question",QStringLiteral("A changed question"));QVERIFY(!reader->aiState().contains("plan"));
        const int page=sources.first().toMap().value("page").toInt();QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QString("p.%1").arg(page))));QTRY_COMPARE(window->property("currentPage").toInt(),page-1);
        QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QStringLiteral("p.99"))));QVERIFY(window->property("operationStatus").toString().contains("cannot be verified"));QCOMPARE(window->property("currentPage").toInt(),page-1);
        QVERIFY(QMetaObject::invokeMethod(panel,"followLink",Q_ARG(QVariant,QStringLiteral("p.0"))));QCOMPARE(window->property("currentPage").toInt(),page-1);
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
        auto *panel=window->findChild<QObject *>("aiPanel");QVERIFY(panel);QVERIFY(QMetaObject::invokeMethod(panel,"prepare"));QTRY_VERIFY2_WITH_TIMEOUT(!reader->aiState().value("plan").toMap().isEmpty(),qPrintable(reader->aiState().value("status").toString()),10000);QCOMPARE(server.requests.size(),0);
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
                    {"requestedBackend",qEnvironmentVariable("QSG_RHI_BACKEND")},{"windowActive",window->isActive()},{"windowExposed",window->isExposed()},
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
        QVariantMap report{{"schema",2},{"phase","bursts"},{"qt",qVersion()},{"platform",QGuiApplication::platformName()},{"graphicsApi",int(window->rendererInterface()->graphicsApi())},{"requestedBackend",qEnvironmentVariable("QSG_RHI_BACKEND")},
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
    QTemporaryDir documentCacheDirectory;
    if(!documentCacheDirectory.isValid())return 2;
    qputenv("LYRA_READER_DOCUMENT_CACHE_DIR",documentCacheDirectory.path().toUtf8());
    QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
    QApplication application(argc, argv);
    application.setQuitOnLastWindowClosed(false);
    QFontDatabase::addApplicationFont(QStringLiteral(":/fonts/LyraReaderSansSC-Regular.ttf"));
    QCoreApplication::setOrganizationName("LyraReaderChecks");
    QCoreApplication::setApplicationName("LyraReaderChecks");
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
    for(int i=2;i<argc;++i)testArguments.append(argv[i]);
    return QTest::qExec(&checks,int(testArguments.size()),testArguments.data());
}
#include "ReaderChecks.moc"
