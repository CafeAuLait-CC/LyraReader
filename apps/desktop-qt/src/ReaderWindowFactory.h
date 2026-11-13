#pragma once
#include <QObject>
#include <QUrl>
class QQuickWindow;
class WorkspaceController;

// Full reader windows have independent QML engines and remain ordinary top-levels.
class ReaderWindowFactory : public QObject {
    Q_OBJECT
public:
    explicit ReaderWindowFactory(QObject *parent=nullptr):QObject(parent){}
    QQuickWindow *createWindow(const QUrl &url={},int page=-1,double y=0,bool visible=true);
signals:
    void windowCreated(QQuickWindow *window);
private:
    void detachActiveTab(WorkspaceController *source,QQuickWindow *sourceWindow);
};
