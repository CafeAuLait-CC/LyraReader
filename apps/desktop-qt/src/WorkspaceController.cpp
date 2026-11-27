#include "WorkspaceController.h"
#include "PdfPrintJob.h"
#include "LocalFileIdentity.h"
#include "RecentCoverCache.h"
#include "DateFormatting.h"
#include "RenderBudget.h"
#include <QPrinter>
#include <QPrintDialog>
#include <QPointer>
#include <QFileInfo>
#include <QDir>
#include <QUuid>
#include <QSettings>
#include <QJSValue>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlEngine>
#include <QScopeGuard>
#include <QClipboard>
#include <QGuiApplication>
#include <QWindow>
#include <QDesktopServices>
#include <QCryptographicHash>
#include <QSaveFile>
#include <QTimer>
#include <QDateTime>
#include <QFutureWatcher>
#include <QThreadPool>
#include <QtConcurrentRun>
#include <atomic>
#include <cmath>
#include <optional>
#include <functional>

namespace {
QList<WorkspaceController *> &workspaces() {static QList<WorkspaceController *> all;return all;}
QVariantMap &readingPresetState() {static QVariantMap state;return state;}
qulonglong &readingPresetRevision() {static qulonglong revision=0;return revision;}
qulonglong &regionStyleRevision() {static qulonglong revision=0;return revision;}
QVariantList normalizedRecents(const QVariantList &entries) {
    QVariantList result;QSet<QString> seen;
    for(const auto &value:entries) {
        auto entry=value.toMap();const QUrl url(entry.value(QStringLiteral("url")).toString());
        if(!url.isLocalFile())continue;
        const QFileInfo file(url.toLocalFile());const auto normalized=QUrl::fromLocalFile(file.absoluteFilePath()).toString();
        if(seen.contains(normalized))continue;
        seen.insert(normalized);
        const auto title=entry.value(QStringLiteral("title")).toString();
        entry.insert(QStringLiteral("url"),normalized);
        entry.insert(QStringLiteral("title"),title.isEmpty()?file.fileName():title);
        entry.insert(QStringLiteral("displayTitle"),file.completeBaseName());
        const auto opened=QDateTime::fromString(entry.value(QStringLiteral("openedAt")).toString(),Qt::ISODateWithMs);
        entry.insert(QStringLiteral("openedDate"),opened.isValid()
            ? DateFormatting::format(QStringLiteral("medium"),opened.toLocalTime().date().toString(Qt::ISODate)).value(QStringLiteral("text")).toString() : QString{});
        result.append(entry);
        if(result.size()==100)break;
    }
    return result;
}
QThreadPool *coverPool() {static QThreadPool pool;static const bool ready=[] {pool.setMaxThreadCount(1);return true;}();Q_UNUSED(ready);return &pool;}
std::atomic_int &coverJobs(){static std::atomic_int jobs{0};return jobs;}
QString positionKey(const ReaderController *reader) {
    return QStringLiteral("reader/positions/") + QString::fromLatin1(QCryptographicHash::hash(
        reader->fileUrl().toEncoded(), QCryptographicHash::Sha256).toHex());
}

struct TabDrop {
    QPointer<WorkspaceController> window;
    QPointer<ReaderController> before;
    QPointer<ReaderController> active;
    qulonglong activeGeneration;
    bool insertBefore;
    bool newWindow;

    bool stillAvailable() const {
        return window && active && window->activeReader()==active &&
            active->documentGeneration()==activeGeneration &&
            (!insertBefore || (before && before->parent()==window));
    }
};

struct NativeTabDrag {
    QString token;
    QPointer<WorkspaceController> source;
    QPointer<ReaderController> reader;
    QPointer<ReaderController> active;
    qulonglong generation;
    qulonglong revision;
    std::optional<TabDrop> drop;

    bool stillAvailable() const {
        return source && reader && active && source->activeReader()==active &&
            reader->parent()==source && reader->documentGeneration()==generation &&
            reader->editRevision()==revision;
    }
};

std::optional<NativeTabDrag> &nativeTabDrag() {
    static std::optional<NativeTabDrag> drag;
    return drag;
}
}

