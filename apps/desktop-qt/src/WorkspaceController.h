#pragma once
#include "ReaderController.h"
#include "CredentialStore.h"
#include <QVariantList>

// Native window session. Tabs retain their own document, raster cache and view state.
class WorkspaceController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList tabs READ tabs NOTIFY tabsChanged)
    Q_PROPERTY(ReaderController *activeReader READ activeReader NOTIFY activeReaderChanged)
    Q_PROPERTY(int activeIndex READ activeIndex NOTIFY activeReaderChanged)
    Q_PROPERTY(QVariantList recentDocuments READ recentDocuments NOTIFY recentDocumentsChanged)
    Q_PROPERTY(CredentialStore *credentials READ credentials CONSTANT)
public:
    explicit WorkspaceController(QObject *parent = nullptr);
    QVariantList tabs() const;
    ReaderController *activeReader() const;
    int activeIndex() const { return m_activeIndex; }
    QVariantList recentDocuments() const { return m_recent; }
    CredentialStore *credentials() const { return m_credentials; }
    Q_INVOKABLE void printDocument(ReaderController *reader, int currentPage = 0);
    Q_INVOKABLE void openFiles(const QList<QUrl> &urls);
    Q_INVOKABLE void openFile(const QUrl &url);
    Q_INVOKABLE void selectTab(int index);
    Q_INVOKABLE void closeTab(int index, bool discardPending = false);
    Q_INVOKABLE void newTab();
    Q_INVOKABLE void openInNewWindow(const QUrl &url, int page = 0);
    Q_INVOKABLE QVariantMap viewState(ReaderController *reader) const;
    Q_INVOKABLE void saveViewState(ReaderController *reader, const QVariantMap &state);
    Q_INVOKABLE void clearRecentDocuments();
    Q_INVOKABLE void copyText(const QString &text);
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
    void newWindowRequested(const QUrl &url, int page);
private:
    ReaderController *appendTab();
    void remember(ReaderController *reader);
    QList<ReaderController *> m_tabs;
    QHash<ReaderController *, QVariantMap> m_views;
    QVariantList m_recent;
    int m_activeIndex = 0;
    CredentialStore *m_credentials = new CredentialStore(this);
};
