#include "QuitCoordinator.h"
#include "WorkspaceController.h"
#include <QCoreApplication>
#include <QEvent>
#include <QFileInfo>
#include <QMetaObject>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QQuickItem>
#include <QSet>
#include <QJSValue>
#include <filesystem>

namespace {
bool sameFile(const QUrl &one,const QUrl &two) {
    if(!one.isLocalFile() || !two.isLocalFile() || one.toLocalFile().isEmpty() || two.toLocalFile().isEmpty())return false;
    const auto a=QFileInfo(one.toLocalFile()),b=QFileInfo(two.toLocalFile());
    auto key=[](const QFileInfo &f){const auto canonical=f.canonicalFilePath();return canonical.isEmpty() ? QFileInfo(f.absolutePath()).canonicalFilePath()+QLatin1Char('/')+f.fileName() : canonical;};
    if(key(a)==key(b))return true;
    std::error_code error;
    auto path=[](const QString &s){
#ifdef Q_OS_WIN
        return std::filesystem::path(s.toStdWString());
#else
        return std::filesystem::path(s.toStdString());
#endif
    };
    return std::filesystem::equivalent(path(a.absoluteFilePath()),path(b.absoluteFilePath()),error) && !error;
}
}
QuitCoordinator::QuitCoordinator(QObject *parent):QObject(parent) {
    m_timer.setInterval(30);
    connect(&m_timer,&QTimer::timeout,this,&QuitCoordinator::advance);
}
QuitCoordinator *QuitCoordinator::instance() {
    static QPointer<QuitCoordinator> coordinator;
    if(!coordinator)coordinator=new QuitCoordinator(QCoreApplication::instance());
    return coordinator;
}
QObject *QuitCoordinator::owner()const{return m_owner.data();}
QVariantList QuitCoordinator::documents()const {
    QVariantList result;
    for(const auto &document:m_documents)result.append(QVariantMap{{QStringLiteral("title"),document.reader ? document.reader->title() : tr("Closed document")},{QStringLiteral("summary"),document.summary},{QStringLiteral("copy"),document.copy}});
    return result;
}
bool QuitCoordinator::eventFilter(QObject *object,QEvent *event) {
    if(object==QCoreApplication::instance() && event->type()==QEvent::Quit && !m_accepting) {
        const auto all=WorkspaceController::allWorkspaces();
        WorkspaceController *owner=nullptr;QSet<QWindow *> seen;
        for(auto *window=QGuiApplication::focusWindow();window && !seen.contains(window);window=window->transientParent()) {
            seen.insert(window);auto *candidate=window->property("session").value<WorkspaceController *>();
            if(all.contains(candidate)){owner=candidate;break;}
        }
        if(!all.isEmpty()){request(owner ? owner : all.first());return true;}
    }
    return QObject::eventFilter(object,event);
}
void QuitCoordinator::request(WorkspaceController *owner) {
    if(busy() || !owner)return;
    ++m_epoch;m_owner=owner;m_windows.clear();m_documents.clear();m_completed=0;m_index=0;m_copyIndex=0;
    m_message=tr("Waiting for pending document changes…");m_phase=QStringLiteral("preparing");
    for(auto *workspace:WorkspaceController::allWorkspaces()) {
        QWindow *window=nullptr;
        for(auto *candidate:QGuiApplication::topLevelWindows())if(candidate->objectName()==QStringLiteral("readerWindow") && candidate->property("session").value<WorkspaceController *>()==workspace){window=candidate;break;}
        if(!window)continue;
        const auto quick=qobject_cast<QQuickWindow *>(window);
        m_windows.append({workspace,window,quick ? quick->contentItem()->isEnabled() : true});
        QVariant prepared;
        if(!QMetaObject::invokeMethod(window,"prepareForQuit",Q_RETURN_ARG(QVariant,prepared)) || !prepared.toBool()) {
            abort(tr("Finish the current save or close dialog before quitting."));return;
        }
    }
    if(m_windows.isEmpty()){abort(tr("No reader window is available to confirm quitting."));return;}
    for(const auto &entry:m_windows)if(entry.window && entry.workspace!=owner)if(auto *quick=qobject_cast<QQuickWindow *>(entry.window.data()))quick->contentItem()->setEnabled(false);
    for(const auto &entry:m_windows)if(entry.window && entry.workspace==owner){if(!entry.window->isVisible())entry.window->showNormal();entry.window->raise();entry.window->requestActivate();}
    emit changed();m_timer.start();advance();
}
void QuitCoordinator::collect() {
    for(auto &entry:m_windows) {
        if(!entry.workspace || !entry.window){abort(tr("A reader window changed while preparing to quit. Try again."));return;}
        for(const auto &tab:entry.workspace->tabs()) {
            auto *reader=tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>();
            entry.readers.append(reader);
            if(!reader || !reader->hasUnsavedChanges())continue;
            const auto marks=reader->data().value(QStringLiteral("marks")).toMap();QStringList parts;
            if(marks.value(QStringLiteral("page_pending")).toBool())parts.append(tr("page edits"));
            if(marks.value(QStringLiteral("pdf_dirty")).toBool())parts.append(tr("annotations or bookmarks"));
            if(reader->editDrafts().contains(QStringLiteral("forms")))parts.append(tr("form values"));
            if(reader->editDrafts().contains(QStringLiteral("content")))parts.append(tr("text draft"));
            if(!reader->noteDrafts().isEmpty())parts.append(tr("annotation note"));
            if(parts.isEmpty())parts.append(tr("unsaved changes"));
            m_documents.append({reader,reader->documentHandle(),reader->fileUrl(),{},reader->editDrafts(),reader->noteDrafts(),reader->editRevision(),reader->data().value(QStringLiteral("signature_status")).toMap().value(QStringLiteral("signed")).toBool(),parts.join(QStringLiteral(", "))});
        }
    }
    if(m_documents.isEmpty()){finish();return;}
    m_phase=QStringLiteral("prompt");m_message=tr("If you do not save, these changes will be lost and will not be restored the next time the documents are opened.");emit changed();
}
bool QuitCoordinator::unchanged(const Document &document)const {
    if(!document.reader || document.reader->documentHandle()!=document.handle || document.reader->loading() || document.reader->fileUrl()!=document.source || document.reader->editRevision()!=document.revision || document.reader->editDrafts()!=document.drafts || document.reader->noteDrafts()!=document.notes)return false;
    for(const auto &entry:m_windows)if(entry.workspace)for(const auto &tab:entry.workspace->tabs())if(tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>()==document.reader)return true;
    return false;
}
void QuitCoordinator::decide(const QString &decision) {
    if(m_phase!=QStringLiteral("prompt") || (decision!=QStringLiteral("save") && decision!=QStringLiteral("discard")))return;
    for(const auto &document:m_documents)if(!unchanged(document)){abort(tr("The documents changed after the quit prompt. No further changes were resolved; try again."));return;}
    m_decision=decision;m_index=0;m_copyIndex=0;
    if(decision==QStringLiteral("save")) {
        for(int i=0;i<m_documents.size();++i) {
            const auto &document=m_documents[i];const auto data=document.reader->data();
            if(!document.notes.isEmpty() || document.drafts.contains(QStringLiteral("content")) || document.drafts.contains(QStringLiteral("redactions"))) {abort(tr("Review unfinished text, note or redaction drafts before using Save All."));return;}
            const auto xfa=data.value(QStringLiteral("xfa_status")).toMap();
            if(xfa.value(QStringLiteral("is_xfa")).toBool()){abort(tr("This XFA document is read-only. Its local bookmarks can be kept by cancelling the quit."));return;}
            const auto error=data.value(QStringLiteral("marks")).toMap().value(QStringLiteral("error")).toString();
            if(!error.isEmpty()){abort(error);return;}
            if(document.reader->aiState().value(QStringLiteral("running")).toBool()){abort(tr("Stop the active AI request before saving and quitting."));return;}
            for(int j=0;j<i;++j)if(sameFile(document.source,m_documents[j].source)){abort(tr("The same PDF has unsaved changes in more than one tab or window. Save or discard one copy first. Nothing was saved."));return;}
        }
        askNextCopy();
    } else {
        for(const auto &window:m_windows)if(window.window)QMetaObject::invokeMethod(window.window,"prepareDiscardForQuit");
        m_phase=QStringLiteral("discarding");m_message=tr("Discarding document drafts…");emit changed();advance();
    }
}
void QuitCoordinator::askNextCopy() {
    while(m_copyIndex<m_documents.size() && !m_documents[m_copyIndex].copy)++m_copyIndex;
    if(m_copyIndex==m_documents.size()) {
        if(!preflightCopies())return;
        m_phase=QStringLiteral("saving");m_message=tr("Saving documents…");emit changed();advance();return;
    }
    const auto &document=m_documents[m_copyIndex];const QFileInfo source(document.source.toLocalFile());
    m_phase=QStringLiteral("copy");m_message=tr("Choose a copy for %1. No PDF has been written yet.").arg(document.reader->title());emit changed();
    const auto suggestion=QUrl::fromLocalFile(source.absolutePath()+QLatin1Char('/')+source.completeBaseName()+QStringLiteral(" (edited).pdf"));
    const auto title=document.reader->title();
    const auto epoch=m_epoch;const auto index=m_copyIndex;
    // Let a just-accepted native file panel finish closing before the next one opens.
    QMetaObject::invokeMethod(this,[this,suggestion,title,epoch,index]{if(m_epoch==epoch && m_copyIndex==index && m_phase==QStringLiteral("copy"))emit copyRequested(suggestion,title);},Qt::QueuedConnection);
}
void QuitCoordinator::chooseCopy(const QUrl &destination) {
    if(m_phase!=QStringLiteral("copy"))return;
    if(!destination.isLocalFile() || destination.toLocalFile().isEmpty()){cancel();return;}
    m_documents[m_copyIndex].destination=destination;++m_copyIndex;askNextCopy();
}
bool QuitCoordinator::preflightCopies() {
    for(int i=0;i<m_documents.size();++i) {
        const auto &document=m_documents[i];
        if(!unchanged(document)){abort(tr("The documents changed while choosing copies. Nothing was saved."));return false;}
        if(!document.copy)continue;
        for(const auto &window:m_windows)if(window.workspace)for(const auto &tab:window.workspace->tabs()) {
            auto *reader=tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>();
            if(reader && (sameFile(document.destination,reader->fileUrl()) || sameFile(document.destination,QUrl::fromLocalFile(reader->data().value(QStringLiteral("document_revision")).toString())))) {abort(tr("A copy cannot overwrite any open original or working PDF. Nothing was saved."));return false;}
        }
        for(int j=0;j<i;++j)if(m_documents[j].copy && sameFile(document.destination,m_documents[j].destination)){abort(tr("Two copies cannot use the same destination. Nothing was saved."));return false;}
    }
    return true;
}
void QuitCoordinator::startCommand(Document &document,const QString &operation) {
    if(!unchanged(document)){abort(tr("New changes remain unsaved. All reader windows stay open."));return;}
    QVariantMap arguments;
    if(operation!=QStringLiteral("document_discard")) {
        QVariantList forms;for(const auto &value:document.drafts.value(QStringLiteral("forms")).toMap())forms.append(value);
        arguments={{QStringLiteral("expected_revision"),document.reader->data().value(QStringLiteral("document_revision"))},{QStringLiteral("forms"),forms}};
        if(operation==QStringLiteral("save_document_copy"))arguments.insert(QStringLiteral("destination"),document.destination.toLocalFile());
        for(const auto &window:m_windows)if(window.workspace) {
            bool owns=false;for(const auto &tab:window.workspace->tabs())if(tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>()==document.reader){owns=true;break;}
            if(!owns)continue;
            if(window.workspace->activeReader()==document.reader) {
                QVariant result;
                if(!window.window || !QMetaObject::invokeMethod(window.window,"prepareQuitSave",Q_RETURN_ARG(QVariant,result),Q_ARG(QVariant,operation))){abort(tr("The reader could not preserve its position before saving. The quit was cancelled."));return;}
                const auto view=result.metaType()==QMetaType::fromType<QJSValue>() ? result.value<QJSValue>().toVariant().toMap() : result.toMap();
                for(auto it=view.cbegin();it!=view.cend();++it)arguments.insert(it.key(),it.value());
            } else {
                const auto page=window.workspace->viewState(document.reader).value(QStringLiteral("page"));bool valid=false;const auto index=page.toInt(&valid);
                if(valid && index>=0 && index<document.reader->pageCount())arguments.insert(QStringLiteral("current_page"),index);
            }
            break;
        }
    }
    m_connections.append(connect(document.reader,&ReaderController::commandFinished,this,&QuitCoordinator::finishCommand));
    m_operation=operation;m_draining=false;m_command=document.reader->submit(operation,arguments);document.revision=document.reader->editRevision();
}
void QuitCoordinator::finishCommand(quint64 id,const QString &operation,const QVariant &result,const QString &error) {
    if(m_index>=m_documents.size() || sender()!=m_documents[m_index].reader || id!=m_command || operation!=m_operation)return;
    for(const auto &connection:m_connections)disconnect(connection);m_connections.clear();
    if(!error.isEmpty()){abort(error);return;}
    ++m_completed;
    const auto map=result.toMap();const auto report=map.value(QStringLiteral("report"),map).toMap();
    for(const auto &key:{"cache_cleanup_error","sidecar_error","sidecar_cleanup_error","recovery_warning"})if(!report.value(QLatin1String(key)).toString().isEmpty()){abort(tr("The PDF operation completed, but its draft needs attention: %1").arg(report.value(QLatin1String(key)).toString()));return;}
    auto &document=m_documents[m_index];
    // These are the only draft changes the matching Rust command may resolve.
    if(operation==QStringLiteral("document_discard")){document.notes.clear();document.drafts.clear();}
    else if(operation==QStringLiteral("document_save"))document.drafts.remove(QStringLiteral("forms"));
    m_draining=true;QMetaObject::invokeMethod(this,&QuitCoordinator::advance,Qt::QueuedConnection);
}
void QuitCoordinator::advance() {
    if(!busy())return;
    if(!m_owner){abort(tr("The window confirming the quit was closed."));return;}
    const auto all=WorkspaceController::allWorkspaces();
    if(all.size()!=m_windows.size()){abort(tr("The reader windows changed while quitting. Try again."));return;}
    for(const auto &window:m_windows)if(!window.workspace || !window.window || !all.contains(window.workspace)){abort(tr("The reader windows changed while quitting. Try again."));return;}
    if(m_phase==QStringLiteral("preparing")) {
        for(const auto &window:m_windows)if(window.workspace)for(const auto &tab:window.workspace->tabs()){auto *reader=tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>();if(reader && (reader->loading() || reader->pendingCommands()>0))return;}
        collect();return;
    }
    if(m_phase!=QStringLiteral("saving") && m_phase!=QStringLiteral("discarding") && m_phase!=QStringLiteral("retiring"))return;
    if(m_command) {
        if(!m_draining)return;
        auto &document=m_documents[m_index];if(document.reader && document.reader->pendingCommands()>0)return;
        if(!unchanged(document)){abort(tr("New changes remain unsaved. All reader windows stay open."));return;}
        if(m_operation!=QStringLiteral("save_document_copy") && document.reader->hasUnsavedChanges()){abort(tr("Changes remain unsaved. All reader windows stay open."));return;}
        m_command=0;m_draining=false;++m_index;
    }
    if(m_index==m_documents.size()) {
        if(m_phase==QStringLiteral("saving")) {
            m_phase=QStringLiteral("retiring");m_message=tr("Retiring drafts saved to copies…");m_index=0;emit changed();
        } else {finish();return;}
    }
    while(m_phase==QStringLiteral("retiring") && m_index<m_documents.size() && !m_documents[m_index].copy)++m_index;
    if(m_index==m_documents.size()){finish();return;}
    auto &document=m_documents[m_index];
    startCommand(document,m_phase!=QStringLiteral("saving") ? QStringLiteral("document_discard") : document.copy ? QStringLiteral("save_document_copy") : QStringLiteral("document_save"));
}
void QuitCoordinator::cancel() {
    if(m_phase==QStringLiteral("preparing") || m_phase==QStringLiteral("prompt") || m_phase==QStringLiteral("copy"))abort({});
}
void QuitCoordinator::restoreWindows() {
    for(const auto &window:m_windows)if(auto *quick=qobject_cast<QQuickWindow *>(window.window.data()))quick->contentItem()->setEnabled(window.enabled);
}
void QuitCoordinator::abort(const QString &error) {
    m_timer.stop();for(const auto &connection:m_connections)disconnect(connection);m_connections.clear();restoreWindows();
    const auto detail=error.isEmpty() ? QString{} : m_completed>0 ? tr("%1 Earlier successful saves or discards remain completed; unresolved drafts and all reader windows stay open.").arg(error) : error;
    ++m_epoch;m_phase=QStringLiteral("idle");m_message=detail;m_command=0;m_draining=false;m_windows.clear();m_documents.clear();emit changed();emit finished(false,detail);
}
void QuitCoordinator::finish() {
    // No window disappears until all documents, including late drafts, are resolved.
    for(const auto &window:m_windows) {
        if(!window.window || !window.workspace || window.workspace->tabs().size()!=window.readers.size()){abort(tr("The reader tabs changed while resolving the quit."));return;}
        for(const auto &tab:window.workspace->tabs())if(!window.readers.contains(tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>())){abort(tr("The reader tabs changed while resolving the quit."));return;}
    }
    for(const auto &window:m_windows)for(const auto &tab:window.workspace->tabs()){auto *reader=tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>();if(reader && (reader->hasUnsavedChanges() || reader->pendingCommands()>0)){abort(tr("New changes remain unsaved. All reader windows stay open."));return;}}
    m_timer.stop();m_accepting=true;restoreWindows();
    for(const auto &window:m_windows)if(window.window)window.window->setProperty("closeApproved",true);
    for(const auto &window:m_windows)if(window.window)window.window->close();
    ++m_epoch;m_phase=QStringLiteral("idle");m_windows.clear();m_documents.clear();m_command=0;emit changed();emit finished(true,{});emit accepted();
    QMetaObject::invokeMethod(this,[this]{m_accepting=false;},Qt::QueuedConnection);
}