WorkspaceController::WorkspaceController(QObject *parent,CredentialStore *credentials) : QObject(parent),m_windowTransferId(QUuid::createUuid().toString(QUuid::WithoutBraces)),m_credentials(credentials ? credentials : new CredentialStore(this)) {
    m_credentials->setParent(this);
    connect(m_preview,&PreviewController::externalRequested,this,&WorkspaceController::openExternal);
    QSettings settings;
    m_recent = normalizedRecents(settings.value(QStringLiteral("reader/recentDocuments")).toList());
    workspaces().append(this);
    appendTab();
}
WorkspaceController::~WorkspaceController() {
    if (auto &drag=nativeTabDrag(); drag && drag->source==this) drag.reset();
    workspaces().removeAll(this);
}
QList<WorkspaceController *> WorkspaceController::allWorkspaces(){return workspaces();}
QWindow *WorkspaceController::readerWindow()const {
    for(auto *window:QGuiApplication::topLevelWindows())
        if(window->objectName()==QStringLiteral("readerWindow") && window->property("session").value<WorkspaceController *>()==this)return window;
    return nullptr;
}
QVariantList WorkspaceController::tabTransferTargets()const {
    QVariantList result;int number=0;
    for(auto *candidate:workspaces()) {
        auto *window=candidate->readerWindow();
        if(!window || !window->isVisible())continue;
        ++number;if(candidate==this)continue;
        const auto *reader=candidate->activeReader();const QFileInfo file(reader ? reader->fileUrl().toLocalFile() : QString{});
        const auto title=reader && reader->pageCount() ? reader->title() : tr("Empty reader");
        const auto folder=reader && !reader->fileUrl().isEmpty() ? file.dir().dirName() : QString{};
        const auto label=folder.isEmpty() ? tr("Window %2 · %1").arg(title).arg(number) : tr("Window %3 · %1 — %2").arg(title,folder).arg(number);
        result.append(QVariantMap{{QStringLiteral("windowId"),candidate->windowTransferId()},{QStringLiteral("title"),label},{QStringLiteral("detail"),(candidate->m_tabs.size()==1 ? tr("1 tab") : tr("%1 tabs").arg(candidate->m_tabs.size()))}});
    }
    return result;
}
void WorkspaceController::moveActiveTabToWindow(const QString &targetId,ReaderController *expectedReader,qulonglong expectedGeneration) {
    if(m_tabTransfer)return;
    if(!expectedReader || expectedReader!=activeReader() || expectedReader->documentGeneration()!=expectedGeneration) {
        emit tabTransferFailed(tr("The active tab changed while the window menu was open. Nothing was moved."));return;
    }
    for(auto *candidate:workspaces())if(candidate->windowTransferId()==targetId && candidate!=this) {
        emit moveTabToWindowRequested(candidate,expectedReader,expectedGeneration,nullptr);return;
    }
    emit tabTransferFailed(tr("The selected reader window is no longer available. Nothing was moved."));
}
QuitCoordinator *WorkspaceController::quitCoordinator()const{return QuitCoordinator::instance();}
void WorkspaceController::publishRecents(const QVariantList &entries) {
    // Signals can close another window; never keep an unguarded raw pointer across one.
    QList<QPointer<WorkspaceController>> recipients;
    for(auto *workspace:workspaces())recipients.append(workspace);
    for(const auto &workspace:recipients)if(workspace && workspace->m_recent!=entries) {
        workspace->m_recent=entries;emit workspace->recentDocumentsChanged();
    }
}
void WorkspaceController::connectReader(ReaderController *reader) {
    m_readerConnections.insert(reader,{
        connect(reader,&ReaderController::documentChanged,this,&WorkspaceController::tabsChanged),
        connect(reader,&ReaderController::loadingChanged,this,&WorkspaceController::tabsChanged),
        connect(reader,&ReaderController::openFinished,this,[this,reader](bool success){if(success)remember(reader);}),
        connect(reader,&ReaderController::pageReady,this,[this,reader](int page,double scale){if(page==0)rememberCover(reader,scale);}),
        connect(reader,&QObject::destroyed,this,[this,reader]{m_coverAttempts.remove(reader);})
    });
}
ReaderController *WorkspaceController::appendTab(bool notify) {
    auto *reader = new ReaderController(this);
    QQmlEngine::setObjectOwnership(reader,QQmlEngine::CppOwnership);
    m_tabs.append(reader);
    connectReader(reader);
    if(notify)emit tabsChanged();
    return reader;
}
QVariantList WorkspaceController::tabs() const {
    QVariantList result;
    for (auto *reader : m_tabs) result.append(QVariantMap{
        {QStringLiteral("title"),reader->title()}, {QStringLiteral("loading"),reader->loading()},
        {QStringLiteral("reader"),QVariant::fromValue(reader)}, {QStringLiteral("url"),reader->fileUrl()}
    });
    return result;
}
ReaderController *WorkspaceController::activeReader() const { return m_tabs.value(m_activeIndex); }
void WorkspaceController::selectTab(int index) {
    if (m_tabTransfer || index < 0 || index >= m_tabs.size() || index == m_activeIndex) return;
    m_preview->close();
    emit activeReaderAboutToChange();
    m_activeIndex = index;
    emit activeReaderChanged();
}
bool WorkspaceController::moveTab(ReaderController *reader,ReaderController *before) {
    if(m_tabTransfer)return false;
    auto destination=[&]() {
        const auto source=m_tabs.indexOf(reader),gap=before ? m_tabs.indexOf(before) : m_tabs.size();
        if(source<0 || gap<0)return qsizetype(-1);
        const auto result=gap>source ? gap-1 : gap;
        return result==source ? qsizetype(-1) : result;
    };
    if(destination()<0)return false;
    const bool changing=reader!=activeReader();
    QPointer<WorkspaceController> guard(this);
    if(changing){emit activeReaderAboutToChange();if(!guard)return false;}
    const auto target=destination();
    if(target<0)return false;
    if(changing)m_preview->close();
    m_tabs.move(m_tabs.indexOf(reader),target);
    m_activeIndex=int(target);
    emit tabsChanged();
    if(guard)emit activeReaderChanged();
    return true;
}
QString WorkspaceController::tabTransferBlockReason(ReaderController *reader) const {
    if(quitCoordinator()->busy())return tr("Finish or cancel quitting before moving a tab.");
    if(m_credentials->busy())return tr("Wait for the credential operation to finish before moving a tab.");
    if(m_printJobs)return tr("Wait for printing to finish before moving a tab.");
    if(!reader || !m_tabs.contains(reader))return tr("The selected tab is no longer available.");
    if(const auto error=readerTransferBlockReason(reader,false);!error.isEmpty())return error;
    for(const auto *other:m_tabs)if(other!=reader && sameLocalFile(other->fileUrl(),reader->fileUrl()))
        return tr("The same PDF is open in another tab here. Close that copy before moving this tab.");
    return {};
}
QString WorkspaceController::readerTransferBlockReason(const ReaderController *reader,bool allowEmpty) {
    if(!reader || ((!reader->pageCount() || reader->fileUrl().isEmpty()) && !(allowEmpty && !reader->pageCount() && reader->fileUrl().isEmpty() && !reader->loading())))
        return tr("Open a PDF before moving this tab.");
    if(reader->loading() || reader->pendingCommands() || reader->regionPersistencePending())return tr("Wait for the document operation to finish before moving this tab.");
    if(reader->hasUnsavedChanges() || reader->hasUnsavedReadingNotes())return tr("Save or review the unsaved changes before moving this tab. Nothing was moved.");
    const auto readingPhase=reader->documentReading().value(QStringLiteral("phase")).toString();
    if(reader->aiState().value(QStringLiteral("running")).toBool() || QStringList{QStringLiteral("preparing"),QStringLiteral("starting"),QStringLiteral("reading"),QStringLiteral("stopping")}.contains(readingPhase))
        return tr("Stop the active AI request before moving this tab.");
    return {};
}
void WorkspaceController::detachActiveTab() {
    if(m_tabTransfer)return;
    if (auto *reader=activeReader()) emit detachTabRequested(reader,reader->documentGeneration());
}
QString WorkspaceController::prepareNativeTabDrag(ReaderController *reader) {
    auto &drag=nativeTabDrag();
    if (drag || m_tabTransfer) return {};
    if (const auto reason=tabTransferBlockReason(reader); !reason.isEmpty()) {
        emit tabTransferFailed(reason);
        return {};
    }
    const auto token=QUuid::createUuid().toString(QUuid::WithoutBraces);
    drag=NativeTabDrag{token,this,reader,activeReader(),reader->documentGeneration(),reader->editRevision(),{}};
    return token;
}
bool WorkspaceController::nativeTabDragInProgress() const {
    return nativeTabDrag().has_value();
}
bool WorkspaceController::acceptsNativeTabDrag(const QString &token, bool newWindow) const {
    const auto &drag=nativeTabDrag();
    return drag && !drag->drop && token==drag->token && drag->stillAvailable() &&
        !m_tabTransfer && activeReader() && (!newWindow || drag->source==this);
}
bool WorkspaceController::queueNativeTabDrop(const QString &token, ReaderController *before, bool newWindow) {
    if (!acceptsNativeTabDrag(token,newWindow) || (before && (newWindow || !m_tabs.contains(before)))) return false;
    auto *active=activeReader();
    nativeTabDrag()->drop=TabDrop{this,before,active,active->documentGeneration(),before!=nullptr,newWindow};
    return true;
}
void WorkspaceController::finishNativeTabDrag(const QString &token, bool moved) {
    auto &current=nativeTabDrag();
    if (!current || current->source!=this || current->token!=token) return;
    auto drag=std::move(*current);
    current.reset();
    if (!moved || !drag.drop) return;

    // Qt still owns the drag gesture while dragFinished handlers unwind. Transfer
    // afterwards so closing an emptied source cannot delete any event receiver.
    QTimer::singleShot(0,this,[drag=std::move(drag)] {
        auto &source=drag.source;
        const auto &drop=*drag.drop;
        if (!source) return;
        auto *sourceWindow=source->readerWindow();
        auto *destinationWindow=drop.window ? drop.window->readerWindow() : nullptr;
        if (!drag.stillAvailable() || !drop.stillAvailable() || !sourceWindow ||
            !sourceWindow->isVisible() || !destinationWindow || !destinationWindow->isVisible()) {
            emit source->tabTransferFailed(tr("The tab or window changed during the drag. Nothing was moved."));
            return;
        }
        if (drop.newWindow) {
            emit source->detachTabRequested(drag.reader,drag.generation);
        } else if (drop.window!=source) {
            emit source->moveTabToWindowRequested(drop.window,drag.reader,drag.generation,drop.before);
        } else {
            QMetaObject::invokeMethod(sourceWindow,"reorderReaderTab",Q_ARG(QVariant,QVariant::fromValue(drag.reader.data())),
                                      Q_ARG(QVariant,QVariant::fromValue(drop.before.data())),Q_ARG(QVariant,false));
        }
    });
}
QString WorkspaceController::transferActiveTabTo(WorkspaceController *target,QPointer<ReaderController> *emptySource) {
    return transferTabTo(target,activeReader(),nullptr,emptySource);
}
QString WorkspaceController::transferTabTo(WorkspaceController *target, ReaderController *requested, ReaderController *before,
                                           QPointer<ReaderController> *emptySource) {
    if(emptySource)*emptySource=nullptr;
    const auto unavailable=tr("The reader windows changed while preparing the move. The tab was not moved.");
    if(!target || target==this || m_tabTransfer || target->m_tabTransfer)return unavailable;
    QPointer<WorkspaceController> source(this),destination(target);
    QPointer<ReaderController> reader(requested),sourceActive(activeReader()),targetActive(target->activeReader()),anchor(before);
    const auto sourceTabs=m_tabs,targetTabs=target->m_tabs;
    const auto sourceIndex=sourceTabs.indexOf(reader);
    const auto destinationIndex=before ? targetTabs.indexOf(before) : targetTabs.size();
    if(sourceIndex<0 || destinationIndex<0)return unavailable;
    const bool movingActive=reader==sourceActive;
    const auto document=reader ? reader->documentHandle() : nullptr;
    const auto generation=reader ? reader->documentGeneration() : 0;
    const auto revision=reader ? reader->editRevision() : 0;
    const auto targetDocument=targetActive ? targetActive->documentHandle() : nullptr;
    const auto targetGeneration=targetActive ? targetActive->documentGeneration() : 0;
    const auto targetRevision=targetActive ? targetActive->editRevision() : 0;
    const bool replaceEmpty=targetTabs.size()==1 && targetActive && !targetActive->pageCount() && targetActive->fileUrl().isEmpty() && targetActive->aiState().isEmpty();
    const auto unchanged=[&] {
        return source && destination && reader && sourceActive && targetActive && (!before || anchor) &&
            source->m_tabs==sourceTabs && destination->m_tabs==targetTabs && source->activeReader()==sourceActive && destination->activeReader()==targetActive &&
            reader->documentHandle()==document && reader->documentGeneration()==generation && reader->editRevision()==revision &&
            targetActive->documentHandle()==targetDocument && targetActive->documentGeneration()==targetGeneration && targetActive->editRevision()==targetRevision && (!replaceEmpty || targetActive->aiState().isEmpty());
    };
    QVariantMap sourceAiSettings,targetAiSettings;
    auto windowReason=[&](WorkspaceController *workspace) {
        if(auto *window=workspace->readerWindow()) {
            if(!window->isVisible() && (workspace==source || !replaceEmpty))return unavailable;
            for(auto *child:QGuiApplication::topLevelWindows())if(child!=window && child->isVisible() && (child->flags() & Qt::WindowType_Mask)==Qt::Dialog) {
                QSet<QWindow *> seen;
                for(auto *parent=child->transientParent();parent && !seen.contains(parent);parent=parent->transientParent()) {
                    if(parent==window)return tr("Close the child window before moving this tab. Its input stays here.");
                    seen.insert(parent);
                }
            }
            QVariant reason;
            if(!QMetaObject::invokeMethod(window,"tabTransferUiBlockReason",Q_RETURN_ARG(QVariant,reason)))return tr("This reader window cannot prepare a tab move.");
            const auto value=window->property("aiSettings");
            const auto settings=(value.metaType()==QMetaType::fromType<QJSValue>() ? value.value<QJSValue>().toVariant() : value).toMap();
            if(workspace==source)sourceAiSettings=settings;else targetAiSettings=settings;
            return reason.toString();
        }
        return tr("A reader window is no longer available.");
    };
    const auto validate=[&]() -> QString {
        if(!unchanged())return unavailable;
        if(destination->m_credentials->busy())return tr("Wait for the other window's credential operation to finish before moving this tab.");
        if(destination->m_printJobs)return tr("Wait for printing in the other window to finish before moving this tab.");
        auto error=source->tabTransferBlockReason(reader);
        if(!error.isEmpty())return error;
        error=readerTransferBlockReason(targetActive,true);
        if(!error.isEmpty())return tr("The other window is not ready: %1").arg(error);
        for(auto *other:targetTabs)if(sameLocalFile(other->fileUrl(),reader->fileUrl()))
            return tr("The other window already has this PDF open. Nothing was moved.");
        error=windowReason(source);
        if(!unchanged())return unavailable;
        if(!error.isEmpty())return error;
        error=windowReason(destination);
        if(!unchanged())return unavailable;
        if(!error.isEmpty())return error;
        const auto ai=reader->aiState();
        const bool prepared=(!ai.value(QStringLiteral("plan")).toMap().isEmpty() && !ai.value(QStringLiteral("planSent")).toBool()) || reader->documentReading().value(QStringLiteral("phase")).toString()==QStringLiteral("preview");
        if(prepared && sourceAiSettings!=targetAiSettings)
            return tr("The windows use different AI settings. Update Settings before moving a prepared request. Nothing was moved.");
        return {};
    };
    if(const auto error=validate();!error.isEmpty())return error;
    m_tabTransfer=target->m_tabTransfer=true;
    const auto release=qScopeGuard([source,destination]{
        if(source)source->m_tabTransfer=false;
        if(destination)destination->m_tabTransfer=false;
        if(source)emit source->tabTransferStateChanged();
        if(destination)emit destination->tabTransferStateChanged();
    });
    emit tabTransferStateChanged();
    if(!unchanged())return unavailable;
    emit target->tabTransferStateChanged();
    if(const auto error=validate();!error.isEmpty())return error;
    if(movingActive)emit activeReaderAboutToChange();
    if(const auto error=validate();!error.isEmpty())return error;
    emit target->activeReaderAboutToChange();
    if(const auto error=validate();!error.isEmpty())return error;
    if(movingActive)m_preview->close();
    if(!unchanged())return unavailable;
    target->m_preview->close();
    if(const auto error=validate();!error.isEmpty())return error;

    // Commit ownership and both lists before emitting any model notification. The
    // Reader (Rust document, immutable sources, workers, history and AI state) stays
    // alive; no open/reset/generation bump or second PDF writer is introduced.
    const auto oldIndex=m_activeIndex;
    for(const auto &connection:m_readerConnections.take(reader))QObject::disconnect(connection);
    if(replaceEmpty)for(const auto &connection:target->m_readerConnections.take(targetActive))QObject::disconnect(connection);
    const auto view=m_views.take(reader);
    m_tabs.removeAt(sourceIndex);
    if(m_tabs.isEmpty()){auto *blank=appendTab(false);if(emptySource)*emptySource=blank;}
    m_activeIndex=movingActive ? qBound(0,oldIndex,int(m_tabs.size())-1) : int(m_tabs.indexOf(sourceActive));
    if(replaceEmpty){target->m_views.remove(targetActive);target->m_tabs.clear();}
    const auto insertedAt=replaceEmpty ? 0 : destinationIndex;
    target->m_tabs.insert(insertedAt,reader);
    target->m_activeIndex=int(insertedAt);
    target->m_views.insert(reader,view);
    reader->setParent(target);
    target->connectReader(reader);
    if(replaceEmpty)targetActive->deleteLater();
    const bool sourceChanged=movingActive || m_activeIndex!=oldIndex;
    emit tabsChanged();
    if(source && sourceChanged)emit source->activeReaderChanged();
    if(destination)emit destination->tabsChanged();
    if(destination)emit destination->activeReaderChanged();
    return {};
}
void WorkspaceController::openFiles(const QList<QUrl> &urls) { for (const auto &url : urls) openFile(url); }
void WorkspaceController::openFile(const QUrl &url) {
    if (m_tabTransfer || !url.isLocalFile()) return;
    const auto path = QFileInfo(url.toLocalFile()).absoluteFilePath();
    for (int i = 0; i < m_tabs.size(); ++i) {
        if (m_tabs.at(i)->fileUrl().toLocalFile() == path) { selectTab(i); return; }
    }
    auto *reader = activeReader();
    if (!reader || reader->loading() || reader->pageCount() || !reader->fileUrl().isEmpty()) {
        reader = appendTab();
        selectTab(int(m_tabs.size()) - 1);
    }
    reader->openFile(QUrl::fromLocalFile(path));
}
void WorkspaceController::requestQuit() {
    quitCoordinator()->request(this);
}

