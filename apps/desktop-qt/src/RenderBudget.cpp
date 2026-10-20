#include "RenderBudget.h"
#include <QCoreApplication>
#include <QPointer>
#include <QTimer>
#include <array>
#include <mutex>

namespace {
struct Ledger {std::mutex mutex;std::array<qint64,2> used{},peak{},denied{};QHash<qint64,std::weak_ptr<RenderBudget::Allocation>> images;};
// Scene nodes can outlive the GUI singleton during application shutdown.
Ledger &ledger(){static auto *value=new Ledger;return *value;}
size_t index(RenderBudget::Kind kind){return kind==RenderBudget::Kind::Resident ? 0 : 1;}
}
RenderBudget::Allocation::~Allocation(){auto &state=ledger();std::lock_guard lock(state.mutex);state.used[index(kind)]-=bytes;if(imageKey && state.images.value(imageKey).expired())state.images.remove(imageKey);}
RenderBudget::Lease RenderBudget::reserve(Kind kind,qint64 bytes) {
    if(bytes<=0)return {};
    auto &state=ledger();std::lock_guard lock(state.mutex);const auto i=index(kind);
    const auto limit=kind==Kind::Resident ? residentLimit : textureLimit;
    if(bytes>limit-state.used[i]){++state.denied[i];return {};}
    state.used[i]+=bytes;state.peak[i]=qMax(state.peak[i],state.used[i]);
    // Construct directly: a temporary Allocation would release the charge twice.
    return Lease(new Allocation{kind,bytes});
}
RenderBudget::Lease RenderBudget::retainImage(const QImage &image) {
    if(image.isNull())return {};
    auto &s=ledger();std::lock_guard lock(s.mutex);const auto key=image.cacheKey();
    if(auto existing=s.images.value(key).lock())return existing;
    const auto bytes=image.sizeInBytes();
    if(bytes>residentLimit-s.used[0]){++s.denied[0];return {};}
    s.used[0]+=bytes;s.peak[0]=qMax(s.peak[0],s.used[0]);
    Lease result(new Allocation{Kind::Resident,bytes,key});s.images.insert(key,result);return result;
}
RenderBudget::Lease RenderBudget::publishImage(Lease reservation,const QImage &image) {
    if(!reservation || image.isNull() || reservation->kind!=Kind::Resident || image.sizeInBytes()>reservation->bytes)return {};
    auto &s=ledger();std::lock_guard lock(s.mutex);const auto key=image.cacheKey();
    if(auto existing=s.images.value(key).lock())return existing;
    // Only the worker owns this reservation until its future publishes the result.
    s.used[0]-=reservation->bytes-image.sizeInBytes();reservation->bytes=image.sizeInBytes();reservation->imageKey=key;
    s.images.insert(key,reservation);return reservation;
}
QVariantMap RenderBudget::statistics() {
    auto &state=ledger();std::lock_guard lock(state.mutex);
    return {{"residentBytes",state.used[0]},{"residentPeakBytes",state.peak[0]},{"residentDenied",state.denied[0]},{"residentLimitBytes",residentLimit},
            {"textureBytes",state.used[1]},{"texturePeakBytes",state.peak[1]},{"textureDenied",state.denied[1]},{"textureLimitBytes",textureLimit}};
}
RenderBudget *RenderBudget::instance() {
    static QPointer<RenderBudget> value;
    if(!value)value=new RenderBudget(QCoreApplication::instance());
    return value;
}
void RenderBudget::setClient(const QObject *owner,int weight) {
    if(m_clients.value(owner)==weight)return;
    if(weight>0)m_clients.insert(owner,weight);else m_clients.remove(owner);
    if(m_notificationPending)return;m_notificationPending=true;
    QTimer::singleShot(0,this,[this]{m_notificationPending=false;emit targetsChanged();});
}
qint64 RenderBudget::targetBytes(const QObject *owner)const {
    const int weight=m_clients.value(owner);if(!weight)return 0;
    qint64 total=0;for(const auto value:m_clients)total+=value;
    // The other half covers old tiers and nodes awaiting a render sync. The hard
    // ledger still gates transient replacements when their leases overlap.
    return qBound<qint64>(16*1024,(residentLimit/2)*weight/qMax<qint64>(1,total),64LL*1024*1024);
}
