#pragma once
#include "WorkspaceController.h"
#include "NativeRaster.h"
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QQuickItem>
#include <QSaveFile>
#include <QTemporaryDir>
#include <QtTest>

namespace NativeCorpus {
inline QQuickItem *item(QQuickItem *root,const QString &name) {
    if(root->objectName()==name)return root;
    for(auto *child:root->childItems())if(auto *found=item(child,name))return found;
    return nullptr;
}
struct Viewer {
    WorkspaceController workspace;
    QQmlApplicationEngine engine;
    QQuickWindow *window=nullptr;
    Viewer() {
        // Tests never launch a browser for a source PDF's external link.
        QObject::disconnect(workspace.preview(),&PreviewController::externalRequested,&workspace,&WorkspaceController::openExternal);
        engine.addImageProvider("lyrapreview",new NativeImageProvider);
        engine.rootContext()->setContextProperty("workspace",&workspace);
        engine.rootContext()->setContextProperty("reader",workspace.activeReader());
        engine.load(QUrl("qrc:/qml/Main.qml"));
        if(!engine.rootObjects().isEmpty())window=qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    }
    bool cropReady()const {const auto *crop=window?item(window->contentItem(),"referencePreviewImage"):nullptr;return crop && crop->property("status").toInt()==1;}
};

inline bool textEvidence(Viewer &view,const QString &stem) {
    const auto directory=qEnvironmentVariable("LYRA_READER_CORPUS_SNAPSHOTS");
    if(directory.isEmpty())return true;
    return QDir().mkpath(directory) && view.window->grabWindow().save(directory+"/"+stem+"-qt-text.png");
}
inline bool cropEvidence(Viewer &view,const QString &stem) {
    auto *crop=item(view.window->contentItem(),"referencePreviewImage");if(!crop)return false;
    const auto frame=view.window->grabWindow();if(frame.isNull())return false;
    const auto bounds=crop->mapRectToScene(QRectF(0,0,crop->width(),crop->height()));
    const qreal sx=qreal(frame.width())/view.window->width(),sy=qreal(frame.height())/view.window->height();
    const auto rect=QRectF(bounds.x()*sx,bounds.y()*sy,bounds.width()*sx,bounds.height()*sy).toAlignedRect().intersected(frame.rect());
    const auto image=frame.copy(rect);int ink=0,paper=0;
    for(int y=0;y<image.height();++y)for(int x=0;x<image.width();++x){const auto c=image.pixelColor(x,y);if(c.red()<80 && c.green()<80 && c.blue()<80)++ink;if(c.red()>245 && c.green()>245 && c.blue()>245)++paper;}
    if(ink<10 || paper<100)return false;
    const auto directory=qEnvironmentVariable("LYRA_READER_CORPUS_SNAPSHOTS");
    if(directory.isEmpty())return true;
    return QDir().mkpath(directory) && frame.save(directory+"/"+stem+"-qt-popup.png") && image.save(directory+"/"+stem+"-qt-crop.png");
}

inline void coldNarrativeAndTablePreviews(const QString &root) {
    QTemporaryDir scratch;QVERIFY(scratch.isValid());
    for(const auto &name:{"narrative-citation.pdf","booktabs-bounds.pdf"})QVERIFY(QFile::copy(root+"/tests/fixtures/"+name,scratch.path()+"/"+name));
    Viewer view;QVERIFY(view.window);view.window->setProperty("paperAppearance","original");auto *preview=view.workspace.preview();
    view.workspace.openFile(QUrl::fromLocalFile(scratch.path()+"/narrative-citation.pdf"));auto *reader=view.workspace.activeReader();
    QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),2,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
    // Actual year-only link bounds, before references/citations/figures were queried.
    const auto yearY=reader->pages().first().toMap().value("height").toDouble()-694;
    preview->openAt(reader,0,144,yearY,320,200,1);
    auto *panel=view.window->findChild<QObject *>("referencePreviewPanel");QVERIFY(panel);panel->setProperty("preferredWidth",680);
    QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);QCOMPARE(preview->model().value("kind").toString(),QString("reference"));
    const auto entries=preview->model().value("entries").toList();QCOMPARE(entries.size(),1);QVERIFY(entries.first().toMap().value("text").toString().contains("Chuan Guo"));
    QVERIFY(textEvidence(view,"narrative-citation"));preview->showEntry(0);QTRY_VERIFY_WITH_TIMEOUT(view.cropReady(),10000);QVERIFY(cropEvidence(view,"narrative-citation"));
    preview->close();preview->openAt(reader,0,144,yearY,320,200,1);preview->close();QTest::qWait(100);QVERIFY(!preview->visible());QVERIFY(!preview->loading());
    view.workspace.openFile(QUrl::fromLocalFile(scratch.path()+"/booktabs-bounds.pdf"));reader=view.workspace.activeReader();
    QTRY_COMPARE_WITH_TIMEOUT(reader->pageCount(),3,10000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);
    const auto height=reader->pages().first().toMap().value("height").toDouble();
    for(int row=0;row<2;++row) {
        preview->openAt(reader,0,125,height-693.5+row*15,320,200,1);
        QTRY_VERIFY_WITH_TIMEOUT(preview->visible(),10000);QCOMPARE(preview->model().value("kind").toString(),QString("figure"));
        const auto region=preview->model().value("region").toMap();const auto width=region.value("width_pt").toDouble();
        QVERIFY(region.value("y_pt").toDouble()<height-695);QVERIFY(region.value("y_pt").toDouble()+region.value("height_pt").toDouble()<height-577);
        QVERIFY(row==0 ? width>420 && width<500 : width>260 && width<330);
        QTRY_VERIFY_WITH_TIMEOUT(view.cropReady(),10000);QVERIFY(cropEvidence(view,QString("booktabs-%1").arg(row+1)));preview->close();
    }
}

