#pragma once
#include "lyra_reader_desktop.h"
#include "RasterJobs.h"
#include <QRectF>
#include <QImage>
#include <QObject>
#include <QColor>
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

struct TilePlanResult {QList<TileSpec> tiles;bool accepted=false;};

// One controller per tab or immutable preview; windows retain independent reader state.
class ReaderController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList pages READ pages NOTIFY documentChanged)
    Q_PROPERTY(QVariantMap fitPresentation READ fitPresentation NOTIFY fitPresentationChanged)
    Q_PROPERTY(QVariantList layoutRows READ layoutRows NOTIFY documentChanged)
    Q_PROPERTY(QVariantMap layoutConfiguration READ layoutConfiguration NOTIFY documentChanged)
    Q_PROPERTY(int pageCount READ pageCount NOTIFY documentChanged)
    Q_PROPERTY(double documentWidth READ documentWidth NOTIFY documentChanged)
    Q_PROPERTY(double documentHeight READ documentHeight NOTIFY documentChanged)
    Q_PROPERTY(QUrl fileUrl READ fileUrl NOTIFY documentChanged)
    Q_PROPERTY(QVariantMap aiState READ aiState NOTIFY aiStateChanged)
    Q_PROPERTY(QVariantMap documentReading READ documentReading NOTIFY documentReadingChanged)
    Q_PROPERTY(QVariantMap aiRegion READ aiRegion NOTIFY aiRegionChanged)
    Q_PROPERTY(QVariantMap aiRegionPaper READ aiRegionPaper NOTIFY aiRegionPaperChanged)
    Q_PROPERTY(QVariantMap regionNoteDraft READ regionNoteDraft NOTIFY regionNoteDraftChanged)
    Q_PROPERTY(bool hasUnsavedReadingNotes READ hasUnsavedReadingNotes NOTIFY regionNoteDraftChanged)
    Q_PROPERTY(bool regionPersistencePending READ regionPersistencePending NOTIFY regionNoteDraftChanged)
    Q_PROPERTY(QString regionPersistenceError READ regionPersistenceError NOTIFY regionNoteDraftChanged)
    Q_PROPERTY(QVariantMap regionHistory READ regionHistory NOTIFY regionHistoryChanged)
    Q_PROPERTY(QUrl aiRegionImage READ aiRegionImage NOTIFY aiRegionImageChanged)
    Q_PROPERTY(QVariantMap editDrafts READ editDrafts NOTIFY editDraftsChanged)
    Q_PROPERTY(bool hasEditDrafts READ hasEditDrafts NOTIFY editDraftsChanged)
    Q_PROPERTY(QVariantMap noteDrafts READ noteDrafts NOTIFY noteDraftsChanged)
    Q_PROPERTY(bool hasUnsavedChanges READ hasUnsavedChanges NOTIFY unsavedChangesChanged)
    Q_PROPERTY(qulonglong editRevision READ editRevision NOTIFY commandsChanged)
    Q_PROPERTY(qulonglong documentGeneration READ documentGeneration NOTIFY documentChanged)
    Q_PROPERTY(QVariantMap data READ data NOTIFY dataChanged)
    Q_PROPERTY(QVariantMap textPages READ textPages NOTIFY textPagesChanged)
    Q_PROPERTY(int pendingCommands READ pendingCommands NOTIFY commandsChanged)
    Q_PROPERTY(QString title READ title NOTIFY documentChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool snapshotReadOnly READ snapshotReadOnly NOTIFY documentChanged)
    Q_PROPERTY(bool passwordRequired READ passwordRequired NOTIFY passwordRequiredChanged)
    Q_PROPERTY(qulonglong completedRasters READ completedRasters NOTIFY statisticsChanged)
    Q_PROPERTY(qulonglong discardedRasters READ discardedRasters NOTIFY statisticsChanged)
    Q_PROPERTY(int pendingRasters READ pendingRasters NOTIFY statisticsChanged)
