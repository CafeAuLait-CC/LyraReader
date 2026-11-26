#pragma once
#include <QObject>
#include <QVariantMap>

// Geometry in native text-document coordinates, independent of PDF/AI state.
// The caller maps the control's actual padding into its own preview coordinates.
class ReadingTextGeometry : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    Q_INVOKABLE QVariantMap tail(QObject *document, double limit, int maximumLines,
                                double actionWidth, double availableWidth) const;
};
