#include "SignatureArtwork.h"
#include <QBuffer>
#include <QCoreApplication>
#include <QFontDatabase>
#include <QFontMetricsF>
#include <QImage>
#include <QPainter>
#include <cmath>

QStringList SignatureArtwork::fonts() {
    static const auto available=[] {
        const auto installed=QFontDatabase::families();QStringList result;
        for(const auto &preferred:{"Z003","URW Chancery L","TeX Gyre Chorus","Segoe Script","Lucida Handwriting"}) {
            for(const auto &family:installed)if(family.compare(QLatin1String(preferred),Qt::CaseInsensitive)==0){result.append(family);break;}
        }
        const auto system=QFontDatabase::systemFont(QFontDatabase::GeneralFont).family();
        if(!result.contains(system))result.append(system);
        for(const auto &family:installed)if(!result.contains(family))result.append(family);
        return result;
    }();
    return available;
}

QVariantMap SignatureArtwork::typed(const QString &name,const QString &family) {
    const auto failure=[](const char *message){return QVariantMap{{"error",QCoreApplication::translate("SignatureArtwork",message)}};};
    // Bound user text before font shaping or pixel allocation, including programmatic callers.
    if(name.size()>256)return failure("Use up to 256 characters for a typed signature.");
    const auto text=name.trimmed();
    if(text.isEmpty())return failure("Type a name before placing the signature.");
    for(const auto character:text)if(character.category()==QChar::Other_Control || character==QChar::LineSeparator || character==QChar::ParagraphSeparator)
        return failure("Use a single line of text for the signature.");
    if(!fonts().contains(family))return failure("Choose an installed signature font.");
    QFont font(family);font.setPixelSize(72);
    const auto ink=QFontMetricsF(font).tightBoundingRect(text);
    if(ink.isEmpty() || !std::isfinite(ink.width()) || !std::isfinite(ink.height()))
        return failure("That name could not be drawn in the chosen font.");
    const auto logical=ink.adjusted(-14,-14,14,14);
    const auto scale=qMin(2.0,qMin(2048.0/logical.width(),512.0/logical.height()));
    const double w=std::ceil(logical.width()*scale),h=std::ceil(logical.height()*scale);
    if(!std::isfinite(w) || !std::isfinite(h) || w<1 || h<1 || w>2048 || h>512)
        return failure("The signature preview is too large.");
    QImage image(int(w),int(h),QImage::Format_ARGB32_Premultiplied);
    if(image.isNull())return failure("There is not enough memory to draw the signature.");
    image.fill(Qt::transparent);
    {
        QPainter painter(&image);painter.setRenderHint(QPainter::TextAntialiasing);
        painter.setFont(font);painter.setPen(Qt::black);painter.scale(scale,scale);
        painter.translate(-logical.x(),-logical.y());painter.drawText(QPointF(0,0),text);
    }
    QByteArray encoded;QBuffer buffer(&encoded);
    if(!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer,"PNG"))
        return failure("The signature preview could not be encoded.");
    return {{"image",QString::fromLatin1(encoded.toBase64())},{"width",image.width()},{"height",image.height()},{"font",family}};
}
