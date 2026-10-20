#include "RasterCache.h"
#include <QCache>

namespace {
QCache<QString,QImage> &images() {static QCache<QString,QImage> cache(RasterCache::maximumKiB);return cache;}
}
QImage RasterCache::get(const QString &key) {auto *image=images().object(key);return image ? *image : QImage{};}
bool RasterCache::contains(const QString &key) {return images().contains(key);}
void RasterCache::put(const QString &key,const QImage &image) {images().insert(key,new QImage(image),int((image.sizeInBytes()+1023)/1024));}
void RasterCache::clearPrefix(const QString &prefix) {for(const auto &key:images().keys())if(key.startsWith(prefix))images().remove(key);}
int RasterCache::costKiB() {return images().totalCost();}
