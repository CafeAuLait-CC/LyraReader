#pragma once
#include <QImage>
#include <QString>

// Cached decoration only. These helpers never open or identify a source PDF.
namespace RecentCoverCache {
bool validDocumentId(const QString &id);
bool validKey(const QString &key);
QString write(const QString &documentId,const QImage &pixels,QString *error);
QImage read(const QString &key,QString *error);
}
