#pragma once
#include <QObject>
#include <QUrl>
#include <memory>
namespace RenderTrace {class Sink;}
class QQuickWindow;
class WorkspaceController;
class ReaderController;

// Full reader windows have independent QML engines and remain ordinary top-levels.
class ReaderWindowFactory : public QObject {
    Q_OBJECT
public:
    void setRenderTraceSink(std::shared_ptr<RenderTrace::Sink> sink){m_renderTrace=std::move(sink);}
    explicit ReaderWindowFactory(QObject *parent=nullptr):QObject(parent){}
    QQuickWindow *createWindow(const QUrl &url={},int page=-1,double y=0,bool visible=true);
signals:
    void windowCreated(QQuickWindow *window);
private:
    std::shared_ptr<RenderTrace::Sink> m_renderTrace;
    void detachActiveTab(WorkspaceController *source,QQuickWindow *sourceWindow);
    void moveToWindow(WorkspaceController *source,QQuickWindow *sourceWindow,WorkspaceController *target,ReaderController *reader,qulonglong generation);
};
