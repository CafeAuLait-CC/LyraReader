#pragma once
#include <QVariantMap>
#include <atomic>
#include <memory>
class QThreadPool;

namespace RasterJobs {
constexpr int maximumRunning=2,maximumQueued=32;
enum class Work { Interactive, Background };
struct Ticket {
    Ticket(Work work, qint64 queuedAt): m_work(work), m_queuedAt(queuedAt) {}
    std::atomic_bool cancelled{false};
private:
    friend class Run;
    friend void cancel(const std::shared_ptr<Ticket> &ticket);
    const Work m_work;
    const qint64 m_queuedAt;
    bool m_queued=true; // guarded by the admission mutex
};
using Handle=std::shared_ptr<Ticket>;
QThreadPool *pool();
Handle enqueue(Work work=Work::Interactive);
void cancel(const Handle &ticket);
QVariantMap statistics();
bool foregroundBusy();
class Run {
public:
    explicit Run(Handle ticket);
    ~Run();
    Run(const Run &)=delete;
    Run &operator=(const Run &)=delete;
private:
    Handle m_ticket;
    qint64 m_started=0;
    bool m_interactive=false;
};
}
