#pragma once
#include "lyra_reader_desktop.h"
#include <QCache>
#include <QImage>
#include <QObject>
#include <QSet>
#include <QUrl>
#include <QVariantList>
#include <memory>
class CommandQueue;

// One controller per tab; windows own independent sets of tabs.
class ReaderController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList pages READ pages NOTIFY documentChanged)
    Q_PROPERTY(int pageCount READ pageCount NOTIFY documentChanged)
    Q_PROPERTY(double documentWidth READ documentWidth NOTIFY documentChanged)
    Q_PROPERTY(double documentHeight READ documentHeight NOTIFY documentChanged)
    Q_PROPERTY(QUrl fileUrl READ fileUrl NOTIFY documentChanged)
    Q_PROPERTY(QVariantMap noteDrafts READ noteDrafts NOTIFY noteDraftsChanged)
    Q_PROPERTY(QVariantMap data READ data NOTIFY dataChanged)
    Q_PROPERTY(QVariantMap textPages READ textPages NOTIFY textPagesChanged)
    Q_PROPERTY(int pendingCommands READ pendingCommands NOTIFY commandsChanged)
    Q_PROPERTY(QString title READ title NOTIFY documentChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool passwordRequired READ passwordRequired NOTIFY passwordRequiredChanged)
    Q_PROPERTY(qulonglong completedRasters READ completedRasters NOTIFY statisticsChanged)
    Q_PROPERTY(qulonglong discardedRasters READ discardedRasters NOTIFY statisticsChanged)
    Q_PROPERTY(int pendingRasters READ pendingRasters NOTIFY statisticsChanged)
public:
    explicit ReaderController(QObject *parent = nullptr);
    QVariantList pages() const { return m_pages; }
    int pageCount() const { return int(m_pages.size()); }
    double documentWidth() const { return m_documentWidth; }
    double documentHeight() const { return m_documentHeight; }
    QUrl fileUrl() const { return m_lastUrl; }
    QVariantMap noteDrafts()const{return m_noteDrafts;}
    Q_INVOKABLE void setNoteDraft(const QString &id,const QString &text){m_noteDrafts.insert(id,text);emit noteDraftsChanged();}
    Q_INVOKABLE void clearNoteDraft(const QString &id){if(m_noteDrafts.remove(id))emit noteDraftsChanged();}
    QVariantMap data() const { return m_data; }
    QVariantMap textPages() const { return m_textPages; }
    int pendingCommands() const { return m_pendingCommands; }
    QString title() const { return m_title; }
    QString error() const { return m_error; }
    bool loading() const { return m_loading; }
    bool passwordRequired() const { return m_passwordRequired; }
    qulonglong completedRasters() const { return m_completed; }
    qulonglong discardedRasters() const { return m_discarded; }
    int pendingRasters() const { return int(m_requests.size()) + (m_rendering ? 1 : 0); }
    Q_INVOKABLE void openFile(const QUrl &url, const QString &password = {});
    Q_INVOKABLE void retryPassword(const QString &password);
    Q_INVOKABLE void dismissError();
    Q_INVOKABLE quint64 submit(const QString &operation, const QVariantMap &arguments = {});
    Q_INVOKABLE void requestText(int page);
    Q_INVOKABLE void setLayout(const QString &mode, double gap);
    Q_INVOKABLE double fitWidth(double viewportWidth) const;
    Q_INVOKABLE double zoomOffset(double offset, double anchor, double oldZoom, double newZoom) const;
    std::shared_ptr<LyraReaderDesktopDocument> documentHandle()const{return m_document;}
    void requestPage(int page, double scale,bool embedded=false);
    QImage cachedPage(int page, double scale,bool embedded=false) const;
    static QString rasterKey(int page, double scale,bool embedded=false);
signals:
    void documentChanged();
    void documentReset();
    void loadingChanged();
    void errorChanged();
    void passwordRequiredChanged();
    void statisticsChanged();
    void pageReady(int page, double scale);
    void openFinished(bool success);
    void commandFinished(quint64 id, const QString &operation, const QVariant &result, const QString &error);
    void dataChanged();
    void noteDraftsChanged();
    void textPagesChanged();
    void commandsChanged();
private:
    struct Request { int page; double scale; QString key; bool embedded; };
    void startNextRaster();
    void setError(const QString &error);
    std::shared_ptr<LyraReaderDesktopDocument> m_document;
    QUrl m_lastUrl;
    QVariantList m_pages;
    double m_documentWidth = 0;
    double m_documentHeight = 0;
    QVariantMap m_data, m_textPages, m_noteDrafts;
    QSet<int> m_textPending;
    int m_pendingCommands = 0;
    quint64 m_commandSequence = 0;
    quint64 m_mutationSequence = 0;
    QHash<QString,quint64> m_latestRead;
    std::shared_ptr<CommandQueue> m_mutations;
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
