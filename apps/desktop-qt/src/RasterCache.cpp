#include "RasterCache.h"
#include <QCache>
#include "RenderBudget.h"

namespace {
QCache<QString,QImage> &images() {static QCache<QString,QImage> cache(RasterCache::maximumKiB);return cache;}
QCache<QString,ResidentImage> &backdrops() {static QCache<QString,ResidentImage> cache(RasterCache::maximumBackdropKiB);return cache;}
}
QImage RasterCache::get(const QString &key) {auto *image=images().object(key);return image ? *image : QImage{};}
bool RasterCache::contains(const QString &key) {return images().contains(key);}
void RasterCache::put(const QString &key,const QImage &image) {images().insert(key,new QImage(image),int((image.sizeInBytes()+1023)/1024));}
void RasterCache::clearPrefix(const QString &prefix) {
    for(const auto &key:images().keys())if(key.startsWith(prefix))images().remove(key);
    for(const auto &key:backdrops().keys())if(key.startsWith(prefix))backdrops().remove(key);
}
int RasterCache::costKiB() {return images().totalCost();}
QImage RasterCache::backdrop(const QString &key) {auto *image=backdrops().object(key);return image ? image->pixels : QImage{};}
bool RasterCache::hasBackdrop(const QString &key) {return backdrops().contains(key);}
void RasterCache::putBackdrop(const QString &key,const ResidentImage &image) {
    if(image.isNull() || !image.allocation || image.pixels.sizeInBytes()>qint64(maximumBackdropKiB)*1024)return;
    backdrops().insert(key,new ResidentImage(image),int((image.pixels.sizeInBytes()+1023)/1024));
}
int RasterCache::backdropCostKiB() {return backdrops().totalCost();}
