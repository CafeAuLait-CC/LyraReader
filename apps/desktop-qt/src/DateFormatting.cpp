#include "DateFormatting.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QFontDatabase>
#include <QFontMetricsF>
#include <QLocale>
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
    font.setPixelSize(14);
    const QFontMetricsF metrics(font);
    const double width = metrics.horizontalAdvance(text) + 16, height = metrics.height() + 12;
    if (!std::isfinite(width) || !std::isfinite(height) || width <= 0 || height <= 0 || width > 8192 || height > 8192)
        return failure("The date could not be measured in the system font.");
    return {{"text", text}, {"width", width}, {"height", height}};
}
