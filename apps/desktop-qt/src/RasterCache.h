#pragma once
#include <QImage>
#include <QString>

// GUI-thread LRU shared by tabs and windows. Visible items can retain a shared image after eviction.
namespace RasterCache {
QImage get(const QString &key);
bool contains(const QString &key);
void put(const QString &key,const QImage &image);
void clearPrefix(const QString &prefix);
int costKiB();
constexpr int maximumKiB=96*1024;
}
