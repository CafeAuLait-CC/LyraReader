#include "WorkspaceController.h"
#include "PdfPrintJob.h"
#include <QPrinter>
#include <QPrintDialog>
#include <QPointer>
#include <filesystem>
#include <QFileInfo>
#include <QSettings>
#include <QClipboard>
#include <QGuiApplication>
#include <QWindow>
#include <QDesktopServices>
#include <QCryptographicHash>
#include <QSaveFile>
#include <cmath>

namespace {
QSet<WorkspaceController *> &workspaces() {static QSet<WorkspaceController *> all;return all;}
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

WorkspaceController::WorkspaceController(QObject *parent) : QObject(parent) {
    connect(m_preview,&PreviewController::newWindowRequested,this,&WorkspaceController::openInNewWindow);
    connect(m_preview,&PreviewController::externalRequested,this,&WorkspaceController::openExternal);
    QSettings settings;
    m_recent = normalizedRecents(settings.value(QStringLiteral("reader/recentDocuments")).toList());
    workspaces().insert(this);
    appendTab();
}
WorkspaceController::~WorkspaceController() {workspaces().remove(this);}
void WorkspaceController::publishRecents(const QVariantList &entries) {
    // Signals can close another window; never keep an unguarded raw pointer across one.
    QList<QPointer<WorkspaceController>> recipients;
    for(auto *workspace:workspaces())recipients.append(workspace);
    for(const auto &workspace:recipients)if(workspace && workspace->m_recent!=entries) {
        workspace->m_recent=entries;emit workspace->recentDocumentsChanged();
    }
}
ReaderController *WorkspaceController::appendTab() {
    auto *reader = new ReaderController(this);
    m_tabs.append(reader);
    connect(reader, &ReaderController::documentChanged, this, &WorkspaceController::tabsChanged);
    connect(reader, &ReaderController::loadingChanged, this, &WorkspaceController::tabsChanged);
    connect(reader, &ReaderController::openFinished, this, [this,reader](bool success) { if (success) remember(reader); });
    emit tabsChanged();
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
    if (index < 0 || index >= m_tabs.size() || index == m_activeIndex) return;
    m_preview->close();
    emit activeReaderAboutToChange();
    m_activeIndex = index;
    emit activeReaderChanged();
}
void WorkspaceController::openFiles(const QList<QUrl> &urls) { for (const auto &url : urls) openFile(url); }
void WorkspaceController::openFile(const QUrl &url) {
    if (!url.isLocalFile()) return;
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
    // Each reader window flushes notes, waits for writes and confirms its own drafts.
    // A cancelled close keeps the application alive; do not bypass that with quit().
    const auto windows=QGuiApplication::topLevelWindows();
    for(auto *window:windows)if(window->isVisible() && window->objectName()==QStringLiteral("readerWindow"))window->close();
}

void WorkspaceController::newTab() {
    appendTab();
    selectTab(int(m_tabs.size()) - 1);
}
void WorkspaceController::closeTab(int index, bool discardPending) {
    if (index < 0 || index >= m_tabs.size()) return;
    auto *candidate=m_tabs.at(index);
    const auto marks=candidate->data().value(QStringLiteral("marks")).toMap();
    if(candidate->pendingCommands()>0 || (!discardPending &&
        (marks.value(QStringLiteral("page_pending")).toBool() || marks.value(QStringLiteral("pending_deletions")).toInt()>0 || !candidate->noteDrafts().isEmpty() || candidate->hasEditDrafts()))) {
        emit closeTabRequested(index);
        return;
    }
    if(candidate==activeReader())m_preview->close();
    emit activeReaderAboutToChange();
    auto *reader = m_tabs.takeAt(index);
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
    return settings.value(QStringLiteral("reader/preferences/")+key,fallback);
}
void WorkspaceController::setPreference(const QString &key,const QVariant &value) {
    QSettings settings;
    settings.setValue(QStringLiteral("reader/preferences/")+key,value);
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
    if(reader->pendingCommands()>0){emit printFinished(tr("Wait for the document operation to finish before printing."));return;}
    const auto document=reader->documentHandle();
    const auto pages=reader->pages();
    const auto original=reader->fileUrl().toLocalFile();
    auto printer=std::make_shared<QPrinter>(QPrinter::HighResolution);
    printer->setDocName(reader->title());
    QPrintDialog dialog(printer.get());
    dialog.setMinMax(1,int(pages.size()));
    dialog.setOption(QAbstractPrintDialog::PrintPageRange,true);
    dialog.setOption(QAbstractPrintDialog::PrintCurrentPage,true);
    if(dialog.exec()!=QDialog::Accepted)return;
    if(!printer->outputFileName().isEmpty()) {
        const auto destination=QFileInfo(printer->outputFileName());
        std::error_code error;
        if(destination.absoluteFilePath()==QFileInfo(original).absoluteFilePath() ||
            std::filesystem::equivalent(std::filesystem::u8path(original.toUtf8().constData()),
                std::filesystem::u8path(destination.absoluteFilePath().toUtf8().constData()),error)) {
            emit printFinished(tr("Printing cannot overwrite the original PDF. Choose another destination."));return;
        }
    }
    const auto owner=QPointer<WorkspaceController>(this);
    PdfPrintJob::start(document,pages,printer,currentPage,[owner](const QString &error){if(owner)emit owner->printFinished(error);});
}
