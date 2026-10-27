#pragma once
#include "lyra_reader_desktop.h"
#include "RasterJobs.h"
#include <QRectF>
#include <QImage>
#include <QObject>
#include <QSet>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <memory>
class CommandQueue;
class NativeRasterSource;
struct TileSpec {
    QString key;
    int page=0,level=0,column=0,row=0;
    double scale=1;
    QRectF target,render;
};

// One controller per tab; windows own independent sets of tabs.
class ReaderController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList pages READ pages NOTIFY documentChanged)
    Q_PROPERTY(int pageCount READ pageCount NOTIFY documentChanged)
    Q_PROPERTY(double documentWidth READ documentWidth NOTIFY documentChanged)
    Q_PROPERTY(double documentHeight READ documentHeight NOTIFY documentChanged)
    Q_PROPERTY(QUrl fileUrl READ fileUrl NOTIFY documentChanged)
    Q_PROPERTY(QVariantMap aiState READ aiState NOTIFY aiStateChanged)
    Q_PROPERTY(QVariantMap editDrafts READ editDrafts NOTIFY editDraftsChanged)
    Q_PROPERTY(bool hasEditDrafts READ hasEditDrafts NOTIFY editDraftsChanged)
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
    ~ReaderController() override;
    QVariantList pages() const { return m_pages; }
    int pageCount() const { return int(m_pages.size()); }
    double documentWidth() const { return m_documentWidth; }
    double documentHeight() const { return m_documentHeight; }
    QUrl fileUrl() const { return m_lastUrl; }
    QVariantMap aiState()const{return m_aiState;}
    Q_INVOKABLE void prepareAi(const QVariantMap &request);
    Q_INVOKABLE bool startAi(const QString &key,const QVariantMap &expectedPlan);
    Q_INVOKABLE void cancelAi();
    Q_INVOKABLE void setAiInput(const QString &key,const QVariant &value);
    Q_INVOKABLE void invalidateAiPlan();
    QVariantMap editDrafts()const{return m_editDrafts;}
    bool hasEditDrafts()const{return !m_editDrafts.isEmpty();}
    Q_INVOKABLE void setEditDraft(const QString &key,const QVariant &value);
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
    Q_INVOKABLE double zoomOffset(double offset, double anchor, double oldZoom, double newZoom) const;
    Q_INVOKABLE QVariantMap signatureImage(const QUrl &url) const;
    std::shared_ptr<LyraReaderDesktopDocument> documentHandle()const{return m_document;}
    void requestPage(int page, double scale,bool embedded=false);
    void requestPageForConsumer(quintptr consumer,int page,double scale,bool embedded=false);
    void clearRasterDemand(quintptr consumer);
    QImage cachedPage(int page, double scale,bool embedded=false) const;
    QList<TileSpec> requestTiles(quintptr consumer,int page,int level,const QRectF &visible,const QSet<QString> &retained);
    void clearTileDemand(quintptr consumer);
    QImage cachedTile(const QString &key)const;
    static double tileScale(int level);
    static int cpuCacheKiB();
    static QString rasterKey(int page, double scale,bool embedded=false);
signals:
    void documentChanged();
    void documentReset();
    void loadingChanged();
    void errorChanged();
    void passwordRequiredChanged();
    void statisticsChanged();
    void pageReady(int page, double scale);
    void tileReady(int page);
    void openFinished(bool success);
    void commandFinished(quint64 id, const QString &operation, const QVariant &result, const QString &error);
    void dataChanged();
    void noteDraftsChanged();
    void editDraftsChanged();
    void aiStateChanged();
    void textPagesChanged();
    void commandsChanged();
private:
    struct Request { int page; double scale; QString key; bool embedded=false; bool tile=false; QRectF region; int priority=0; };
    void initAi();
    void resetAi();
    void handleAiCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error);
    QTimer m_aiTimer;
    QVariantMap m_aiState;
    quint64 m_aiPreviewId=0,m_aiStartId=0,m_aiPollId=0,m_aiPlanGeneration=0;
    void enqueue(const Request &request);
    void requestPageInternal(int page,double scale,bool embedded,bool manual);
    void pruneTileRequests();
    void clearRasterCache();
    void startNextRaster();
    void setError(const QString &error);
    std::shared_ptr<LyraReaderDesktopDocument> m_document;
    std::shared_ptr<NativeRasterSource> m_source;
    QString m_cachePrefix;
    QHash<quintptr,QSet<QString>> m_tileDemand;
    QHash<quintptr,QString> m_pageDemand;
    QSet<QString> m_manualDemand;
    RasterJobs::Handle m_activeRaster;
    QString m_activeRasterKey;
    bool m_activeRasterIsTile=false;
    QUrl m_lastUrl;
    QVariantList m_pages;
    double m_documentWidth = 0;
    double m_documentHeight = 0;
    QVariantMap m_data, m_textPages, m_noteDrafts, m_editDrafts;
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
    bool m_rasterRetryQueued=false;
    quint64 m_generation = 0;
    qulonglong m_completed = 0, m_discarded = 0;
    // Whole pages and bounded tiles share the process-wide 96 MiB CPU LRU.
    QSet<QString> m_pending, m_failed;
    QList<Request> m_requests;
};
