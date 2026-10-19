#include "ReaderController.h"
#include "PageItem.h"
#include <QGuiApplication>
#include <QDir>
#include <QSignalSpy>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QtTest>

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
        const auto before = reader.completedRasters();
        QVERIFY(QMetaObject::invokeMethod(window, "zoomBy", Q_ARG(QVariant, 1.2)));
        QTRY_VERIFY_WITH_TIMEOUT(reader.completedRasters() > before, 10000);
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
        const auto snapshots = qEnvironmentVariable("LYRA_READER_CHECK_SNAPSHOTS");
        if (!snapshots.isEmpty()) {
            QVERIFY(frame.save(snapshots + "/lyrareader-light.png"));
            QVERIFY(darkFrame.save(snapshots + "/lyrareader-dark.png"));
        }
        window->setProperty("appearance", "light");
        QVERIFY(QMetaObject::invokeMethod(window, "navigate", Q_ARG(QVariant, reader.pageCount() - 1)));
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
};

int main(int argc, char **argv) {
    QGuiApplication application(argc, argv);
    QQuickStyle::setStyle("Fusion");
    if (argc < 2) return 2;
    ReaderChecks checks;
    checks.root = QDir(QString::fromLocal8Bit(argv[1])).absolutePath();
    // The root argument belongs to this harness, not QTest's test-function selection.
    int testArgc = 1;
    return QTest::qExec(&checks, testArgc, argv);
}
#include "ReaderChecks.moc"
