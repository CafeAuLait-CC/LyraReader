#include "FileDialogNavigation.h"
#include <QGuiApplication>
#include <QMetaProperty>
#include <QTimer>
#include <QUrl>

namespace {
QQuickItem *fileList(QQuickItem *item) {
    if(item->isVisible() && item->objectName()==QStringLiteral("fileDialogListView"))return item;
    for(auto *child:item->childItems())if(auto *found=fileList(child))return found;
    return nullptr;
}
bool belongsTo(QWindow *window,QWindow *owner) {
    for(auto *candidate=window;candidate;candidate=candidate->transientParent())if(candidate==owner)return true;
    return false;
}
}
FileDialogNavigation::FileDialogNavigation(QObject *parent):QObject(parent) {
    if(auto *application=qobject_cast<QGuiApplication *>(QCoreApplication::instance()))
        connect(application,&QGuiApplication::focusWindowChanged,this,&FileDialogNavigation::refresh,Qt::QueuedConnection);
}
void FileDialogNavigation::track(QObject *dialog,QQuickWindow *owner) {
    if(m_list)disconnect(m_list,nullptr,this,nullptr);
    if(m_model)disconnect(m_model,nullptr,this,nullptr);
    m_list=nullptr;m_model=nullptr;m_dialog=dialog;m_owner=owner;m_initializeMissing=dialog!=nullptr;
    if(dialog)QTimer::singleShot(0,this,&FileDialogNavigation::refresh);
}
void FileDialogNavigation::refresh() {
    if(!m_dialog || !m_owner || !m_dialog->property("visible").toBool())return;
    const auto folder=m_dialog->property("currentFolder").toUrl();
    if(!m_list) {
        // Qt 6.10's fallback retains the old index when a shorter directory loads.
        // This object name is a fallback implementation detail, not a system-panel API.
        // If a Qt style/version exposes no matching view, leave that panel alone.
        for(auto *window:QGuiApplication::allWindows()) {
            auto *quick=qobject_cast<QQuickWindow *>(window);
            if(!quick || !quick->isVisible() || !belongsTo(quick,m_owner))continue;
            auto *list=fileList(quick->contentItem());
            if(!list)continue;
            auto *model=list->property("model").value<QObject *>();
            if(!model || model->property("folder").toUrl()!=folder)continue;
            m_list=list;m_model=model;
            // Wait for FolderListModel/ListView to finish their update before touching the index.
            connect(model,SIGNAL(statusChanged()),this,SLOT(refresh()),Qt::QueuedConnection);
            connect(list,SIGNAL(countChanged()),this,SLOT(refresh()),Qt::QueuedConnection);
            connect(list,SIGNAL(currentIndexChanged()),this,SLOT(refresh()),Qt::QueuedConnection);
            break;
        }
    }
    if(!m_list)return;
    auto *model=m_list->property("model").value<QObject *>();
    if(!model || model->property("folder").toUrl()!=folder)return;
    const int statusIndex=model->metaObject()->indexOfProperty("status");
    if(statusIndex<0)return;
    const auto status=model->metaObject()->property(statusIndex);
    if(!status.isEnumType())return;
    const int ready=status.enumerator().keyToValue("Ready");
    if(ready<0 || status.read(model).toInt()!=ready)return;
    const int count=m_list->property("count").toInt(),index=m_list->property("currentIndex").toInt();
    // Initialize a new folder's missing delegate even while its location editor owns focus.
    // Later deliberate deselection stays unchanged; valid user choices always stay unchanged.
    if(count>0 && (index>=count || (index<0 && m_initializeMissing)))
        m_list->setProperty("currentIndex",0);
    m_initializeMissing=false;
}
