#pragma once
#include <QString>
#include <QVariantMap>

// Native locale formatting belongs to the shell, like Foundation's DateFormatter.
// PDF dates, annotation codecs and saved metadata remain with the shared Rust engine.
namespace DateFormatting {
inline constexpr int fontSizePt = 14;
QVariantMap format(const QString &style, const QString &isoDay = {}, const QString &localeName = {});
QVariantMap picture(const QString &text, int clockwiseDegrees);
}
