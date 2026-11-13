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
#include <algorithm>
#include <vector>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QtConcurrentRun>
#include <utility>

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
    if(object==QCoreApplication::instance() && event->type()==QEvent::Quit) {
        if(m_accepting) {
            // The accepted application's queued Quit may arrive after the close
            // callbacks. Closed readers deliberately still own their recovery data.
            const auto windows=QGuiApplication::topLevelWindows();
            const bool newReader=std::any_of(windows.cbegin(),windows.cend(),[](QWindow *window){return window->objectName()==QStringLiteral("readerWindow") && window->isVisible();});
            if(!newReader)return false;
            m_accepting=false;
        }
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
    m_accepting=false;
    ++m_epoch;m_owner=owner;m_windows.clear();m_documents.clear();m_completed=0;m_index=0;m_copyIndex=0;m_resolved=false;m_receipt.clear();m_receiptDocument.reset();m_resolutionAborted=false;m_resolutionError.clear();
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
            if(reader && reader->hasUnsavedReadingNotes()){abort(tr("Save or discard the reading-note draft before quitting. All reader windows stay open."));return;}
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
        m_phase=QStringLiteral("discarding");m_message=tr("Recording the resolved quit…");emit changed();recordResolution();
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
    if(operation==QStringLiteral("document_save"))document.drafts.remove(QStringLiteral("forms"));
    m_draining=true;QMetaObject::invokeMethod(this,&QuitCoordinator::advance,Qt::QueuedConnection);
}
void QuitCoordinator::advance() {
    if(!busy())return;
    if(!m_owner){abort(tr("The window confirming the quit was closed."));return;}
    const auto all=WorkspaceController::allWorkspaces();
    if(all.size()!=m_windows.size()){abort(tr("The reader windows changed while quitting. Try again."));return;}
    for(const auto &window:m_windows)if(!window.workspace || !window.window || !all.contains(window.workspace)){abort(tr("The reader windows changed while quitting. Try again."));return;}
    if(m_phase==QStringLiteral("preparing")) {
        for(const auto &window:m_windows)if(window.workspace)for(const auto &tab:window.workspace->tabs()){auto *reader=tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>();if(reader && (reader->loading() || reader->pendingCommands()>0 || reader->regionPersistencePending()))return;}
        collect();return;
    }
    if(m_phase!=QStringLiteral("saving"))return;
    if(m_command) {
        if(!m_draining)return;
        auto &document=m_documents[m_index];if(document.reader && document.reader->pendingCommands()>0)return;
        if(!unchanged(document)){abort(tr("New changes remain unsaved. All reader windows stay open."));return;}
        if(m_operation!=QStringLiteral("save_document_copy") && document.reader->hasUnsavedChanges()){abort(tr("Changes remain unsaved. All reader windows stay open."));return;}
        m_command=0;m_draining=false;++m_index;
    }
    if(m_index==m_documents.size()){recordResolution();return;}
    auto &document=m_documents[m_index];
    startCommand(document,document.copy ? QStringLiteral("save_document_copy") : QStringLiteral("document_save"));
}
void QuitCoordinator::recordResolution() {
    for(const auto &document:m_documents)if(!unchanged(document) || document.reader->pendingCommands()>0){abort(tr("New changes remain unsaved. All reader windows stay open."));return;}
    if(m_documents.isEmpty()){finish();return;}
    std::vector<std::shared_ptr<LyraReaderDesktopDocument>> documents;
    for(const auto &document:m_documents)documents.push_back(document.handle);
    const auto epoch=m_epoch;const auto resolution=m_decision==QStringLiteral("save") ? 0u : 1u;
    m_recording=true;m_phase=QStringLiteral("recording");m_message=tr("Recording the resolved quit…");emit changed();
    struct Result {QByteArray receipt;QString error;};
    auto *watcher=new QFutureWatcher<Result>(this);
    connect(watcher,&QFutureWatcher<Result>::finished,this,[this,watcher,documents,epoch] {
        const auto result=watcher->result();watcher->deleteLater();
        m_recording=false;
        if(epoch!=m_epoch)return;
        if(!result.error.isEmpty()){abort(m_resolutionAborted?m_resolutionError:result.error);return;}
        m_receipt=result.receipt;m_receiptDocument=documents.front();m_resolved=true;
        if(m_resolutionAborted){abort(m_resolutionError);return;}
        const auto warning=QJsonDocument::fromJson(m_receipt).toVariant().toMap().value(QStringLiteral("warning")).toString();
        if(!warning.isEmpty()){abort(tr("The quit decision was committed, but its durability could not be confirmed: %1").arg(warning));return;}
        finish();
    });
    watcher->setFuture(QtConcurrent::run([documents,resolution] {
        std::vector<const LyraReaderDesktopDocument *> handles;for(const auto &document:documents)handles.push_back(document.get());
        LyraReaderBuffer output{},error{};const auto ok=lyra_reader_desktop_resolve_quit(handles.data(),handles.size(),resolution,&output,&error);
        Result result;if(ok)result.receipt=QByteArray(reinterpret_cast<const char *>(output.data),qsizetype(output.len));else result.error=QString::fromUtf8(reinterpret_cast<const char *>(error.data),qsizetype(error.len));
        lyra_reader_desktop_buffer_free(output);lyra_reader_desktop_buffer_free(error);return result;
    }));
}
void QuitCoordinator::cancel() {
    if(m_phase==QStringLiteral("preparing") || m_phase==QStringLiteral("prompt") || m_phase==QStringLiteral("copy"))abort({});
}
void QuitCoordinator::restoreWindows() {
    for(const auto &window:m_windows)if(auto *quick=qobject_cast<QQuickWindow *>(window.window.data()))quick->contentItem()->setEnabled(window.enabled);
}
void QuitCoordinator::abort(const QString &error) {
    if(m_phase==QStringLiteral("cancelling"))return;
    if(m_recording){m_timer.stop();m_resolutionAborted=true;m_resolutionError=error;return;}
    m_timer.stop();for(const auto &connection:m_connections)disconnect(connection);m_connections.clear();
    if(!m_receipt.isEmpty()) {
        const auto receipt=std::exchange(m_receipt,{});const auto document=std::move(m_receiptDocument);m_resolved=false;m_phase=QStringLiteral("cancelling");
        auto *watcher=new QFutureWatcher<QString>(this);
        connect(watcher,&QFutureWatcher<QString>::finished,this,[this,watcher,error] {
            const auto cancellation=watcher->result();watcher->deleteLater();m_phase=QStringLiteral("recording");
            abort(cancellation.isEmpty()?error:tr("%1 The quit receipt could not be cancelled: %2. The stored decision may still resolve the earlier drafts on reopen. Keep these windows open and back up recovery data before closing.").arg(error,cancellation));
        });
        watcher->setFuture(QtConcurrent::run([document,receipt] {
            LyraReaderBuffer failure{};const auto ok=lyra_reader_desktop_cancel_quit(document.get(),reinterpret_cast<const std::uint8_t *>(receipt.constData()),std::size_t(receipt.size()),&failure);
            const auto message=ok?QString{}:QString::fromUtf8(reinterpret_cast<const char *>(failure.data),qsizetype(failure.len));lyra_reader_desktop_buffer_free(failure);return message;
        }));return;
    }
    restoreWindows();
    const auto detail=error.isEmpty() ? QString{} : m_completed>0 ? tr("%1 Earlier successful saves remain completed; unresolved drafts and all reader windows stay open.").arg(error) : error;
    ++m_epoch;m_phase=QStringLiteral("idle");m_message=detail;m_command=0;m_draining=false;m_windows.clear();m_documents.clear();emit changed();emit finished(false,detail);
}
void QuitCoordinator::finish() {
    // No window disappears until all documents, including late drafts, are resolved.
    const auto all=WorkspaceController::allWorkspaces();
    if(all.size()!=m_windows.size()){abort(tr("The reader windows changed while resolving the quit. Try again."));return;}
    for(const auto &window:m_windows) {
        if(!window.window || !window.workspace || !all.contains(window.workspace) || window.workspace->tabs().size()!=window.readers.size()){abort(tr("The reader tabs changed while resolving the quit."));return;}
        for(const auto &tab:window.workspace->tabs())if(!window.readers.contains(tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>())){abort(tr("The reader tabs changed while resolving the quit."));return;}
    }
    for(const auto &document:m_documents)if(!unchanged(document)){abort(tr("New changes remain unsaved. All reader windows stay open."));return;}
    for(const auto &window:m_windows)for(const auto &tab:window.workspace->tabs()) {
        auto *reader=tab.toMap().value(QStringLiteral("reader")).value<ReaderController *>();if(!reader)continue;
        const bool resolved=m_resolved && std::any_of(m_documents.cbegin(),m_documents.cend(),[&](const Document &document){return document.reader==reader;});
        if((reader->hasUnsavedChanges() && !resolved) || reader->hasUnsavedReadingNotes() || reader->pendingCommands()>0){abort(tr("New changes remain unsaved. All reader windows stay open."));return;}
    }
    if(m_resolved) {
        LyraReaderBuffer failure{};
        const auto ok=lyra_reader_desktop_activate_quit(reinterpret_cast<const std::uint8_t *>(m_receipt.constData()),std::size_t(m_receipt.size()),&failure);
        const auto error=ok?QString{}:QString::fromUtf8(reinterpret_cast<const char *>(failure.data),qsizetype(failure.len));lyra_reader_desktop_buffer_free(failure);
        if(!ok){abort(error);return;}
    }
    // Only an accepted batch may abandon UI drafts. Failed/cancelled batches keep them.
    for(const auto &window:m_windows)if(window.window)QMetaObject::invokeMethod(window.window,"prepareDiscardForQuit");
    m_receipt.clear();m_receiptDocument.reset();m_resolved=false;
    m_timer.stop();m_accepting=true;restoreWindows();
    for(const auto &window:m_windows)if(window.window)window.window->setProperty("closeApproved",true);
    for(const auto &window:m_windows)if(window.window)window.window->close();
    ++m_epoch;m_phase=QStringLiteral("idle");m_windows.clear();m_documents.clear();m_command=0;emit changed();emit finished(true,{});emit accepted();
}
