#include "ReadingTextGeometry.h"
#include <QAbstractTextDocumentLayout>
#include <QQuickTextDocument>
#include <QGlyphRun>
#include <QSet>
#include <QTextBlock>
#include <QTextBoundaryFinder>
#include <QTextCursor>
#include <QTextLayout>
#include <QThread>
#include <cmath>

QString ReadingTextGeometry::toolTip(QObject *document,int position) const {
    auto *quick=qobject_cast<QQuickTextDocument *>(document);
    if(!quick || quick->thread()!=QThread::currentThread() || !quick->textDocument())return {};
    auto *text=quick->textDocument();
    if(position<0 || position>=text->characterCount()-1)return {};
    QTextCursor cursor(text);cursor.setPosition(position);
    cursor.movePosition(QTextCursor::NextCharacter,QTextCursor::KeepAnchor);
    const auto hint=cursor.charFormat().toolTip();
    // Hover is optional presentation; oversized or absent metadata has no hint.
    return hint.size()<=4096?hint:QString{};
}

QVariantMap ReadingTextGeometry::sourceSelection(QObject *document, const QString &source,
                                               int start, int end) const {
    const auto changed = [this] {
        return QVariantMap{{QStringLiteral("error"), tr("The displayed passage changed. Select it again before copying.")}};
    };
    auto *quick = qobject_cast<QQuickTextDocument *>(document);
    if (!quick || quick->thread() != QThread::currentThread() || !quick->textDocument()) return changed();
    // toRawText keeps NBSP and native line/paragraph separators. toPlainText
    // would lose their distinction and cannot validate a canonical source.
    const auto native = quick->textDocument()->toRawText();
    const auto first = qMin(start, end), last = qMax(start, end);
    if (first < 0 || last > native.size()) return changed();
    qsizetype position = 0, rawFirst = -1, rawLast = -1;
    for (qsizetype raw = 0; raw < source.size();) {
        if (position == first) rawFirst = raw;
        if (position == last) rawLast = raw;
        auto character = source.at(raw++);
        if (character == QLatin1Char('\r')) {
            if (raw < source.size() && source.at(raw) == QLatin1Char('\n')) ++raw;
            character = QChar::ParagraphSeparator;
        } else if (character == QLatin1Char('\n')) character = QChar::ParagraphSeparator;
        if (position >= native.size() || native.at(position++) != character) return changed();
    }
    if (position != native.size()) return changed();
    if (position == first) rawFirst = source.size();
    if (position == last) rawLast = source.size();
    const auto splitsSurrogate = [&](qsizetype offset) {
        return offset > 0 && offset < source.size() && source.at(offset).isLowSurrogate()
            && source.at(offset - 1).isHighSurrogate();
    };
    if (rawFirst < 0 || rawLast < rawFirst || splitsSurrogate(rawFirst) || splitsSurrogate(rawLast)) return changed();
    return {{QStringLiteral("text"), source.mid(rawFirst, rawLast - rawFirst)}};
}

QVariantMap ReadingTextGeometry::tail(QObject *document, double limit, int maximumLines,
                                    double actionWidth, double availableWidth) const {
    QVariantMap result{{QStringLiteral("measured"), false}};
    auto *quick = qobject_cast<QQuickTextDocument *>(document);
    if (!quick || quick->thread() != QThread::currentThread() || !std::isfinite(limit)
        || limit <= 0 || maximumLines < 0 || !std::isfinite(actionWidth) || actionWidth < 0
        || !std::isfinite(availableWidth) || availableWidth <= 0)
        return result;
    auto *text = quick->textDocument();
    if (!text || !text->documentLayout()) return result;
    QTextLine tail;
    QTextBlock tailBlock;
    QPointF blockOrigin;
    int lines = 0;
    bool hidden = false;
    // Native layout is already needed to display the text. A clipped preview
    // visits only its visible lines, not the rest of a long response.
    for (auto block = text->begin(); block.isValid() && !hidden; block = block.next()) {
        const auto *layout = block.layout();
        if (!layout) continue;
        const auto origin = layout->position();
        for (int index = 0; index < layout->lineCount(); ++index) {
            const auto line = layout->lineAt(index);
            if ((maximumLines && lines >= maximumLines) || origin.y() + line.y() + line.height() > limit + .5) {
                hidden = true; break;
            }
            ++lines; tail = line; tailBlock = block; blockOrigin = origin;
        }
    }
    if (!tail.isValid()) return result;
    const auto rect = tail.naturalTextRect().translated(blockOrigin);
    const auto width = availableWidth;
    const auto start = tail.textStart();
    const auto end = qMin(start + tail.textLength(), tailBlock.length() - 1);
    result = {{QStringLiteral("measured"), true}, {QStringLiteral("hidden"), hidden},
              {QStringLiteral("top"), rect.top()}, {QStringLiteral("bottom"), blockOrigin.y() + tail.y() + tail.height()},
              {QStringLiteral("baseline"), blockOrigin.y() + tail.y() + tail.ascent()},
              {QStringLiteral("inline"), false}};
    // A malicious combining sequence can put millions of UTF-16 units on one
    // visual line. Keep this UI query bounded and use the existing footer instead.
    constexpr int maximumPreviewLineUnits = 4096;
    if (end < start || end - start > maximumPreviewLineUnits || width < actionWidth + 6) return result;
    QTextCursor cursor(text);
    cursor.setPosition(tailBlock.position() + start);
    cursor.setPosition(tailBlock.position() + end, QTextCursor::KeepAnchor);
    const auto source = cursor.selectedText();
    if (source.contains(QChar::ObjectReplacementCharacter)) return result;
    const bool rtl = tail.cursorToX(start) > tail.cursorToX(end);
    const double capacity = width - actionWidth;
    double x = rtl ? rect.left() - actionWidth - 3 : rect.right() + 3;
    int cut = end;
    if (x < 0 || x > capacity) {
        QTextBoundaryFinder boundary(QTextBoundaryFinder::Grapheme, source);
        boundary.setPosition(source.size());
        if (!boundary.isAtBoundary()) boundary.toPreviousBoundary();
        QSet<qsizetype> glyphStarts;
        for (const auto &run : tail.glyphRuns(start, end - start, QTextLayout::RetrieveStringIndexes))
            for (const auto position : run.stringIndexes()) glyphStarts.insert(position);
        // Never cover half a surrogate pair, combining sequence or native glyph.
        // Bidi lines use the native cursor positions instead of character widths.
        while (boundary.position() >= 0) {
            cut = start + boundary.position();
            if (cut != end && !glyphStarts.contains(cut)) {
                if (boundary.toPreviousBoundary() < 0) break;
                continue;
            }
            const auto edge = blockOrigin.x() + tail.cursorToX(cut);
            x = rtl ? edge - actionWidth - 3 : edge + 3;
            if (x >= 0 && x <= capacity) break;
            if (boundary.toPreviousBoundary() < 0) break;
        }
    }
    if (!std::isfinite(x) || x < 0 || x > capacity) return result;
    result.insert(QStringLiteral("inline"), true);
    result.insert(QStringLiteral("rtl"), rtl);
    result.insert(QStringLiteral("x"), x);
    result.insert(QStringLiteral("mask_x"), rtl ? 0.0 : x);
    result.insert(QStringLiteral("mask_width"), rtl ? x + actionWidth : width - x);
    result.insert(QStringLiteral("cut_position"), tailBlock.position() + cut);
    return result;
}
