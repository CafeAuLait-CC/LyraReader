#pragma once
#include <QObject>
#include <QVariantMap>
#include <QVector>
class QTextDocument;

// Geometry in native text-document coordinates, independent of PDF/AI state.
// The caller maps the control's actual padding into its own preview coordinates.
class ReadingTextGeometry : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    // Raw UTF-16 boundary -> native document offset; -1 marks CRLF/surrogate interiors.
    static QVector<int> sourceBoundaries(QTextDocument *document,const QString &source);
    Q_INVOKABLE QVariantMap tail(QObject *document, double limit, int maximumLines,
                                double actionWidth, double availableWidth) const;
    // Native TextEdit positions are UTF-16 offsets after newline normalization.
    // Copy from the canonical passage only after verifying that projection.
    Q_INVOKABLE QVariantMap sourceSelection(QObject *document, const QString &source,
                                           int start, int end) const;
    Q_INVOKABLE QString toolTip(QObject *document, int position) const;
};
