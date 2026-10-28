#pragma once
#include "lyra_reader_desktop.h"
#include <QImage>
#include <QQuickImageProvider>
#include <QRectF>
#include <QVariantMap>
#include <memory>

// No QObject is used by these worker-facing objects. Every source owns one immutable PDF revision.
class NativeRasterSource {
public:
    static std::shared_ptr<NativeRasterSource> prepare(
        const std::shared_ptr<LyraReaderDesktopDocument> &document, bool includeEdits, QString *error);
    QVariant query(const QVariantMap &request, QString *error) const;
    QImage crop(int page, const QRectF &region, double scale, bool annotated, bool transparent,
                QString *error, double *actualScale = nullptr) const;
    QImage contentImage(int page,const QString &target,const QString &revision,const QSize &bounds,
                        qint64 maximumBytes,QString *error)const;
private:
    explicit NativeRasterSource(std::shared_ptr<LyraReaderRenderSource> source) : m_source(std::move(source)) {}
    std::shared_ptr<LyraReaderRenderSource> m_source;
};

class NativeImageProvider final : public QQuickImageProvider {
public:
    NativeImageProvider() : QQuickImageProvider(Image, ForceAsynchronousImageLoading) {}
    static QString registerSource(const std::shared_ptr<NativeRasterSource> &source);
    static void unregisterSource(const QString &key);
    static QImage rawImage(const QUrl &url,qint64 maximumBytes=16*1024*1024,QString *error=nullptr);
    static QSize artworkSize(const QByteArray &encoded);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;
};
