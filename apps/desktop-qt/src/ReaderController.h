#pragma once
#include "lyra_reader_desktop.h"
#include <QCache>
#include <QImage>
#include <QObject>
#include <QSet>
#include <QUrl>
#include <QVariantList>
#include <memory>

// One controller per window. No mutable document/viewport state is process-global.
class ReaderController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList pages READ pages NOTIFY documentChanged)
    Q_PROPERTY(int pageCount READ pageCount NOTIFY documentChanged)
    Q_PROPERTY(double documentWidth READ documentWidth NOTIFY documentChanged)
    Q_PROPERTY(QString title READ title NOTIFY documentChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool passwordRequired READ passwordRequired NOTIFY passwordRequiredChanged)
    Q_PROPERTY(qulonglong completedRasters READ completedRasters NOTIFY statisticsChanged)
    Q_PROPERTY(qulonglong discardedRasters READ discardedRasters NOTIFY statisticsChanged)
public:
    explicit ReaderController(QObject *parent = nullptr);
    QVariantList pages() const { return m_pages; }
    int pageCount() const { return int(m_pages.size()); }
    double documentWidth() const { return m_documentWidth; }
    QString title() const { return m_title; }
    QString error() const { return m_error; }
    bool loading() const { return m_loading; }
    bool passwordRequired() const { return m_passwordRequired; }
    qulonglong completedRasters() const { return m_completed; }
    qulonglong discardedRasters() const { return m_discarded; }
    Q_INVOKABLE void openFile(const QUrl &url, const QString &password = {});
    Q_INVOKABLE void retryPassword(const QString &password);
    Q_INVOKABLE void dismissError();
    Q_INVOKABLE double fitWidth(double viewportWidth) const;
    Q_INVOKABLE double zoomOffset(double offset, double anchor, double oldZoom, double newZoom) const;
    void requestPage(int page, double scale);
    QImage cachedPage(int page, double scale) const;
    static QString rasterKey(int page, double scale);
signals:
    void documentChanged();
    void documentReset();
    void loadingChanged();
    void errorChanged();
    void passwordRequiredChanged();
    void statisticsChanged();
    void pageReady(int page, double scale);
    void openFinished(bool success);
private:
    struct Request { int page; double scale; QString key; };
    void startNextRaster();
    void setError(const QString &error);
    std::shared_ptr<LyraReaderDesktopDocument> m_document;
    QUrl m_lastUrl;
    QVariantList m_pages;
    double m_documentWidth = 0;
    QString m_title = QStringLiteral("LyraReader");
    QString m_error;
    bool m_loading = false;
    bool m_passwordRequired = false;
    bool m_rendering = false;
    quint64 m_generation = 0;
    qulonglong m_completed = 0, m_discarded = 0;
    // KiB, CPU raster cache only. Visible items can retain a shared image after LRU eviction.
    QCache<QString, QImage> m_cache{48 * 1024};
    QSet<QString> m_pending, m_failed;
    QList<Request> m_requests;
};
