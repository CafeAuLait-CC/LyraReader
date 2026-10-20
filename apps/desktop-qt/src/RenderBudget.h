#pragma once
#include <QHash>
#include <QImage>
#include <QObject>
#include <QVariantMap>
#include <memory>

// Charges live source pixels and owned scene textures separately. These are
// conservative payload/reservation budgets, not driver VRAM or process RSS.
class RenderBudget final:public QObject {
    Q_OBJECT
public:
    enum class Kind { Resident, Texture };
    struct Allocation {
        Kind kind; qint64 bytes; qint64 imageKey=0;
        ~Allocation();
    };
    using Lease=std::shared_ptr<Allocation>;
    static constexpr qint64 residentLimit=192LL*1024*1024;
    static constexpr qint64 textureLimit=192LL*1024*1024;
    static constexpr qint64 maximumJobBytes=16LL*1024*1024;
    static RenderBudget *instance(); // GUI thread; leases may die on render threads.
    static Lease reserve(Kind kind,qint64 bytes);
    static Lease retainImage(const QImage &image);
    static Lease publishImage(Lease reservation,const QImage &image);
    static QVariantMap statistics();
    void setClient(const QObject *owner,int weight);
    qint64 targetBytes(const QObject *owner)const;
signals:
    void targetsChanged();
private:
    explicit RenderBudget(QObject *parent):QObject(parent){}
    QHash<const QObject *,int> m_clients;
    bool m_notificationPending=false;
};

struct ResidentImage {
    RenderBudget::Lease allocation;
    QImage pixels;
    ResidentImage()=default;
    ResidentImage(RenderBudget::Lease charge,QImage image):allocation(std::move(charge)),pixels(std::move(image)){}
    ResidentImage(const ResidentImage &)=default;
    ResidentImage(ResidentImage &&)=default;
    ResidentImage &operator=(ResidentImage next)noexcept {allocation.swap(next.allocation);pixels.swap(next.pixels);return *this;}
    bool isNull()const{return pixels.isNull();}
    static ResidentImage retain(const QImage &image) {
        if(image.isNull())return {};
        auto lease=RenderBudget::retainImage(image);
        return lease ? ResidentImage{std::move(lease),image} : ResidentImage{};
    }
    static ResidentImage publish(RenderBudget::Lease reservation,QImage image) {
        ResidentImage result(std::move(reservation),std::move(image));
        auto lease=RenderBudget::publishImage(result.allocation,result.pixels);
        if(!lease)return {};
        result.allocation=std::move(lease);return result;
    }
};
