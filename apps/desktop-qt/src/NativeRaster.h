#pragma once
#include "lyra_reader_desktop.h"
#include <QImage>
#include <QQuickImageProvider>
#include <QRectF>
#include <QVariantMap>
#include <QMutex>
#include <atomic>
#include <memory>
#include <optional>

// No QObject is used by these worker-facing objects. Every source owns one immutable PDF revision.
class NativeRasterSource {
public:
    using Cancellation=std::shared_ptr<std::atomic_bool>;
    static bool isIndexQuery(const QString &operation);
    static std::shared_ptr<NativeRasterSource> prepare(
        const std::shared_ptr<LyraReaderDesktopDocument> &document, bool includeEdits, QString *error);
    QVariant query(const QVariantMap &request, QString *error,const Cancellation &cancelled={}) const;
    QVariantMap indexStatistics()const;
    QImage crop(int page, const QRectF &region, double scale, bool annotated, bool transparent,
                QString *error, double *actualScale = nullptr) const;
    struct DragImages {QImage background,foreground;};
    DragImages dragPreview(int page,const QString &target,const QString &revision,const QRectF &region,double scale,QString *error)const;
    QImage contentImage(int page,const QString &target,const QString &revision,const QSize &bounds,
                        qint64 maximumBytes,QString *error)const;
private:
    explicit NativeRasterSource(std::shared_ptr<LyraReaderRenderSource> source) : m_source(std::move(source)) {}
    std::shared_ptr<LyraReaderRenderSource> m_source;
    QVariant queryDirect(const QVariantMap &request,QString *error)const;
    QVariantList scanIndex(bool figures,QString *error,const Cancellation &cancelled)const;
    bool queryCancelled(const Cancellation &cancelled,QString *error)const;
    mutable QMutex m_indexMutex,m_indexCacheMutex,m_indexStatsMutex;
    mutable std::optional<QVariantList> m_referenceIndex,m_figureIndex;
    mutable quint64 m_referenceSteps=0,m_figureSteps=0,m_rasterDeferrals=0,m_cancelledQueries=0;
    mutable double m_maxIndexStepMs=0,m_maxRasterYieldMs=0;
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
