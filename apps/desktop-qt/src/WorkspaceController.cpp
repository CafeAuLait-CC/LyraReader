#include "WorkspaceController.h"
#include "PdfPrintJob.h"
#include "LocalFileIdentity.h"
#include <QPrinter>
#include <QPrintDialog>
#include <QPointer>
#include <QFileInfo>
#include <QDir>
#include <QUuid>
#include <QSettings>
#include <QJSValue>
#include <QQmlEngine>
#include <QScopeGuard>
#include <QClipboard>
#include <QGuiApplication>
#include <QWindow>
#include <QDesktopServices>
#include <QCryptographicHash>
#include <QSaveFile>
#include <cmath>

namespace {
QList<WorkspaceController *> &workspaces() {static QList<WorkspaceController *> all;return all;}
QVariantList normalizedRecents(const QVariantList &entries) {
    QVariantList result;QSet<QString> seen;
    for(const auto &value:entries) {
        const auto entry=value.toMap();const QUrl url(entry.value(QStringLiteral("url")).toString());
        if(!url.isLocalFile())continue;
        const QFileInfo file(url.toLocalFile());const auto normalized=QUrl::fromLocalFile(file.absoluteFilePath()).toString();
        if(seen.contains(normalized))continue;
        seen.insert(normalized);
        const auto title=entry.value(QStringLiteral("title")).toString();
        result.append(QVariantMap{{QStringLiteral("url"),normalized},{QStringLiteral("title"),title.isEmpty()?file.fileName():title}});
        if(result.size()==20)break;
    }
    return result;
}
QString positionKey(const ReaderController *reader) {
    return QStringLiteral("reader/positions/") + QString::fromLatin1(QCryptographicHash::hash(
        reader->fileUrl().toEncoded(), QCryptographicHash::Sha256).toHex());
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
WorkspaceController::~WorkspaceController() {workspaces().removeAll(this);}
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
        const auto label=folder.isEmpty() ? tr("%1 · Window %2").arg(title).arg(number) : tr("%1 — %2 · Window %3").arg(title,folder).arg(number);
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
        emit moveActiveTabToWindowRequested(candidate,expectedReader,expectedGeneration);return;
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
        connect(reader,&ReaderController::openFinished,this,[this,reader](bool success){if(success)remember(reader);})
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
QString WorkspaceController::tabTransferBlockReason()const {
    const auto *reader=activeReader();
    if(quitCoordinator()->busy())return tr("Finish or cancel quitting before moving a tab.");
    if(m_credentials->busy())return tr("Wait for the credential operation to finish before moving a tab.");
    if(m_printJobs)return tr("Wait for printing to finish before moving a tab.");
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
    emit detachActiveTabRequested();
}
QString WorkspaceController::transferActiveTabTo(WorkspaceController *target,QPointer<ReaderController> *emptySource) {
    if(emptySource)*emptySource=nullptr;
    const auto unavailable=tr("The reader windows changed while preparing the move. The tab was not moved.");
    if(!target || target==this || m_tabTransfer || target->m_tabTransfer)return unavailable;
    QPointer<WorkspaceController> source(this),destination(target);
    QPointer<ReaderController> reader(activeReader()),targetActive(target->activeReader());
    const auto sourceTabs=m_tabs,targetTabs=target->m_tabs;
    const auto document=reader ? reader->documentHandle() : nullptr;
    const auto generation=reader ? reader->documentGeneration() : 0;
    const auto revision=reader ? reader->editRevision() : 0;
    const auto targetDocument=targetActive ? targetActive->documentHandle() : nullptr;
    const auto targetGeneration=targetActive ? targetActive->documentGeneration() : 0;
    const auto targetRevision=targetActive ? targetActive->editRevision() : 0;
    const bool replaceEmpty=targetTabs.size()==1 && targetActive && !targetActive->pageCount() && targetActive->fileUrl().isEmpty() && targetActive->aiState().isEmpty();
    const auto unchanged=[&] {
        return source && destination && reader && targetActive && source->m_tabs==sourceTabs && destination->m_tabs==targetTabs && source->activeReader()==reader && destination->activeReader()==targetActive &&
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
        auto error=source->tabTransferBlockReason();
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
    emit activeReaderAboutToChange();
    if(const auto error=validate();!error.isEmpty())return error;
    emit target->activeReaderAboutToChange();
    if(const auto error=validate();!error.isEmpty())return error;
    m_preview->close();
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
    m_tabs.removeAt(oldIndex);
    if(m_tabs.isEmpty()){auto *blank=appendTab(false);if(emptySource)*emptySource=blank;}
    m_activeIndex=qBound(0,oldIndex,int(m_tabs.size())-1);
    if(replaceEmpty){target->m_views.remove(targetActive);target->m_tabs.clear();}
    target->m_tabs.append(reader);target->m_activeIndex=int(target->m_tabs.size())-1;
    target->m_views.insert(reader,view);
    reader->setParent(target);
    target->connectReader(reader);
    if(replaceEmpty)targetActive->deleteLater();
    emit tabsChanged();
    if(source)emit source->activeReaderChanged();
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
    const auto marks=candidate->data().value(QStringLiteral("marks")).toMap();
    if(candidate->pendingCommands()>0 || candidate->regionPersistencePending() || candidate->hasUnsavedReadingNotes() || candidate->hasUnsavedChanges() ||
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
    for (auto it=entries.begin();it!=entries.end();) {
        if (it->toMap().value(QStringLiteral("url")).toString()==url) it=entries.erase(it);
        else ++it;
    }
    entries.prepend(QVariantMap{{QStringLiteral("url"),url},{QStringLiteral("title"),reader->title()}});
    while (entries.size()>20) entries.removeLast();
    settings.setValue(QStringLiteral("reader/recentDocuments"),entries);
    publishRecents(entries);
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
