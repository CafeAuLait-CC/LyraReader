#pragma once
#include <QImage>
#include <QString>
struct ResidentImage;

// GUI-thread LRU shared by tabs and windows. Visible items can retain a shared image after eviction.
namespace RasterCache {
QImage get(const QString &key);
bool contains(const QString &key);
void put(const QString &key,const QImage &image);
void clearPrefix(const QString &prefix);
int costKiB();
constexpr int maximumKiB=96*1024;
// Reductions of completed main-canvas rasters, retained across working-set eviction.
// Unlike the general CPU LRU, these entries retain their source-payload budget lease.
QImage backdrop(const QString &key);
bool hasBackdrop(const QString &key);
void putBackdrop(const QString &key,const ResidentImage &image);
int backdropCostKiB();
constexpr int maximumBackdropKiB=8*1024;
}
