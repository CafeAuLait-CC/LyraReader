#include "RenderBudget.h"
#include <QCoreApplication>
#include <QPointer>
#include <QTimer>
#include <array>
#include <mutex>

namespace {
struct Ledger {std::mutex mutex;std::array<qint64,2> used{},peak{},denied{};};
// Scene nodes can outlive the GUI singleton during application shutdown.
Ledger &ledger(){static auto *value=new Ledger;return *value;}
size_t index(RenderBudget::Kind kind){return kind==RenderBudget::Kind::Resident ? 0 : 1;}
}
RenderBudget::Allocation::~Allocation(){auto &state=ledger();std::lock_guard lock(state.mutex);state.used[index(kind)]-=bytes;}
RenderBudget::Lease RenderBudget::reserve(Kind kind,qint64 bytes) {
    if(bytes<=0)return {};
    auto &state=ledger();std::lock_guard lock(state.mutex);const auto i=index(kind);
    const auto limit=kind==Kind::Resident ? residentLimit : textureLimit;
    if(bytes>limit-state.used[i]){++state.denied[i];return {};}
    state.used[i]+=bytes;state.peak[i]=qMax(state.peak[i],state.used[i]);
    // Construct directly: a temporary Allocation would release the charge twice.
    return Lease(new Allocation{kind,bytes});
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
