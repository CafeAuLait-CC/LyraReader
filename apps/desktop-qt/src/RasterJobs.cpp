#include "RasterJobs.h"
#include <QCoreApplication>
#include <QThreadPool>
#include <algorithm>
#include <chrono>
#include <deque>
#include <mutex>

namespace {
qint64 now(){return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
struct State {std::mutex mutex;int queued=0,active=0,peak=0,peakQueued=0;qint64 done=0,cancelled=0;std::deque<qint64> wait,work;};
State &state(){static auto *value=new State;return *value;}
void sample(std::deque<qint64> &values,qint64 value){values.push_back(value);while(values.size()>512)values.pop_front();}
double percentile(const std::deque<qint64> &values,double p){if(values.empty())return 0;std::vector<qint64> sorted(values.begin(),values.end());std::sort(sorted.begin(),sorted.end());return sorted[size_t((sorted.size()-1)*p)]/1000.0;}
}
QThreadPool *RasterJobs::pool(){static auto *value=[] {auto *pool=new QThreadPool(QCoreApplication::instance());pool->setMaxThreadCount(maximumRunning);pool->setExpiryTimeout(30000);return pool;}();return value;}
RasterJobs::Handle RasterJobs::enqueue() {
    auto &s=state();std::lock_guard lock(s.mutex);if(s.queued>=maximumQueued)return {};
    auto ticket=std::make_shared<Ticket>();ticket->queuedAt=now();++s.queued;s.peakQueued=qMax(s.peakQueued,s.queued);return ticket;
}
void RasterJobs::cancel(const Handle &ticket){if(ticket)ticket->cancelled.store(true);}
RasterJobs::Run::Run(Handle ticket):m_ticket(std::move(ticket)),m_started(now()) {
    auto &s=state();std::lock_guard lock(s.mutex);--s.queued;++s.active;s.peak=qMax(s.peak,s.active);sample(s.wait,m_started-m_ticket->queuedAt);
}
RasterJobs::Run::~Run(){auto &s=state();std::lock_guard lock(s.mutex);--s.active;++s.done;if(m_ticket->cancelled.load())++s.cancelled;sample(s.work,now()-m_started);}
QVariantMap RasterJobs::statistics() {
    auto &s=state();std::lock_guard lock(s.mutex);
    return {{"running",s.active},{"queued",s.queued},{"peakRunning",s.peak},{"peakQueued",s.peakQueued},{"completed",s.done},{"cancelled",s.cancelled},
            {"maximumRunning",maximumRunning},{"maximumQueued",maximumQueued},{"waitP50Ms",percentile(s.wait,.5)},{"waitP95Ms",percentile(s.wait,.95)},{"workP50Ms",percentile(s.work,.5)},{"workP95Ms",percentile(s.work,.95)}};
}
