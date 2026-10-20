#pragma once
#include <QFile>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QTimer>
#include <QVariantMap>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>

namespace Performance {
inline qint64 now(){return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
inline qint64 memory(const QByteArray &field) {
#ifdef Q_OS_LINUX
    QFile file(QStringLiteral("/proc/self/status"));if(!file.open(QIODevice::ReadOnly))return -1;
    for(const auto &line:file.readAll().split('\n'))if(line.startsWith(field+':'))return line.mid(field.size()+1).trimmed().split(' ').first().toLongLong()*1024;
#else
    Q_UNUSED(field);
#endif
    return -1;
}
inline QVariantMap distribution(QList<double> values) {
    if(values.isEmpty())return {{"samples",0}};std::sort(values.begin(),values.end());
    const auto at=[&](double p){return values.at(qsizetype((values.size()-1)*p));};
    return {{"samples",values.size()},{"p50",at(.5)},{"p95",at(.95)},{"p99",at(.99)},{"max",values.last()}};
}
class Frames {
    struct State {std::mutex mutex;QList<qint64> timestamps;std::atomic<qint64> armed{0},queued{0};};
    std::shared_ptr<State> m_state=std::make_shared<State>();
    QMetaObject::Connection m_connection;
public:
    explicit Frames(QQuickWindow *window) {
        m_connection=QObject::connect(window,&QQuickWindow::frameSwapped,window,[state=m_state] {
            const auto time=now();{std::lock_guard lock(state->mutex);state->timestamps.append(time);}
            const auto armed=state->armed.load();if(armed && time>=armed){qint64 empty=0;state->queued.compare_exchange_strong(empty,time);}
        },Qt::DirectConnection);
    }
    ~Frames(){QObject::disconnect(m_connection);}
    void clear(){std::lock_guard lock(m_state->mutex);m_state->timestamps.clear();m_state->armed=0;m_state->queued=0;}
    void arm(){m_state->armed=now();}
    qint64 queued()const{return m_state->queued.load();}
    QList<double> intervals(qint64 begin,qint64 end)const {
        std::lock_guard lock(m_state->mutex);QList<double> result;qint64 previous=0;
        for(const auto time:m_state->timestamps)if(time>=begin && time<=end){if(previous)result.append((time-previous)/1000.0);previous=time;}
        return result;
    }
};
}