void WorkspaceController::newTab() {
    if(m_tabTransfer)return;
    appendTab();
    selectTab(int(m_tabs.size()) - 1);
}
void WorkspaceController::closeTab(int index, bool discardPending) {
    if (m_tabTransfer || index < 0 || index >= m_tabs.size()) return;
    auto *candidate=m_tabs.at(index);
    candidate->flushAiRegionNote();
    candidate->flushAiChatDraft(true);
    const auto marks=candidate->data().value(QStringLiteral("marks")).toMap();
    if(candidate->pendingCommands()>0 || candidate->regionPersistencePending() || candidate->hasUnsavedReadingNotes() || candidate->chatDraftPending() || candidate->hasUnsavedChanges() ||
        (discardPending && marks.value(QStringLiteral("page_session_active")).toBool())) {
        emit closeTabRequested(index);
        return;
    }
    if(candidate==activeReader())m_preview->close();
    emit activeReaderAboutToChange();
    auto *reader = m_tabs.takeAt(index);
    m_readerConnections.remove(reader);
    m_views.remove(reader);
    reader->deleteLater(); // Outstanding workers own their Rust handles independently.
    if (m_tabs.isEmpty()) appendTab();
    if (index < m_activeIndex) --m_activeIndex;
    m_activeIndex = qBound(0, m_activeIndex, int(m_tabs.size()) - 1);
    emit tabsChanged();
    emit activeReaderChanged();
}
void WorkspaceController::openInNewWindow(const QUrl &url,int page,double y) {emit newWindowRequested(url,page,std::isfinite(y)?qMax(0.0,y):0.0);}
QVariantMap WorkspaceController::viewState(ReaderController *reader) const {
    if (m_views.contains(reader)) return m_views.value(reader);
    QSettings settings;
    return settings.value(positionKey(reader)).toMap();
}
void WorkspaceController::saveViewState(ReaderController *reader, const QVariantMap &state) {
    if (!reader) return;
    m_views.insert(reader,state);
    if (!reader->fileUrl().isEmpty()) {
        QSettings settings;
        settings.setValue(positionKey(reader),state);
    }
}
void WorkspaceController::remember(ReaderController *reader) {
    QSettings settings;
    auto entries=normalizedRecents(settings.value(QStringLiteral("reader/recentDocuments")).toList());
    const auto url = reader->fileUrl().toString();
    const auto id=reader->data().value(QStringLiteral("document_id")).toString();
    QVariantMap entry;
    for (auto it=entries.begin();it!=entries.end();) {
        if (it->toMap().value(QStringLiteral("url")).toString()==url
                || (RecentCoverCache::validDocumentId(id) && it->toMap().value(QStringLiteral("documentId")).toString()==id)) {entry=it->toMap();it=entries.erase(it);}
        else ++it;
    }
    if(entry.value(QStringLiteral("documentId")).toString()!=id)entry.remove(QStringLiteral("coverKey"));
    entry.insert(QStringLiteral("url"),url);entry.insert(QStringLiteral("title"),reader->title());
    entry.insert(QStringLiteral("documentId"),id);entry.insert(QStringLiteral("openedAt"),QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    entries.prepend(entry);entries=normalizedRecents(entries);
    settings.setValue(QStringLiteral("reader/recentDocuments"),entries);
    publishRecents(entries);
}
void WorkspaceController::rememberCover(ReaderController *reader,double scale) {
    const auto generation=reader->documentGeneration();const auto id=reader->data().value(QStringLiteral("document_id")).toString();
    if(!RecentCoverCache::validDocumentId(id))return;
    auto pixels=reader->cachedPage(0,scale,true);const int quality=pixels.isNull()?1:2;
    if(pixels.isNull())pixels=reader->cachedBackdrop(0);
    if(pixels.isNull() || pixels.width()>512 || pixels.height()>1024)return;
    const auto previous=m_coverAttempts.value(reader);
    if(previous.first==generation && previous.second>=quality)return;
    if(coverJobs().fetch_add(1)>=4){coverJobs().fetch_sub(1);return;}
    auto retained=ResidentImage::retain(pixels);
    if(retained.isNull()){coverJobs().fetch_sub(1);return;}
    m_coverAttempts.insert(reader,{generation,quality});
    const auto url=reader->fileUrl().toString();QPointer<ReaderController> owner(reader);
    auto *watcher=new QFutureWatcher<QPair<QString,QString>>(this);
    connect(watcher,&QFutureWatcher<QPair<QString,QString>>::finished,this,[this,watcher,owner,generation,id,url] {
        const auto result=watcher->result();watcher->deleteLater();
        if(!result.second.isEmpty()) {
            qWarning().noquote()<<"lyra-reader-recent-cover:"<<result.second;
            if(owner && m_coverAttempts.value(owner).first==generation)m_coverAttempts.remove(owner);
        }
        if(result.first.isEmpty() || !owner || owner->documentGeneration()!=generation || owner->fileUrl().toString()!=url
                || owner->data().value(QStringLiteral("document_id")).toString()!=id)return;
        QSettings settings;auto entries=normalizedRecents(settings.value(QStringLiteral("reader/recentDocuments")).toList());
        bool changed=false;
        for(auto &value:entries) {auto entry=value.toMap();
            if(entry.value(QStringLiteral("url")).toString()==url && entry.value(QStringLiteral("documentId")).toString()==id) {
                entry.insert(QStringLiteral("coverKey"),result.first);value=entry;changed=true;
            }
        }
        if(changed){settings.setValue(QStringLiteral("reader/recentDocuments"),entries);publishRecents(entries);}
    });
    watcher->setFuture(QtConcurrent::run(coverPool(),[id,retained=std::move(retained)] {
        const auto finish=qScopeGuard([]{coverJobs().fetch_sub(1);});QString error;
        const auto key=RecentCoverCache::write(id,retained.pixels,&error);return qMakePair(key,error);
    }));
}
void WorkspaceController::clearRecentDocuments() {
    QSettings settings;
    settings.remove(QStringLiteral("reader/recentDocuments"));
    publishRecents({});
}
void WorkspaceController::copyText(const QString &text) { QGuiApplication::clipboard()->setText(text); }
void WorkspaceController::openExternal(const QUrl &url) {
    if (url.scheme()==QStringLiteral("https") || url.scheme()==QStringLiteral("http") || url.scheme()==QStringLiteral("mailto"))
        QDesktopServices::openUrl(url);
}
QVariantList WorkspaceController::readingPresets() const {
    return {
        QVariantMap{{"id","original"},{"title",tr("Original Colours")},{"appearance","light"}},
        QVariantMap{{"id","warm"},{"title",tr("Warm Paper")},{"appearance","light"}},
        QVariantMap{{"id","night"},{"title",tr("Night Reading · Dark Paper")},{"appearance","dark"}},
        QVariantMap{{"id","nightWhite"},{"title",tr("Night Reading · White Paper")},{"appearance","dark"}}
    };
}
QVariantMap WorkspaceController::readingPresetSnapshot() const {return readingPresetState();}
bool WorkspaceController::applyReadingPreset(const QString &id) {
    QVariantMap chosen;
    for(const auto &value:readingPresets())if(value.toMap().value("id").toString()==id){chosen=value.toMap();break;}
    if(chosen.isEmpty())return false;
    const QString paper=chosen.value("id").toString(),appearance=chosen.value("appearance").toString();
    setPreference(QStringLiteral("paper"),paper);
    setPreference(QStringLiteral("appearance"),appearance);
    const auto revision=++readingPresetRevision();
    readingPresetState()={{"paper",paper},{"appearance",appearance},{"revision",QVariant::fromValue(revision)}};
    QList<QPointer<WorkspaceController>> recipients;
    for(auto *workspace:workspaces())recipients.append(workspace);
    // UI-owned workspaces can close or apply a newer preset from a direct notification.
    // Snapshot getters always expose the latest pair, and an older publish stops here.
    for(const auto &workspace:recipients) {
        if(revision!=readingPresetRevision())break;
        if(workspace)emit workspace->readingPresetChanged();
    }
    return true;
}
QVariantList WorkspaceController::regionConversationStyles() const {
    return {QVariantMap{{"id","window"},{"title",tr("Window")}},
            QVariantMap{{"id","parchment"},{"title",tr("Parchment")}}};
}
QString WorkspaceController::regionConversationStyle() const {
    return preference(QStringLiteral("lyra.regionConversationStyle"),QStringLiteral("parchment")).toString();
}
bool WorkspaceController::applyRegionConversationStyle(const QString &id) {
    bool supported=false;
    for(const auto &value:regionConversationStyles())if(value.toMap().value("id").toString()==id){supported=true;break;}
    if(!supported)return false;
    setPreference(QStringLiteral("lyra.regionConversationStyle"),id);
    const auto revision=++regionStyleRevision();
    QList<QPointer<WorkspaceController>> recipients;
    for(auto *workspace:workspaces())recipients.append(workspace);
    // Direct UI observers may close a workspace or choose a newer style.
    for(const auto &workspace:recipients) {
        if(revision!=regionStyleRevision())break;
        if(workspace)emit workspace->regionConversationStyleChanged();
    }
    return true;
}
namespace {
QVariantMap settingsFailure(const QString &message) {return {{"valid",false},{"code","inspection_failed"},{"message",message}};}
QVariantMap inspectNativeSettings(const std::function<bool(LyraReaderBuffer *,LyraReaderBuffer *)> &inspect,const QString &failure,const QString &invalidResponse) {
    LyraReaderBuffer output{},error{};
    const auto cleanup=qScopeGuard([&]{lyra_reader_desktop_buffer_free(output);lyra_reader_desktop_buffer_free(error);});
    if(!inspect(&output,&error))return settingsFailure(error.data ? QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len)) : failure);
    QJsonParseError parse;
    const auto result=QJsonDocument::fromJson(QByteArray::fromRawData(reinterpret_cast<const char *>(output.data),qsizetype(output.len)),&parse);
    if(parse.error!=QJsonParseError::NoError || !result.isObject() || !result.object().value("valid").isBool())return settingsFailure(invalidResponse);
    return result.object().toVariantMap();
}
}
QVariantMap WorkspaceController::inspectReasoning(const QString &mode,const QString &encoding) const {
    if(mode.size()>64 || encoding.size()>64)return settingsFailure(tr("Invalid reasoning inspection input."));
    const auto modeBytes=mode.toUtf8(),encodingBytes=encoding.toUtf8();
    return inspectNativeSettings([&](LyraReaderBuffer *output,LyraReaderBuffer *error){return lyra_reader_desktop_inspect_reasoning(reinterpret_cast<const std::uint8_t *>(modeBytes.constData()),std::size_t(modeBytes.size()),reinterpret_cast<const std::uint8_t *>(encodingBytes.constData()),std::size_t(encodingBytes.size()),output,error);},tr("The reasoning settings could not be inspected."),tr("The reasoning inspection returned an invalid response."));
}
QVariantMap WorkspaceController::generationDefaults() const {
    return inspectNativeSettings([](LyraReaderBuffer *output,LyraReaderBuffer *error){return lyra_reader_desktop_generation_defaults(output,error);},tr("The generation defaults could not be loaded."),tr("The generation defaults returned an invalid response."));
}
QVariant WorkspaceController::preference(const QString &key,const QVariant &fallback) const {
    QSettings settings;
    const auto plainFallback=fallback.metaType()==QMetaType::fromType<QJSValue>() ? fallback.value<QJSValue>().toVariant() : fallback;
    const auto storedKey=QStringLiteral("reader/preferences/")+key;
    const auto value=settings.value(storedKey,plainFallback);
    if(!value.isValid() && settings.contains(storedKey)) {
        // Legacy QJSValue preferences cannot be deserialized. Keep the stored bytes for
        // diagnosis and use the caller's explicit default until the user saves settings.
        qWarning("lyra-reader-preferences: an unreadable preference was retained; using its requested default");
        return plainFallback;
    }
    return value;
}
void WorkspaceController::setPreference(const QString &key,const QVariant &value) {
    QSettings settings;
    const auto plain=value.metaType()==QMetaType::fromType<QJSValue>() ? value.value<QJSValue>().toVariant() : value;
    settings.setValue(QStringLiteral("reader/preferences/")+key,plain);
}
QString WorkspaceController::writeTextFile(const QUrl &url,const QString &text) {
    if (!url.isLocalFile()) return tr("Choose a local destination.");
    QSaveFile file(url.toLocalFile());
    if (!file.open(QIODevice::WriteOnly)) return file.errorString();
    const auto bytes=text.toUtf8();
    if (file.write(bytes)!=bytes.size() || !file.commit()) return file.errorString();
    return {};
}