public:
    explicit ReaderController(QObject *parent = nullptr);
    ~ReaderController() override;
    QVariantList pages() const { return m_pages; }
    QVariantMap fitPresentation() const { return m_fitPresentation; }
    QVariantList layoutRows() const { return m_layoutRows; }
    QVariantMap layoutConfiguration() const { return m_layoutConfiguration; }
    int pageCount() const { return int(m_pages.size()); }
    double documentWidth() const { return m_documentWidth; }
    double documentHeight() const { return m_documentHeight; }
    QUrl fileUrl() const { return m_lastUrl; }
    QVariantMap aiState()const{return m_aiState;}
    QVariantMap documentReading()const{auto state=m_documentReading;state.insert(QStringLiteral("choice_pending"),m_readingChoicePending);return state;}
    Q_INVOKABLE void prepareDocumentReading(const QVariantMap &request);
    Q_INVOKABLE bool startDocumentReading(const QString &key,const QVariantMap &plan,const QString &token);
    Q_INVOKABLE void stopDocumentReading();
    Q_INVOKABLE void invalidateDocumentReadingPreview();
    Q_INVOKABLE void dismissDocumentReadingChoice();
    QVariantMap aiRegion()const{return m_aiRegion;}
    QVariantMap aiRegionPaper()const{return m_aiRegionPaper;}
    Q_INVOKABLE void configureAiRegionPaper(const QString &mode,double pageGap,double cardGap);
    Q_INVOKABLE void clearAiRegionPaper();
    Q_INVOKABLE double unshiftedPaperScroll(double displayY,double reveal=1.0) const;
    Q_INVOKABLE double shiftedPaperScroll(double sourceY,double reveal=1.0) const;
    QVariantMap regionNoteDraft()const{return m_regionNoteDraft;}
    bool hasUnsavedReadingNotes()const{return !m_regionNoteDraft.isEmpty() || !m_regionSaveError.isEmpty() || regionNeedsSave() || m_aiRegionSaveId || regionRequestRunning();}
    bool regionPersistencePending()const;
    QString regionPersistenceError()const{return m_regionSaveError;}
    Q_INVOKABLE void flushAiRegionNote(bool stopResponse=true);
    Q_INVOKABLE QVariantMap regionDiscardContext()const;
    Q_INVOKABLE bool discardAiRegionChanges(const QVariantMap &expected);
    Q_INVOKABLE bool setRegionNoteDraft(const QString &id,const QString &text);
    Q_INVOKABLE void discardRegionNoteDraft();
    Q_INVOKABLE quint64 saveRegionNoteDraft();
    Q_INVOKABLE bool isSavingRegionNote()const{return m_regionNoteSaveId!=0;}
    QVariantMap regionHistory()const{return m_regionHistory;}
    Q_INVOKABLE quint64 saveAiRegionNote();
    Q_INVOKABLE quint64 reopenAiRegion(const QString &id,const QString &revision);
    QUrl aiRegionImage()const{return m_aiRegionImage;}
    Q_INVOKABLE bool captureAiRegion(int page,const QVariantMap &rect,double zoom);
    Q_INVOKABLE void cancelAiRegionCapture();
    Q_INVOKABLE void clearAiRegion();
    Q_INVOKABLE void setAiRegionQuestion(const QString &text);
    Q_INVOKABLE void prepareAiRegion(const QVariantMap &settings);
    Q_INVOKABLE void prepareAi(const QVariantMap &request);
    Q_INVOKABLE bool startAi(const QString &key,const QVariantMap &expectedPlan);
    Q_INVOKABLE void cancelAi();
    Q_INVOKABLE void setAiInput(const QString &key,const QVariant &value);
    Q_INVOKABLE void invalidateAiPlan();
    Q_INVOKABLE void clearAiChat();
    QVariantMap editDrafts()const{return m_editDrafts;}
    bool hasEditDrafts()const{return !m_editDrafts.isEmpty();}
    Q_INVOKABLE void setEditDraft(const QString &key,const QVariant &value);
    QVariantMap noteDrafts()const{return m_noteDrafts;}
    bool hasUnsavedChanges()const;
    qulonglong editRevision()const{return m_mutationSequence;}
    qulonglong documentGeneration()const{return m_generation;}
    Q_INVOKABLE void setNoteDraft(const QString &id,const QString &text){m_noteDrafts.insert(id,text);emit noteDraftsChanged();}
    Q_INVOKABLE void clearNoteDraft(const QString &id){if(m_noteDrafts.remove(id))emit noteDraftsChanged();}
    QVariantMap data() const { return m_data; }
    QVariantMap textPages() const { return m_textPages; }
    int pendingCommands() const { return m_pendingCommands; }
    QString title() const { return m_title; }
    QString error() const { return m_error; }
    bool loading() const { return m_loading; }
    bool snapshotReadOnly()const{return m_snapshotMode;}
    bool openSnapshot(const std::shared_ptr<NativeRasterSource> &source,const QUrl &identity,const QString &title);
    Q_INVOKABLE void closeSnapshot();
    std::shared_ptr<NativeRasterSource> renderSource()const{return m_source;}
    bool passwordRequired() const { return m_passwordRequired; }
    qulonglong completedRasters() const { return m_completed; }
    qulonglong tilePlanBatches()const{return m_tilePlanBatches;}
    qulonglong discardedRasters() const { return m_discarded; }
    int pendingRasters() const { return int(m_requests.size()) + (m_rendering ? 1 : 0); }
    Q_INVOKABLE void openFile(const QUrl &url, const QString &password = {});
    Q_INVOKABLE void retryPassword(const QString &password);
    Q_INVOKABLE void dismissError();
    Q_INVOKABLE quint64 submit(const QString &operation, const QVariantMap &arguments = {});
    Q_INVOKABLE void requestText(int page);
    Q_INVOKABLE QVariantMap selectionText(int page,int start,int end) const;
    Q_INVOKABLE QVariantMap normalizedCopiedText(const QString &text) const;
    Q_INVOKABLE void setLayout(const QString &mode, double gap);
    Q_INVOKABLE double zoomOffset(double offset, double anchor, double oldZoom, double newZoom) const;
    Q_INVOKABLE uint fitPercent(bool fitPage,double pageWidth,double pageHeight,double viewportWidth,double viewportHeight,double calibration) const;
    Q_INVOKABLE uint viewportFitPercent(uint currentPercent,double pageWidth,double pageHeight,double viewportWidth,double viewportHeight,double calibration) const;
    Q_INVOKABLE bool configureFitPageSpacing(double pageHeight,double viewportHeight,double zoom,double preferredGap);
    Q_INVOKABLE void clearFitPageSpacing();
    Q_INVOKABLE double clampScroll(double offset,double contentHeight,double viewportHeight) const;
    Q_INVOKABLE void cancelIndexQueries();
    Q_INVOKABLE QVariantMap signatureImage(const QUrl &url) const;
    Q_INVOKABLE QColor paperBackground(const QString &appearance) const;
    Q_INVOKABLE QStringList signatureFonts() const;
    Q_INVOKABLE QVariantMap typedSignatureImage(const QString &name,const QString &family) const;
    Q_INVOKABLE QVariantMap formattedDate(const QString &style,const QString &isoDay = {},const QString &localeName = {}) const;
    Q_INVOKABLE QVariantMap datePicture(const QString &text,int clockwiseDegrees) const;
    Q_INVOKABLE QUrl contentPreviewUrl(int page,const QString &target,const QString &revision,
                                      double width,double height,double deviceScale);
    std::shared_ptr<LyraReaderDesktopDocument> documentHandle()const{return m_document;}
    void requestPage(int page, double scale,bool embedded=false);
    void requestPageForConsumer(quintptr consumer,int page,double scale,bool embedded=false);
    void clearRasterDemand(quintptr consumer);
    QImage cachedPage(int page, double scale,bool embedded=false) const;
    QImage cachedBackdrop(int page,bool embedded=false)const;
    QList<TileSpec> requestTiles(quintptr consumer,int page,int level,const QRectF &visible,const QSet<QString> &retained);
    void clearTileDemand(quintptr consumer);
    QImage cachedTile(const QString &key)const;
    TilePlanResult requestTilesForSurface(quintptr consumer,int page,double requiredScale,qint64 residentBytes,const QRectF &visible,const QSet<QString> &retained);
    static int cpuCacheKiB();
    static QString rasterKey(int page, double scale,bool embedded=false);
