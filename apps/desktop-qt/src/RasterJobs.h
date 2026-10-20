#pragma once
#include <QVariantMap>
#include <atomic>
#include <memory>
class QThreadPool;

namespace RasterJobs {
constexpr int maximumRunning=2,maximumQueued=32;
struct Ticket {std::atomic_bool cancelled{false};qint64 queuedAt=0;};
using Handle=std::shared_ptr<Ticket>;
QThreadPool *pool();
Handle enqueue();
void cancel(const Handle &ticket);
QVariantMap statistics();
class Run {
public:
    explicit Run(Handle ticket);
    ~Run();
private:
    Handle m_ticket;
    qint64 m_started=0;
};
}