inline void realPapers(const QString &root) {
    if(!qEnvironmentVariableIsSet("LYRA_READER_CHECK_CORPUS"))QSKIP("Opt-in three-paper native corpus; fetch the locked 1512.03385, 1706.03762, 2303.08774 PDFs first");
    QFile lock(root+"/tests/eval/arxiv-lock.tsv");QVERIFY(lock.open(QIODevice::ReadOnly));QHash<QString,QByteArray> hashes;
    for(const auto &line:lock.readAll().split('\n')){const auto fields=line.simplified().split(' ');if(fields.size()>=3 && !fields[0].startsWith('#'))hashes.insert(QString::fromLatin1(fields[0]),fields[2]);}
    QTemporaryDir scratch;QVERIFY(scratch.isValid());Viewer view;QVERIFY(view.window);view.window->setProperty("paperAppearance","original");QVariantList report;
    for(const auto &id:{QString("1512.03385"),QString("1706.03762"),QString("2303.08774")}) {
        const auto input=root+"/eval-papers/"+id+".pdf";QFile file(input);QVERIFY2(file.open(QIODevice::ReadOnly),qPrintable(input));
        QCOMPARE(QCryptographicHash::hash(file.readAll(),QCryptographicHash::Sha256).toHex(),hashes.value(id));file.close();
        const auto copied=scratch.path()+"/"+id+".pdf";QVERIFY(QFile::copy(input,copied));view.workspace.openFile(QUrl::fromLocalFile(copied));
        auto *reader=view.workspace.activeReader();QTRY_VERIFY_WITH_TIMEOUT(reader->pageCount()>1,30000);QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,30000);
        reader->submit("references");QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,60000);
        const auto references=reader->data().value("references").toList();QVERIFY(references.size()>=30);
        auto *preview=view.workspace.preview();bool resolved=false;
        for(int page=0;page<qMin(6,reader->pageCount()) && !resolved;++page) {
            reader->submit("citations",{{"page",page}});QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,30000);
            for(const auto &value:reader->data().value("citations").toList()) {
                const auto citation=value.toMap();
                preview->openAt(reader,page,citation.value("x_pt").toDouble()+citation.value("width_pt").toDouble()/2,citation.value("y_pt").toDouble()+citation.value("height_pt").toDouble()/2,320,200,1);
                QTRY_VERIFY_WITH_TIMEOUT(!preview->loading(),30000);
                if(!preview->visible() || preview->model().value("kind").toString()!="reference"){preview->close();continue;}
                const auto entries=preview->model().value("entries").toList();QVERIFY(!entries.isEmpty());
                for(const auto &entry:entries)QVERIFY(!entry.toMap().value("text").toString().isEmpty());
                QVERIFY(textEvidence(view,id));preview->showEntry(0);QTRY_VERIFY_WITH_TIMEOUT(view.cropReady(),15000);QVERIFY(cropEvidence(view,id));
                report.append(QVariantMap{{"id",id},{"pages",reader->pageCount()},{"references",references.size()},{"sourcePage",page},{"previewPage",preview->model().value("page")},{"region",preview->model().value("region")},{"fragments",preview->model().value("fragments")},{"devicePixelRatio",view.window->effectiveDevicePixelRatio()}});
                preview->close();resolved=true;break;
            }
        }
        QVERIFY2(resolved,qPrintable("No native reference crop resolved for "+id));
        reader->requestText(0);QTRY_VERIFY_WITH_TIMEOUT(reader->textPages().contains("0"),10000);QVERIFY(reader->textPages().value("0").toMap().value("text").toString().size()>100);
        QTRY_COMPARE_WITH_TIMEOUT(reader->pendingCommands(),0,10000);view.workspace.closeTab(view.workspace.activeIndex());
    }
    const auto output=qEnvironmentVariable("LYRA_READER_CORPUS_OUTPUT");
    if(!output.isEmpty()){QSaveFile file(output);QVERIFY(file.open(QIODevice::WriteOnly));QVERIFY(file.write(QJsonDocument::fromVariant(report).toJson())>0);QVERIFY(file.commit());}
    qInfo().noquote()<<"lyra-reader-native-corpus:"<<QJsonDocument::fromVariant(report).toJson(QJsonDocument::Compact);
}
}
