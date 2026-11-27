#pragma once
#include "ReaderController.h"
#include "CredentialStore.h"
#include "ConnectionTestController.h"
#include "ChatGptAccounts.h"
#include "PreviewController.h"
#include <QVariantList>
#include "QuitCoordinator.h"
class QPrinter;

// Native window session. Tabs retain their own document, raster cache and view state.
class WorkspaceController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList readingPresets READ readingPresets CONSTANT)
    Q_PROPERTY(QVariantMap readingPresetSnapshot READ readingPresetSnapshot NOTIFY readingPresetChanged)
    Q_PROPERTY(QVariantList regionConversationStyles READ regionConversationStyles CONSTANT)
    Q_PROPERTY(QString regionConversationStyle READ regionConversationStyle NOTIFY regionConversationStyleChanged)
    Q_PROPERTY(QVariantList tabs READ tabs NOTIFY tabsChanged)
    Q_PROPERTY(ReaderController *activeReader READ activeReader NOTIFY activeReaderChanged)
    Q_PROPERTY(int activeIndex READ activeIndex NOTIFY activeReaderChanged)
    Q_PROPERTY(QVariantList recentDocuments READ recentDocuments NOTIFY recentDocumentsChanged)
    Q_PROPERTY(PreviewController *preview READ preview CONSTANT)
    Q_PROPERTY(CredentialStore *credentials READ credentials CONSTANT)
    Q_PROPERTY(ConnectionTestController *connectionTest READ connectionTest CONSTANT)
    Q_PROPERTY(QVariant aiOutputLanguage READ aiOutputLanguage NOTIFY aiOutputLanguageChanged)
    Q_PROPERTY(ChatGptAccounts *chatGptAccounts READ chatGptAccounts CONSTANT)
    Q_PROPERTY(QuitCoordinator *quitCoordinator READ quitCoordinator CONSTANT)
    Q_PROPERTY(bool tabTransferInProgress READ tabTransferInProgress NOTIFY tabTransferStateChanged)
