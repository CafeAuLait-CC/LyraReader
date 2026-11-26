#include "RecentCoverCache.h"
#include <QBuffer>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>

namespace {
constexpr qint64 maximumFileBytes=4*1024*1024;
constexpr qint64 diskBudget=64*1024*1024;
QString directory() {return QStandardPaths::writableLocation(QStandardPaths::CacheLocation)+QStringLiteral("/RecentCovers");}
bool safeDirectory() {return !QFileInfo(directory()).isSymLink();}
}
bool RecentCoverCache::validDocumentId(const QString &id) {
    static const QRegularExpression pattern(QStringLiteral("^[0-9a-f]{64}$"));return pattern.match(id).hasMatch();
}
bool RecentCoverCache::validKey(const QString &key) {
    return key.size()==129 && key.at(64)==QLatin1Char('-') && validDocumentId(key.first(64)) && validDocumentId(key.last(64));
}
QString RecentCoverCache::write(const QString &documentId,const QImage &pixels,QString *error) {
    if(!validDocumentId(documentId) || pixels.isNull() || pixels.width()>512 || pixels.height()>1024
            || pixels.sizeInBytes()>512LL*1024*4 || !safeDirectory()) {
        *error=QStringLiteral("Invalid cached cover input.");return {};
    }
    const auto cover=pixels.scaled(280,376,Qt::KeepAspectRatio,Qt::SmoothTransformation);
    QByteArray png;QBuffer buffer(&png);
    if(cover.isNull() || !buffer.open(QIODevice::WriteOnly) || !cover.save(&buffer,"PNG") || png.size()>maximumFileBytes) {
        *error=QStringLiteral("Could not encode the recent cover.");return {};
    }
    const auto key=documentId+QLatin1Char('-')+QString::fromLatin1(QCryptographicHash::hash(png,QCryptographicHash::Sha256).toHex());
    QDir folder(directory());
    if(!folder.mkpath(QStringLiteral("."))) {*error=QStringLiteral("Could not create the recent cover cache.");return {};}
    const auto destination=folder.filePath(key+QStringLiteral(".png"));
    if(QFileInfo(destination).isSymLink()) {*error=QStringLiteral("The recent cover cache contains a symbolic link.");return {};}
    QSaveFile output(destination);output.setDirectWriteFallback(false);
    if(!output.open(QIODevice::WriteOnly) || output.write(png)!=png.size() || !output.commit()) {
        *error=QStringLiteral("Could not save the recent cover.");return {};
    }
    // Evict only our content-addressed cache files, never a source document.
    const auto files=folder.entryInfoList({QStringLiteral("*.png")},QDir::Files|QDir::NoSymLinks,QDir::Time);
    qint64 retained=0;
    for(const auto &file:files)if(validKey(file.completeBaseName())) {
        if(file.size()>diskBudget-retained) {
            if(!QFile::remove(file.absoluteFilePath()))qWarning("lyra-reader-recent-cover: optional cache eviction failed");
        }else retained+=file.size();
    }
    return key;
}
QImage RecentCoverCache::read(const QString &key,QString *error) {
    if(!validKey(key) || !safeDirectory()) {*error=QStringLiteral("Invalid recent cover key.");return {};}
    const auto path=QDir(directory()).filePath(key+QStringLiteral(".png"));const QFileInfo file(path);
    if(!file.isFile() || file.isSymLink() || file.size()<=0 || file.size()>maximumFileBytes) {
        *error=QStringLiteral("Cached cover unavailable.");return {};
    }
    QFile input(path);if(!input.open(QIODevice::ReadOnly)){*error=QStringLiteral("Cached cover unreadable.");return {};}
    const auto png=input.read(maximumFileBytes+1);
    if(png.isEmpty() || png.size()>maximumFileBytes){*error=QStringLiteral("Invalid cached cover size.");return {};}
    if(QString::fromLatin1(QCryptographicHash::hash(png,QCryptographicHash::Sha256).toHex())!=key.last(64)) {
        *error=QStringLiteral("Cached cover bytes changed.");return {};
    }
    QBuffer bytes;bytes.setData(png);bytes.open(QIODevice::ReadOnly);
    QImageReader reader(&bytes,"PNG");const auto size=reader.size();
    if(size.width()<=0 || size.height()<=0 || size.width()>280 || size.height()>376) {
        *error=QStringLiteral("Invalid cached cover dimensions.");return {};
    }
    auto image=reader.read();if(image.isNull())*error=QStringLiteral("Cached cover could not be decoded.");return image;
}
