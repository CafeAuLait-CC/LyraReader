#pragma once
#include "ReaderController.h"
#include <QObject>
#include <QVariantMap>

// Native presentation, like ReaderMarkdown on Mac. PDF/text/AI rules are not
// parsed here; mathematical expressions use the existing shared Rust adapter.
class ReadingMarkdown : public QObject {
    Q_OBJECT
public:
    using QObject::QObject;
    Q_INVOKABLE QVariantMap render(const QString &source, ReaderController *reader,
        const QVariantList &verifiedPages, int pageCount, int bodySize,
        const QVariantMap &colours) const;
};
