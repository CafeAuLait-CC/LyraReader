#include "NativeRaster.h"
#include "PaperAppearance.h"
#include <QHash>
#include <QBuffer>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMutex>
#include <QUuid>
#include <QUrlQuery>
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
QVariant NativeRasterSource::query(const QVariantMap &request,QString *error) const {
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
QImage NativeImageProvider::rawImage(const QUrl &url,qint64 maximumBytes) {
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
    const auto number=[&](const QString &key){bool valid=false;const double value=query.queryItemValue(key).toDouble(&valid);return valid ? value : std::nan("");};
    const QRectF region(number(QStringLiteral("x")),number(QStringLiteral("y")),number(QStringLiteral("w")),number(QStringLiteral("h")));
    QString error;
    double scale=number(QStringLiteral("scale"));
    if(region.isEmpty() || !std::isfinite(scale) || scale<=0 || maximumBytes<4)return {};
    scale=qMin(scale,std::sqrt(double(maximumBytes)/(4*region.width()*region.height())));
    while(std::ceil(region.width()*scale)*std::ceil(region.height()*scale)*4>maximumBytes)scale*=.99;
    return source->crop(page,region,scale,true,false,&error);
}
QImage NativeImageProvider::requestImage(const QString &id,QSize *size,const QSize &) {
    const QUrl url(QStringLiteral("image://lyrapreview/")+id);const QUrlQuery query(url);
    auto image=rawImage(url);
    if(!image.isNull())image=PaperAppearance::displayImage(image,PaperAppearance::mode(query.queryItemValue(QStringLiteral("paper"))));
    if(size)*size=image.size();
    return image;
}
