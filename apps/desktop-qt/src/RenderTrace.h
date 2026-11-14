#pragma once
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QRectF>
#include <QTimer>
#include <QVector>
#include <atomic>
#include <memory>
#include <mutex>
#include <thread>

class QQuickWindow;

namespace RenderTrace {
// Geometry and roles of the admitted scene nodes, without retaining pixel or texture leases.
struct Quad {QRectF target;QString source;bool retainedAfterRejection=false;};
struct Scene {
    quint64 sourceEpoch=0;
    bool complete=false,revision=false,truncated=false;
    QVector<Quad> quads;
};
struct SceneState {
    static constexpr int maximumQuads=4096;
    std::atomic<bool> enabled{true};
    mutable std::mutex mutex;
    const void *owner=nullptr;
    Scene scene;
};

// Admission bounds serialized diagnostic payloads, not process RSS. File I/O stays on the
// writer thread; render callbacks never wait for it. A gap makes a measurement incomplete.
class Sink final {
public:
    static std::shared_ptr<Sink> memory(qsizetype records=4096,qint64 bytes=8*1024*1024);
    static std::shared_ptr<Sink> file(const QString &newPath,qint64 maximumBytes=64*1024*1024);
    ~Sink();
    bool record(const QJsonObject &event);
    QList<QJsonObject> takeRecords();
    QString error()const;
    quint64 dropped()const;
    void finish();
private:
    struct State;
    explicit Sink(qsizetype records,qint64 bytes);
    std::shared_ptr<State> m_state;
    std::thread m_writer;
};

class Window final:public QObject {
    Q_OBJECT
public:
    // GUI-thread entry points; terminal render callbacks use shared plain state only.
    static Window *attach(QQuickWindow *window,const std::shared_ptr<Sink> &sink);
    static void inherit(QQuickWindow *window);
    static Window *observer(QQuickWindow *window);
    ~Window()override;
    std::shared_ptr<Sink> sink()const;
    QString instanceId()const;
private:
    struct State;
    explicit Window(QQuickWindow *window,std::shared_ptr<Sink> sink,const QString &parentInstance={});
    void captureGui();
    QPointer<QQuickWindow> m_window;
    std::shared_ptr<State> m_state;
    QList<QMetaObject::Connection> m_connections;
    QTimer m_diagnostics;
};
double now();
}