public:
    // Takes ownership of an optional platform vault adapter.
    explicit WorkspaceController(QObject *parent=nullptr,CredentialStore *credentials=nullptr);
    ~WorkspaceController() override;
    QVariantList tabs() const;
    ReaderController *activeReader() const;
    int activeIndex() const { return m_activeIndex; }
    QVariantList recentDocuments() const { return m_recent; }
    PreviewController *preview()const{return m_preview;}
    CredentialStore *credentials() const { return m_credentials; }
    ConnectionTestController *connectionTest() const {return m_connectionTest;}
    ChatGptAccounts *chatGptAccounts() const { return ChatGptAccounts::instance(); }
    QuitCoordinator *quitCoordinator()const;
    static QList<WorkspaceController *> allWorkspaces();
    QWindow *readerWindow()const;
    QString windowTransferId()const{return m_windowTransferId;}
    Q_INVOKABLE QVariantList tabTransferTargets()const;
    Q_INVOKABLE void moveActiveTabToWindow(const QString &targetId,ReaderController *expectedReader,qulonglong expectedGeneration);
    Q_INVOKABLE void printDocument(ReaderController *reader, int currentPage = 0);
    void printDocumentToDevice(ReaderController *reader,const std::shared_ptr<QPrinter> &printer,int currentPage=0,bool showProgress=true);
    Q_INVOKABLE void openFiles(const QList<QUrl> &urls);
    Q_INVOKABLE void openFile(const QUrl &url);
    Q_INVOKABLE void selectTab(int index);
    Q_INVOKABLE bool moveTab(ReaderController *reader, ReaderController *before);
    Q_INVOKABLE void detachActiveTab();
    Q_INVOKABLE QString prepareNativeTabDrag(ReaderController *reader);
    Q_INVOKABLE bool nativeTabDragInProgress() const;
    Q_INVOKABLE bool acceptsNativeTabDrag(const QString &token, bool newWindow) const;
    Q_INVOKABLE bool queueNativeTabDrop(const QString &token, ReaderController *before, bool newWindow);
    Q_INVOKABLE void finishNativeTabDrag(const QString &token, bool moved);
    bool tabTransferInProgress()const{return m_tabTransfer;}
    QString tabTransferBlockReason(ReaderController *reader) const;
    QString transferActiveTabTo(WorkspaceController *target,QPointer<ReaderController> *emptySource=nullptr);
    QString transferTabTo(WorkspaceController *target, ReaderController *reader, ReaderController *before,
                          QPointer<ReaderController> *emptySource=nullptr);
    Q_INVOKABLE void closeTab(int index, bool discardPending = false);
    Q_INVOKABLE void newTab();
    Q_INVOKABLE void requestQuit();
    Q_INVOKABLE void openInNewWindow(const QUrl &url, int page = 0, double y = 0);
    Q_INVOKABLE QVariantMap viewState(ReaderController *reader) const;
    Q_INVOKABLE void saveViewState(ReaderController *reader, const QVariantMap &state);
    Q_INVOKABLE void clearRecentDocuments();
    Q_INVOKABLE virtual void copyText(const QString &text);
    Q_INVOKABLE void openExternal(const QUrl &url);
    QVariantList readingPresets() const;
    // Last explicit preset; subsequent independent window-theme edits keep their own value.
    QVariantMap readingPresetSnapshot() const;
    Q_INVOKABLE bool applyReadingPreset(const QString &id);
    QVariantList regionConversationStyles() const;
    QString regionConversationStyle() const;
    Q_INVOKABLE bool applyRegionConversationStyle(const QString &id);
    Q_INVOKABLE QVariantMap inspectReasoning(const QString &mode, const QString &encoding) const;
    Q_INVOKABLE QVariantMap generationDefaults() const;
    QVariant aiOutputLanguage() const;
    Q_INVOKABLE bool setAiOutputLanguage(const QString &language);
    Q_INVOKABLE QVariant preference(const QString &key, const QVariant &fallback = {}) const;
    Q_INVOKABLE void setPreference(const QString &key, const QVariant &value);
    Q_INVOKABLE QString localPath(const QUrl &url) const { return url.toLocalFile(); }
    Q_INVOKABLE QUrl urlForLocalPath(const QString &path) const { return QUrl::fromLocalFile(path); }
    Q_INVOKABLE QString writeTextFile(const QUrl &url, const QString &text);
signals:
    void aiOutputLanguageChanged();
    void readingPresetChanged();
    void regionConversationStyleChanged();
    void tabsChanged();
    void printFinished(const QString &error);
    void closeTabRequested(int index);
    void activeReaderChanged();
    void activeReaderAboutToChange();
    void recentDocumentsChanged();
    void newWindowRequested(const QUrl &url, int page, double y);
    void detachTabRequested(ReaderController *reader, qulonglong generation);
    void moveTabToWindowRequested(WorkspaceController *target, ReaderController *reader, qulonglong generation, ReaderController *before);
    void tabTransferFailed(const QString &reason);
    void tabTransferStateChanged();
private:
    ReaderController *appendTab(bool notify=true);
    void connectReader(ReaderController *reader);
    static QString readerTransferBlockReason(const ReaderController *reader,bool allowEmpty);
    void remember(ReaderController *reader);
    void rememberCover(ReaderController *reader,double scale);
    static void publishRecents(const QVariantList &entries);
    const QString m_windowTransferId;
    QList<ReaderController *> m_tabs;
    QHash<ReaderController *, QVariantMap> m_views;
    QHash<ReaderController *, QList<QMetaObject::Connection>> m_readerConnections;
    bool m_tabTransfer=false;
    int m_printJobs=0;
    QVariantList m_recent;
    QHash<ReaderController *,QPair<qulonglong,int>> m_coverAttempts;
    int m_activeIndex = 0;
    PreviewController *m_preview = new PreviewController(this);
    CredentialStore *m_credentials=nullptr;
    ConnectionTestController *m_connectionTest=nullptr;
};