void WorkspaceController::printDocument(ReaderController *reader,int currentPage) {
    if(!reader || !reader->pageCount())return;
    if(m_tabTransfer){emit printFinished(tr("Wait for the tab move to finish before printing."));return;}
    if(reader->pendingCommands()>0){emit printFinished(tr("Wait for the document operation to finish before printing."));return;}
    const auto document=reader->documentHandle();
    const auto pages=reader->pages();
    const auto revision=reader->editRevision();
    const QPointer<WorkspaceController> owner(this);
    const QPointer<ReaderController> readerGuard(reader);
    auto printer=std::make_shared<QPrinter>(QPrinter::HighResolution);
    printer->setDocName(reader->title());
    QPrintDialog dialog(printer.get());
    dialog.setMinMax(1,int(pages.size()));
    dialog.setOption(QAbstractPrintDialog::PrintPageRange,true);
    dialog.setOption(QAbstractPrintDialog::PrintCurrentPage,true);
    ++m_printJobs;
    const auto result=dialog.exec();
    if(!owner)return;
    --owner->m_printJobs;
    if(result!=QDialog::Accepted)return;
    if(!readerGuard || readerGuard->documentHandle()!=document || readerGuard->editRevision()!=revision) {
        emit owner->printFinished(tr("The document changed while the print dialog was open. Open Print again."));return;
    }
    owner->printDocumentToDevice(readerGuard,printer,currentPage);
}
void WorkspaceController::printDocumentToDevice(ReaderController *reader,const std::shared_ptr<QPrinter> &printer,int currentPage,bool showProgress) {
    if(!reader || !printer || !m_tabs.contains(reader) || !reader->pageCount())return;
    if(m_tabTransfer){emit printFinished(tr("Wait for the tab move to finish before printing."));return;}
    if(reader->pendingCommands()>0){emit printFinished(tr("Wait for the document operation to finish before printing."));return;}
    if(!printer->outputFileName().isEmpty()) {
        const auto destination=QUrl::fromLocalFile(printer->outputFileName());
        if(sameLocalFile(destination,reader->fileUrl()) || sameLocalFile(destination,QUrl::fromLocalFile(reader->data().value(QStringLiteral("document_revision")).toString()))) {
            emit printFinished(tr("Printing cannot overwrite the original PDF. Choose another destination."));return;
        }
    }
    const auto owner=QPointer<WorkspaceController>(this);
    ++m_printJobs;
    PdfPrintJob::start(reader->documentHandle(),reader->pages(),printer,currentPage,[owner](const QString &error){
        if(owner){--owner->m_printJobs;emit owner->printFinished(error);}
    },showProgress);
}
