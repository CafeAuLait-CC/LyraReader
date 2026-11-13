#include "NativeRaster.h"
#include "PaperAppearance.h"
#include "RasterJobs.h"
#include <QHash>
#include <QBuffer>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QUuid>
#include <QUrlQuery>
#include <QScopeGuard>
#include <QElapsedTimer>
#include <QThread>
#include <cmath>

namespace {
QMutex sourcesMutex;
QHash<QString, std::weak_ptr<NativeRasterSource>> sources;
QString takeError(LyraReaderBuffer &buffer) {
    const auto result=QString::fromUtf8(reinterpret_cast<const char *>(buffer.data),qsizetype(buffer.len));
    lyra_reader_desktop_buffer_free(buffer);buffer={};return result;
}
void releasePixels(void *data) {
    auto *buffer=static_cast<LyraReaderBuffer *>(data);
    lyra_reader_desktop_buffer_free(*buffer);delete buffer;
}
}
std::shared_ptr<NativeRasterSource> NativeRasterSource::prepare(
    const std::shared_ptr<LyraReaderDesktopDocument> &document,bool includeEdits,QString *error) {
    LyraReaderBuffer failure{};
    auto *handle=lyra_reader_desktop_render_source(document.get(),includeEdits,&failure);
    if(!handle){*error=takeError(failure);return {};}
    return std::shared_ptr<NativeRasterSource>(new NativeRasterSource(
        std::shared_ptr<LyraReaderRenderSource>(handle,lyra_reader_desktop_render_source_free)));
}
bool NativeRasterSource::queryCancelled(const Cancellation &cancelled,QString *error)const {
    if(!cancelled || !cancelled->load())return false;
    *error=QStringLiteral("The document query was cancelled.");
    QMutexLocker lock(&m_indexStatsMutex);++m_cancelledQueries;return true;
}
bool NativeRasterSource::isIndexQuery(const QString &op) {
    return op==QStringLiteral("references") || op==QStringLiteral("figures") || op==QStringLiteral("citations")
        || op==QStringLiteral("page_targets") || op==QStringLiteral("resolve_citations");
}
QVariantMap NativeRasterSource::indexStatistics()const {
    QMutexLocker lock(&m_indexStatsMutex);
    return {{"referenceSteps",m_referenceSteps},{"figureSteps",m_figureSteps},{"rasterDeferrals",m_rasterDeferrals},
        {"cancelledQueries",m_cancelledQueries},{"maxStepMs",m_maxIndexStepMs},{"maxRasterYieldMs",m_maxRasterYieldMs}};
}
QVariantList NativeRasterSource::scanIndex(bool figures,QString *error,const Cancellation &cancelled)const {
    const auto cache=[&]{QMutexLocker lock(&m_indexCacheMutex);return figures?m_figureIndex:m_referenceIndex;};
    // A completed reference lookup must not wait behind a cold figure scan (or vice versa).
    if(const auto found=cache())return *found;
    // A main reader, its preview and a detached frozen reader share this owner. Only one
    // scanner may advance this source's Rust state; waiting consumers remain cancellable.
    while(!m_indexMutex.tryLock(5))if(queryCancelled(cancelled,error))return {};
    const auto unlock=qScopeGuard([&]{m_indexMutex.unlock();});
    if(queryCancelled(cancelled,error))return {};
    if(const auto found=cache())return *found;
    for(;;) {
        if(queryCancelled(cancelled,error))return {};
        QElapsedTimer wait;wait.start();const bool deferred=RasterJobs::foregroundBusy();
        if(deferred){QMutexLocker lock(&m_indexStatsMutex);++m_rasterDeferrals;}
        // This observes the actual Qt raster admission counters, not an AppKit FIFO.
        // Bound the wait so continuous scrolling cannot permanently starve an index.
        while(RasterJobs::foregroundBusy() && wait.elapsed()<250) {
            if(queryCancelled(cancelled,error))return {};QThread::msleep(5);
        }
        if(deferred){QMutexLocker lock(&m_indexStatsMutex);m_maxRasterYieldMs=qMax(m_maxRasterYieldMs,wait.nsecsElapsed()/1e6);}
        if(queryCancelled(cancelled,error))return {};
        QElapsedTimer step;step.start();
        const auto result=queryDirect({{"op",figures?QStringLiteral("figures_scan_step"):QStringLiteral("references_scan_step")},{"pages",4},{"entries",12}},error).toMap();
        {QMutexLocker lock(&m_indexStatsMutex);if(figures)++m_figureSteps;else ++m_referenceSteps;m_maxIndexStepMs=qMax(m_maxIndexStepMs,step.nsecsElapsed()/1e6);}
        if(!error->isEmpty())return {};
        if(result.value("done").metaType().id()!=QMetaType::Bool || result.value("records").metaType().id()!=QMetaType::QVariantList) {
            *error=QStringLiteral("The document service returned invalid index progress.");return {};
        }
        if(result.value("done").toBool()) {
            const auto records=result.value("records").toList();
            {QMutexLocker lock(&m_indexCacheMutex);(figures?m_figureIndex:m_referenceIndex)=records;}
            if(queryCancelled(cancelled,error))return {};
            return records;
        }
        // No partial collection escapes. The next bounded step gives newly admitted
        // raster work another chance, while Rust retains its own intermediate state.
        QThread::yieldCurrentThread();
    }
}
QVariant NativeRasterSource::query(const QVariantMap &request,QString *error,const Cancellation &cancelled)const {
    if(queryCancelled(cancelled,error))return {};
    const auto op=request.value("op").toString();
    if(op==QStringLiteral("references") || op==QStringLiteral("figures")) {
        const auto records=scanIndex(op==QStringLiteral("figures"),error,cancelled);
        return error->isEmpty()?QVariant(records):QVariant{};
    }
    if(op==QStringLiteral("citations") || op==QStringLiteral("page_targets") || op==QStringLiteral("resolve_citations")) {
        // Those seemingly page-local accessors consult reference_cache(). Finish it
        // cooperatively first, so they cannot silently restart a monolithic cold scan.
        scanIndex(false,error,cancelled);if(!error->isEmpty())return {};
    }
    if(queryCancelled(cancelled,error))return {};
    return queryDirect(request,error);
}
QVariant NativeRasterSource::queryDirect(const QVariantMap &request,QString *error) const {
    const auto bytes=QJsonDocument::fromVariant(request).toJson(QJsonDocument::Compact);
    LyraReaderBuffer output{},failure{};
    if(!lyra_reader_desktop_source_command(m_source.get(),reinterpret_cast<const std::uint8_t *>(bytes.constData()),std::size_t(bytes.size()),&output,&failure)) {
        *error=takeError(failure);return {};
    }
    QJsonParseError parse{};
    const auto result=QJsonDocument::fromJson(QByteArray::fromRawData(reinterpret_cast<const char *>(output.data),qsizetype(output.len)),&parse);
    lyra_reader_desktop_buffer_free(output);
    if(parse.error!=QJsonParseError::NoError || !result.isObject()) {*error=QStringLiteral("Invalid snapshot response.");return {};}
    return result.object().value(QStringLiteral("result")).toVariant();
}
QImage NativeRasterSource::crop(int page,const QRectF &region,double scale,bool annotated,bool transparent,
                               QString *error,double *actualScale) const {
    LyraReaderBitmap bitmap{};LyraReaderBuffer failure{};
    if(!lyra_reader_desktop_render_region(m_source.get(),std::uint32_t(page),scale,region.x(),region.y(),region.width(),region.height(),annotated,transparent,&bitmap,&failure)) {
        *error=takeError(failure);return {};
    }
    if(!bitmap.width || !bitmap.height || bitmap.width>8192 || bitmap.height>8192 ||
        bitmap.stride<std::uint64_t(bitmap.width)*4 || bitmap.pixels.len<std::uint64_t(bitmap.stride)*bitmap.height) {
        lyra_reader_desktop_buffer_free(bitmap.pixels);*error=QStringLiteral("Invalid crop raster.");return {};
    }
    if(actualScale)*actualScale=bitmap.scale;
    auto *pixels=new LyraReaderBuffer(bitmap.pixels);
    return QImage(pixels->data,int(bitmap.width),int(bitmap.height),int(bitmap.stride),QImage::Format_ARGB32,releasePixels,pixels);
}
NativeRasterSource::DragImages NativeRasterSource::dragPreview(int page,const QString &target,const QString &revision,const QRectF &region,double scale,QString *error)const {
    if(page<0 || target.size()>4096 || revision.size()>128){*error=QStringLiteral("Invalid object preview identity.");return {};}
    const auto id=target.toUtf8(),version=revision.toUtf8();LyraReaderBitmap bg{},fg{};LyraReaderBuffer failure{};
    if(!lyra_reader_desktop_drag_preview(m_source.get(),std::uint32_t(page),reinterpret_cast<const std::uint8_t *>(id.constData()),std::size_t(id.size()),reinterpret_cast<const std::uint8_t *>(version.constData()),std::size_t(version.size()),region.x(),region.y(),region.width(),region.height(),scale,&bg,&fg,&failure)){*error=takeError(failure);return {};}
    const auto cleanup=qScopeGuard([&]{lyra_reader_desktop_buffer_free(bg.pixels);lyra_reader_desktop_buffer_free(fg.pixels);});
    const auto valid=[](const LyraReaderBitmap &b){return b.pixels.data && b.width>0 && b.height>0 && b.width<=8192 && b.height<=8192 && b.stride>=std::uint64_t(b.width)*4 && b.pixels.len==std::uint64_t(b.stride)*b.height && b.pixels.len<=lyra_reader_desktop_drag_pair_limit()/2;};
    if(!valid(bg) || !valid(fg) || bg.width!=fg.width || bg.height!=fg.height || bg.stride!=fg.stride){*error=QStringLiteral("Invalid object preview pixels.");return {};}
    const auto take=[](LyraReaderBitmap &b){auto *pixels=new LyraReaderBuffer(b.pixels);b.pixels={};return QImage(pixels->data,int(b.width),int(b.height),int(b.stride),QImage::Format_ARGB32,releasePixels,pixels);};
    return {take(bg),take(fg)};
}
QImage NativeRasterSource::contentImage(int page,const QString &target,const QString &revision,
                                      const QSize &bounds,qint64 maximumBytes,QString *error)const {
    if(page<0 || bounds.isEmpty() || bounds.width()>2048 || bounds.height()>2048 || maximumBytes<4){*error=QStringLiteral("Invalid image preview dimensions.");return {};}
    const auto id=target.toUtf8(),version=revision.toUtf8();LyraReaderBuffer output{},failure{};
    if(!lyra_reader_desktop_source_image_png(m_source.get(),std::uint32_t(page),
        reinterpret_cast<const std::uint8_t *>(id.constData()),std::size_t(id.size()),
        reinterpret_cast<const std::uint8_t *>(version.constData()),std::size_t(version.size()),&output,&failure)){
        *error=takeError(failure);return {};
    }
    const auto cleanup=qScopeGuard([&]{lyra_reader_desktop_buffer_free(output);});
    if(!output.data || output.len>192ULL*1024*1024){*error=QStringLiteral("Invalid image preview buffer.");return {};}
    // Borrow the owned PNG during decoding, without a second copy or a base64 transport.
    QBuffer buffer;buffer.setData(QByteArray::fromRawData(reinterpret_cast<const char *>(output.data),qsizetype(output.len)));
    if(!buffer.open(QIODevice::ReadOnly)){*error=QStringLiteral("The image preview buffer could not be opened.");return {};}
    QImageReader reader(&buffer,"png");const auto size=reader.size();
    if(size.isEmpty() || quint64(size.width())*quint64(size.height())>40000000){*error=QStringLiteral("Invalid image preview size.");return {};}
    const double scale=qMin(1.0,qMin(double(bounds.width())/size.width(),double(bounds.height())/size.height()));
    QSize targetSize(qMax(1,int(std::floor(size.width()*scale))),qMax(1,int(std::floor(size.height()*scale))));
    // At most eleven halvings from 2048 px: even extreme 1×N images respect a tiny budget.
    while(qint64(targetSize.width())*targetSize.height()>maximumBytes/4)
        targetSize={qMax(1,targetSize.width()/2),qMax(1,targetSize.height()/2)};
    reader.setScaledSize(targetSize);auto image=reader.read();
    if(image.isNull()){*error=reader.errorString();return {};}
    if(image.size()!=targetSize)image=image.scaled(targetSize,Qt::IgnoreAspectRatio,Qt::SmoothTransformation);
    image=image.convertToFormat(QImage::Format_ARGB32);
    if(image.isNull() || image.sizeInBytes()>maximumBytes){*error=QStringLiteral("The image preview exceeded its pixel budget.");return {};}
    return image;
}
QString NativeImageProvider::registerSource(const std::shared_ptr<NativeRasterSource> &source) {
    const auto key=QUuid::createUuid().toString(QUuid::WithoutBraces);
    QMutexLocker lock(&sourcesMutex);sources.insert(key,source);return key;
}
void NativeImageProvider::unregisterSource(const QString &key) {
    QMutexLocker lock(&sourcesMutex);sources.remove(key);
}
QSize NativeImageProvider::artworkSize(const QByteArray &encoded) {
    if(encoded.isEmpty() || encoded.size()>8*1024*1024)return {};
    QBuffer buffer;buffer.setData(encoded);buffer.open(QIODevice::ReadOnly);
    QImageReader reader(&buffer);reader.setDecideFormatFromContent(true);
    const auto format=reader.format();
    if(format!="png" && format!="jpeg" && format!="jpg")return {};
    const auto size=reader.size();
    if(size.isEmpty() || size.width()>8192 || size.height()>8192 || qint64(size.width())*size.height()>16LL*1024*1024)return {};
    return size;
}
QImage NativeImageProvider::rawImage(const QUrl &url,qint64 maximumBytes,QString *failure) {
    QString localError;auto *error=failure ? failure : &localError;
    if(url.scheme()==QStringLiteral("data")) {
        const auto path=url.path();const auto comma=path.indexOf(',');
        if(comma<0 || (path.left(comma)!=QStringLiteral("image/png;base64") && path.left(comma)!=QStringLiteral("image/jpeg;base64")) || path.size()>12*1024*1024 || maximumBytes<4)return {};
        const auto bytes=QByteArray::fromBase64Encoding(path.mid(comma+1).toLatin1(),QByteArray::AbortOnBase64DecodingErrors);
        if(!bytes)return {};
        const auto size=artworkSize(bytes.decoded);if(size.isEmpty())return {};
        const double scale=qMin(1.0,qMin(2048.0/qMax(size.width(),size.height()),std::sqrt(double(maximumBytes)/(4.0*size.width()*size.height()))));
        const QSize target(qMax(1,int(std::floor(size.width()*scale))),qMax(1,int(std::floor(size.height()*scale))));
        QBuffer buffer;buffer.setData(bytes.decoded);buffer.open(QIODevice::ReadOnly);
        QImageReader reader(&buffer);reader.setDecideFormatFromContent(true);reader.setScaledSize(target);
        auto image=reader.read();
        if(image.isNull())return {};
        if(image.size()!=target)image=image.scaled(target,Qt::IgnoreAspectRatio,Qt::SmoothTransformation);
        image=image.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
        if(image.sizeInBytes()>maximumBytes)return {};
        return image;
    }
    if(url.scheme()!=QStringLiteral("image") || url.host()!=QStringLiteral("lyrapreview"))return {};
    const auto path=url.path().split('/',Qt::SkipEmptyParts);
    if(path.size()!=2)return {};
    std::shared_ptr<NativeRasterSource> source;
    {QMutexLocker lock(&sourcesMutex);source=sources.value(path.first()).lock();}
    if(!source)return {};
    bool ok=false;const int page=path.last().toInt(&ok);
    if(!ok || page<0)return {};
    const QUrlQuery query(url);
    if(query.queryItemValue(QStringLiteral("kind"))==QStringLiteral("bitmap")){
        bool widthOk=false,heightOk=false;
        const auto width=query.queryItemValue(QStringLiteral("width")).toInt(&widthOk),height=query.queryItemValue(QStringLiteral("height")).toInt(&heightOk);
        if(!widthOk || !heightOk){*error=QStringLiteral("Invalid content preview size.");return {};}
        return source->contentImage(page,query.queryItemValue(QStringLiteral("target")),query.queryItemValue(QStringLiteral("revision")),{width,height},maximumBytes,error);
    }
    const auto number=[&](const QString &key){bool valid=false;const double value=query.queryItemValue(key).toDouble(&valid);return valid ? value : std::nan("");};
    const QRectF region(number(QStringLiteral("x")),number(QStringLiteral("y")),number(QStringLiteral("w")),number(QStringLiteral("h")));
    double scale=number(QStringLiteral("scale"));
    if(region.isEmpty() || !std::isfinite(scale) || scale<=0 || maximumBytes<4)return {};
    scale=qMin(scale,std::sqrt(double(maximumBytes)/(4*region.width()*region.height())));
    while(std::ceil(region.width()*scale)*std::ceil(region.height()*scale)*4>maximumBytes)scale*=.99;
    const auto annotations=query.queryItemValue(QStringLiteral("annotations"));
    if(query.hasQueryItem(QStringLiteral("annotations")) && annotations!=QStringLiteral("0") && annotations!=QStringLiteral("1")){*error=QStringLiteral("Invalid preview annotation flag.");return {};}
    const auto transparent=query.queryItemValue(QStringLiteral("transparent"));
    if(query.hasQueryItem(QStringLiteral("transparent")) && transparent!=QStringLiteral("0") && transparent!=QStringLiteral("1")){*error=QStringLiteral("Invalid preview transparency flag.");return {};}
    return source->crop(page,region,scale,annotations!=QStringLiteral("0"),transparent==QStringLiteral("1"),error);
}
QImage NativeImageProvider::requestImage(const QString &id,QSize *size,const QSize &) {
    const QUrl url(QStringLiteral("image://lyrapreview/")+id);const QUrlQuery query(url);
    auto image=rawImage(url);
    if(!image.isNull())image=PaperAppearance::displayImage(image,PaperAppearance::mode(query.queryItemValue(QStringLiteral("paper"))));
    if(size)*size=image.size();
    return image;
}
