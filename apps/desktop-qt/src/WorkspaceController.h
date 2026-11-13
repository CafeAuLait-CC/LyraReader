#pragma once
#include "ReaderController.h"
#include "CredentialStore.h"
#include "PreviewController.h"
#include <QVariantList>
#include "QuitCoordinator.h"
class QPrinter;

// Native window session. Tabs retain their own document, raster cache and view state.
class WorkspaceController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList tabs READ tabs NOTIFY tabsChanged)
    Q_PROPERTY(ReaderController *activeReader READ activeReader NOTIFY activeReaderChanged)
    Q_PROPERTY(int activeIndex READ activeIndex NOTIFY activeReaderChanged)
    Q_PROPERTY(QVariantList recentDocuments READ recentDocuments NOTIFY recentDocumentsChanged)
    Q_PROPERTY(PreviewController *preview READ preview CONSTANT)
    Q_PROPERTY(CredentialStore *credentials READ credentials CONSTANT)
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
    bool tabTransferInProgress()const{return m_tabTransfer;}
    QString tabTransferBlockReason()const;
    QString transferActiveTabTo(WorkspaceController *target,QPointer<ReaderController> *emptySource=nullptr);
    Q_INVOKABLE void closeTab(int index, bool discardPending = false);
    Q_INVOKABLE void newTab();
    Q_INVOKABLE void requestQuit();
    Q_INVOKABLE void openInNewWindow(const QUrl &url, int page = 0, double y = 0);
    Q_INVOKABLE QVariantMap viewState(ReaderController *reader) const;
    Q_INVOKABLE void saveViewState(ReaderController *reader, const QVariantMap &state);
    Q_INVOKABLE void clearRecentDocuments();
    Q_INVOKABLE virtual void copyText(const QString &text);
    Q_INVOKABLE void openExternal(const QUrl &url);
    Q_INVOKABLE QVariant preference(const QString &key, const QVariant &fallback = {}) const;
    Q_INVOKABLE void setPreference(const QString &key, const QVariant &value);
    Q_INVOKABLE QString localPath(const QUrl &url) const { return url.toLocalFile(); }
    Q_INVOKABLE QString writeTextFile(const QUrl &url, const QString &text);
signals:
    void tabsChanged();
    void printFinished(const QString &error);
    void closeTabRequested(int index);
    void activeReaderChanged();
    void activeReaderAboutToChange();
    void recentDocumentsChanged();
    void newWindowRequested(const QUrl &url, int page, double y);
    void detachActiveTabRequested();
    void moveActiveTabToWindowRequested(WorkspaceController *target,ReaderController *reader,qulonglong generation);
    void tabTransferFailed(const QString &reason);
    void tabTransferStateChanged();
private:
    ReaderController *appendTab(bool notify=true);
    void connectReader(ReaderController *reader);
    static QString readerTransferBlockReason(const ReaderController *reader,bool allowEmpty);
    void remember(ReaderController *reader);
    static void publishRecents(const QVariantList &entries);
    const QString m_windowTransferId;
    QList<ReaderController *> m_tabs;
    QHash<ReaderController *, QVariantMap> m_views;
    QHash<ReaderController *, QList<QMetaObject::Connection>> m_readerConnections;
    bool m_tabTransfer=false;
    int m_printJobs=0;
    QVariantList m_recent;
    int m_activeIndex = 0;
    PreviewController *m_preview = new PreviewController(this);
    CredentialStore *m_credentials=nullptr;
};