signals:
    void documentChanged();
    void fitPresentationChanged();
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
    void unsavedChangesChanged();
    void editDraftsChanged();
    void aiStateChanged();
    void documentReadingChanged();
    void aiRegionChanged();
    void aiRegionPaperChanged();
    void aiRegionImageChanged();
    void regionHistoryChanged();
    void regionNoteDraftChanged();
    void textPagesChanged();
    void commandsChanged();
private:
    TilePlanResult requestPlannedTiles(quintptr consumer,int page,const LyraReaderTilePlanRequest &density,const QRectF &visible,const QSet<QString> &retained);
    void setRasterSource(std::shared_ptr<NativeRasterSource> source);
    QString backdropKey(int page)const;
    QString m_contentSourceKey;
    struct Request { int page; double scale; QString key; bool embedded=false; bool tile=false; QRectF region; int priority=0; };
    quint64 submitSnapshot(quint64 id,const QString &operation,const QVariantMap &arguments);
    void initAi();
    void initRegionPersistence();
    void resetRegionPersistence();
    void resetAiRegion();
    void markRegionDirty(bool localInput=false);
    void scheduleRegionPersistence();
    void finishAiRegionSave(const QVariantMap &result,const QString &error);
    void finishDeferredRegionAction();
    bool regionNeedsSave()const;
    bool regionRequestRunning()const;
    QVariantMap regionSnapshotResult()const;
    QTimer m_regionSaveTimer;
    quint64 m_regionRevision=0,m_regionSnapshotRevision=0;
    bool m_regionFlushRequested=false,m_regionCancelRequested=false,m_regionClearPending=false;
    QVariantMap m_pendingRegionCapture;
    void resetAi();
    void initDocumentReading();
    void resetDocumentReading();
    void handleDocumentReadingCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error);
    QTimer m_readingTimer;
    QVariantMap m_documentReading;
    bool m_readingChoiceShown=false,m_readingChoicePending=false;
    quint64 m_readingPreviewId=0,m_readingStartId=0,m_readingPollId=0,m_readingCancelId=0;
    void handleAiCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error);
    void finishAiChat(const QString &state);
    void retainAiResult(const QString &state);
    QTimer m_aiTimer;
    QVariantMap m_aiState;
    QVariantMap m_aiRegion;
    QVariantMap m_aiRegionPaper,m_aiRegionPaperSpec;
    QVariantMap m_layoutConfiguration;
    QVariantMap m_fitPresentation;
    double mapPaperScroll(double value,bool shifted,double reveal) const;
    quint64 m_aiRegionPaperEpoch=0;
    bool m_aiRegionPaperInFlight=false;
    std::shared_ptr<std::atomic_bool> m_aiRegionPaperCancel;
    void startAiRegionPaperPlan();
    QVariantMap m_regionHistory,m_regionNoteDraft,m_regionNoteSaveSnapshot;
    QString m_regionSaveError;
    quint64 m_regionNoteSaveId=0;
    quint64 m_aiRegionSaveId=0;
    quint64 m_aiRegionRestoreId=0,m_aiRegionRestoreEpoch=0,m_regionContinuationEpoch=0;
    QVariantMap m_regionContinuationSettings;
    QString m_regionContinuationQuestion;
    bool m_regionContinuationPending=false;
    QUrl m_aiRegionImage;
    quint64 m_aiRegionEpoch=0;
    RasterJobs::Handle m_aiRegionJob;
    quint64 m_aiPreviewId=0,m_aiStartId=0,m_aiPollId=0,m_aiPlanGeneration=0;
    void enqueue(const Request &request);
    void requestPageInternal(int page,double scale,bool embedded,bool manual);
    void pruneTileRequests();
    void clearRasterCache();
    void startNextRaster();
    void setError(const QString &error);
    std::shared_ptr<LyraReaderDesktopDocument> m_document;
    std::shared_ptr<NativeRasterSource> m_source;
    std::shared_ptr<std::atomic_bool> m_indexCancellation=std::make_shared<std::atomic_bool>(false);
    QString m_cachePrefix;
    QHash<quintptr,QSet<QString>> m_tileDemand;
    QHash<quintptr,QString> m_pageDemand;
    QSet<QString> m_manualDemand;
    RasterJobs::Handle m_activeRaster;
    QString m_activeRasterKey;
    bool m_activeRasterIsTile=false;
    QUrl m_lastUrl;
    QVariantList m_pages;
    QVariantList m_layoutRows;
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
    bool m_snapshotMode = false;
    bool m_passwordRequired = false;
    bool m_rendering = false;
    bool m_rasterRetryQueued=false;
    quint64 m_generation = 0;
    qulonglong m_completed = 0, m_discarded = 0;
    qulonglong m_tilePlanBatches=0;
    // Whole pages and bounded tiles share the process-wide 96 MiB CPU LRU.
    QSet<QString> m_pending, m_failed;
    QList<Request> m_requests;
};
