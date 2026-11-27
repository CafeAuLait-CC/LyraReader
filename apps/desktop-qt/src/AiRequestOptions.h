#pragma once
#include <QObject>
#include <QVariantMap>
#include <cmath>

// JSON has no non-finite number. Reject unrepresentable optional settings before
// Qt can turn them into null (which would mean a valid provider default).
// Numeric bounds and request policy remain in the shared Rust builder.
inline QString aiGenerationSerializationError(const QVariantMap &request) {
    for(const char *key:{"temperature","max_tokens"}) {
        const auto value=request.value(QLatin1String(key));
        if(!value.isValid() || value.metaType().id()==QMetaType::Nullptr)continue;
        switch(value.metaType().id()) {
        case QMetaType::Double:case QMetaType::Float:
            if(!std::isfinite(value.toDouble()))return QObject::tr("The %1 setting must be finite. Adjust it in Settings.").arg(QLatin1String(key));
            break;
        case QMetaType::Int:case QMetaType::UInt:case QMetaType::LongLong:case QMetaType::ULongLong:break;
        default:return QObject::tr("The %1 setting must be a number or the provider default. Adjust it in Settings.").arg(QLatin1String(key));
        }
    }
    return {};
}
