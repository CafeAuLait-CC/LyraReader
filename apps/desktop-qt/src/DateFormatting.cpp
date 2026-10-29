#include "DateFormatting.h"
#include <QCoreApplication>
#include <QBuffer>
#include <QDateTime>
#include <QFontDatabase>
#include <QFontMetricsF>
#include <QImage>
#include <QLocale>
#include <QPainter>
#include <QTimeZone>
#include <array>
#include <cmath>
#include <memory>
#include <unicode/udat.h>

QVariantMap DateFormatting::format(const QString &style, const QString &isoDay, const QString &localeName) {
    const auto failure = [](const char *message) {
        return QVariantMap{{"error", QCoreApplication::translate("DateFormatting", message)}};
    };
    if (isoDay.size() > 10 || localeName.size() > 128)
        return failure("The date or locale is invalid.");
    const QDate day = isoDay.isEmpty() ? QDate::currentDate() : QDate::fromString(isoDay, Qt::ISODate);
    if (!day.isValid() || (!isoDay.isEmpty() && day.toString(Qt::ISODate) != isoDay))
        return failure("Choose a valid calendar date.");
    QString text;
    if (style == "iso") {
        text = day.toString(Qt::ISODate);
    } else {
        UDateFormatStyle length;
        if (style == "medium") length = UDAT_MEDIUM;
        else if (style == "long") length = UDAT_LONG;
        else if (style == "short") length = UDAT_SHORT;
        else return failure("Choose Medium, Long, Short or ISO date format.");
        const QLocale locale = localeName.isEmpty() ? QLocale() : QLocale(localeName);
        if (!localeName.isEmpty() && locale.language() == QLocale::C && localeName != "C")
            return failure("Choose a valid date locale.");
        const auto identifier = locale.language() == QLocale::C ? QByteArray("en_US_POSIX") : locale.name().toUtf8();
        UErrorCode status = U_ZERO_ERROR;
        // A civil day has already been chosen in the local zone. Format noon UTC in
        // UTC so ICU cannot shift that day across a DST or date-line boundary.
        const UChar zone[] = {u'U', u'T', u'C', 0};
        std::unique_ptr<UDateFormat, decltype(&udat_close)> formatter(
            udat_open(UDAT_NONE, length, identifier.constData(), zone, 3, nullptr, 0, &status), &udat_close);
        if (U_FAILURE(status) || !formatter)
            return failure("The date formatter could not be opened.");
        std::array<UChar, 257> buffer{};
        const auto instant = QDateTime(day, QTime(12, 0), QTimeZone(QTimeZone::UTC)).toMSecsSinceEpoch();
        const auto count = udat_format(formatter.get(), double(instant), buffer.data(), int32_t(buffer.size()), nullptr, &status);
        if (U_FAILURE(status) || count <= 0 || count >= int32_t(buffer.size()))
            return failure("The formatted date is unavailable or too long.");
        // Both ICU UChar and QString's input are UTF-16 code units; the fixed buffer
        // bounds count before this copy. No file-controlled pixel allocation occurs.
        text = QString::fromUtf16(reinterpret_cast<const char16_t *>(buffer.data()), count);
    }
    QFont font = QFontDatabase::systemFont(QFontDatabase::GeneralFont);
    font.setPixelSize(fontSizePt);
    const QFontMetricsF metrics(font);
    const double width = metrics.horizontalAdvance(text) + 16, height = metrics.height() + 12;
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 || width > 8192 || height > 8192)
        return failure("The date could not be measured in the system font.");
    return {{"text", text}, {"width", width}, {"height", height}, {"fontSize", fontSizePt}};
}

QVariantMap DateFormatting::picture(const QString &text, int clockwiseDegrees) {
    const auto failure = [](const char *message) {
        return QVariantMap{{"error", QCoreApplication::translate("DateFormatting", message)}};
    };
    if (clockwiseDegrees != 0 && clockwiseDegrees != 90 && clockwiseDegrees != 180 && clockwiseDegrees != 270)
        return failure("Choose a date rotation of 0, 90, 180 or 270 degrees.");
    if (text.size() > 256 || text.trimmed().isEmpty())
        return failure("The date must contain between 1 and 256 characters.");
    for (const auto character : text)
        if (character.category() == QChar::Other_Control || character == QChar::LineSeparator || character == QChar::ParagraphSeparator)
            return failure("Use a single line for the date picture.");
    QFont font = QFontDatabase::systemFont(QFontDatabase::GeneralFont);
    font.setPixelSize(fontSizePt);
    const QFontMetricsF metrics(font);
    const auto ink = metrics.boundingRect(text);
    if (ink.isEmpty()) return failure("The date contains no drawable text.");
    const auto bounds = ink.united(QRectF(0, -metrics.ascent(), metrics.horizontalAdvance(text), metrics.height()));
    const double logicalWidth = std::ceil(bounds.width()) + 4, logicalHeight = std::ceil(bounds.height()) + 4;
    // Two page-point pixels per point, including two points of transparent padding.
    // Bound both live images before allocation; quarter turns preserve the pixel count.
    constexpr int scale = 2;
    if (!std::isfinite(bounds.left()) || !std::isfinite(bounds.top()) || !std::isfinite(logicalWidth) || !std::isfinite(logicalHeight) || logicalWidth < 1 || logicalHeight < 1 || logicalWidth > 2048 || logicalHeight > 2048)
        return failure("The date picture is too large.");
    const int width = int(logicalWidth) * scale, height = int(logicalHeight) * scale;
    if (quint64(width) * quint64(height) > 1024 * 1024)
        return failure("The date picture exceeds its pixel budget.");
    QImage source(width, height, QImage::Format_ARGB32_Premultiplied);
    if (source.isNull()) return failure("There is not enough memory to draw the date.");
    source.fill(Qt::transparent);
    {
        QPainter painter(&source);
        painter.setRenderHint(QPainter::TextAntialiasing);
        painter.setFont(font);painter.setPen(Qt::black);
        painter.scale(scale, scale);painter.translate(2 - bounds.left(), 2 - bounds.top());
        painter.drawText(QPointF(0, 0), text);
    }
    // QImage coordinates point downwards, so a positive quarter turn is clockwise.
    const auto rotated = clockwiseDegrees == 0 ? source : source.transformed(QTransform().rotate(clockwiseDegrees), Qt::FastTransformation);
    if (rotated.isNull()) return failure("The date picture could not be rotated.");
    QByteArray encoded;QBuffer buffer(&encoded);
    if (!buffer.open(QIODevice::WriteOnly) || !rotated.save(&buffer, "PNG"))
        return failure("The date picture could not be encoded.");
    return {{"image", QString::fromLatin1(encoded.toBase64())}, {"width", rotated.width()}, {"height", rotated.height()},
            {"widthPt", rotated.width() / double(scale)}, {"heightPt", rotated.height() / double(scale)}};
}
