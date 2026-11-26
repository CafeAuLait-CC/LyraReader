#include "ReadingMarkdown.h"
#include <QColor>
#include <QSet>
#include <QScopeGuard>
#include <QUrl>
#include <QUuid>
#include <algorithm>
#include <optional>
#include <utility>

namespace {
constexpr qsizetype maximumInput = 128 * 1024;
constexpr qsizetype maximumOutput = 8 * 1024 * 1024;
constexpr qsizetype maximumLines = 16384;
constexpr qsizetype maximumCells = 4096;
constexpr int maximumDepth = 16;
struct MathRun { QString marker, source, wrapped, rendered; };
struct InlineRun { QString text, rendered; };
struct InlineMath { qsizetype end; QString markup; };
struct ListItem { int indent; QString number, text; };
struct NativeTable { QVector<QStringList> rows; QStringList alignments; };
struct NativeBlock {
    QString kind, text, language;
    QVector<NativeBlock> children;
    std::optional<NativeTable> table = std::nullopt;
};
class Formatter {
public:
    Formatter(ReaderController *reader, const QString &source, const QVariantList &pages,
              int pageCount, const QVariantMap &colours)
        : m_reader(reader) {
        for (const auto &page : pages) { bool ok = false; const int value = page.toInt(&ok); if (ok && value > 0 && value <= pageCount) m_pages.insert(value); }
        for (const auto &name : {"accent", "separator", "raisedBg", "textSecondary", "warningFg"}) {
            const auto value = colours.value(QString::fromLatin1(name));
            const QColor colour = value.canConvert<QColor>() ? value.value<QColor>() : QColor{};
            if (!colour.isValid()) { m_limited = true; return; }
            m_colours.insert(QString::fromLatin1(name), colour.name(QColor::HexRgb));
        }
        m_prefix = QStringLiteral("LYRA-MATH-") + QUuid::createUuid().toString(QUuid::WithoutBraces) + QLatin1Char(':');
        m_inlinePrefix = m_prefix + QStringLiteral("INLINE:");
        if (source.contains(m_prefix)) m_limited = true;
    }
    bool limited() const { return m_limited; }
    QString document(const QString &source) {
        QString display = source; display.replace(QStringLiteral("\r\n"), QStringLiteral("\n")); display.replace(QLatin1Char('\r'), QLatin1Char('\n'));
        if (display.count(QLatin1Char('\n')) >= maximumLines) { m_limited = true; return {}; }
        const auto html = blocks(display.split(QLatin1Char('\n')), 0, m_blocks);
        if (m_limited) return {};
        formatInlines();
        formatMath();
        return expand(html);
    }
    QVariantList nativeBlocks(int bodySize) {
        if (m_limited || !m_hasNativeBlocks) return {};
        return expandBlocks(m_blocks, bodySize);
    }
private:
    QVariantList expandBlocks(const QVector<NativeBlock> &input, int bodySize) {
        QVariantList result;
        for (const auto &value : input) {
            QVariantMap block{{"kind", value.kind}};
            if (value.kind == "prose")
                block["text"] = QStringLiteral("<div style=\"font-size:") + QString::number(bodySize)
                    + QStringLiteral("px\">") + expand(value.text) + QStringLiteral("</div>");
            else if (value.kind == "quote") block["children"] = expandBlocks(value.children, bodySize);
            else if (value.kind == "table" && value.table) {
                QVariantList rows;
                for (const auto &row : value.table->rows) {
                    QVariantList cells;
                    for (qsizetype column = 0; column < row.size(); ++column)
                        cells.append(QVariantMap{{"text", QStringLiteral("<div style=\"font-size:12px\">") + expand(row[column]) + QStringLiteral("</div>")},
                            {"alignment", value.table->alignments[column]}});
                    rows.append(QVariant::fromValue(cells));
                }
                block["rows"] = rows;
                block["columns"] = value.table->alignments.size();
            }
            else { block["text"] = value.text; block["language"] = value.language; }
            result.append(block);
        }
        return result;
    }
    QString expand(const QString &html) {
        const auto expanded = expandInlines(html);
        QString result; qsizetype position = 0;
        while (position < expanded.size()) {
            const auto start = expanded.indexOf(m_prefix, position);
            if (start < 0) { append(result, QStringView(expanded).mid(position)); break; }
            append(result, QStringView(expanded).mid(position, start - position));
            const auto end = expanded.indexOf(QLatin1Char(';'), start + m_prefix.size());
            bool ok = false;
            const auto index = end < 0 ? -1 : QStringView(expanded).mid(start + m_prefix.size(), end - start - m_prefix.size()).toInt(&ok);
            if (!ok || index < 0 || index >= m_math.size()) { m_limited = true; return {}; }
            append(result, m_math[index].rendered); position = end + 1;
        }
        return result;
    }
    bool work(qsizetype units = 1) { m_work -= units; if (m_work < 0) m_limited = true; return !m_limited; }
    void append(QString &output, QStringView text) {
        if (text.size() > maximumOutput - output.size()) { m_limited = true; return; }
        output.append(text);
    }
    QString escape(QStringView text) const { return text.toString().toHtmlEscaped().replace(QLatin1Char('\n'), QStringLiteral("<br/>")); }
    QString colour(const char *name) const { return m_colours.value(QString::fromLatin1(name)); }
    qsizetype closing(QStringView text, QStringView marker, qsizetype start) {
        for (auto i = start; i + marker.size() <= text.size() && work(); ++i) {
            if (marker.front() != QLatin1Char('\\') && text[i] == QLatin1Char('\\')) { ++i; continue; }
            if (text.mid(i, marker.size()) == marker) return i;
        }
        return -1;
    }
    qsizetype labelClosing(QStringView text, qsizetype start) {
        int depth = 1;
        for (auto index = start; index < text.size() && work(); ++index) {
            if (text[index] == QLatin1Char('\\')) { ++index; continue; }
            if (text[index] == QLatin1Char('[')) ++depth;
            if (text[index] == QLatin1Char(']') && --depth == 0) return index;
        }
        return -1;
    }
    QString math(QString source, QString wrapped) {
        if (m_math.size() >= 256) { m_limited = true; return {}; }
        const auto marker = m_prefix + QString::number(m_math.size()) + QLatin1Char(';');
        m_math.append({marker, std::move(source), std::move(wrapped), {}});
        return marker;
    }
    QString mathFallback(const QString &source) const {
        // The shared parser reports success explicitly, but not a detailed
        // failure category. Do not invent a reason from its escaped markup.
        return QStringLiteral("<p align=\"left\" style=\"margin-top:0;margin-bottom:3px;font-size:11px;color:")
            + colour("warningFg") + QStringLiteral("\">")
            + ReadingMarkdown::tr("Could not render this expression. The original source is shown below.").toHtmlEscaped()
            + QStringLiteral("</p><pre align=\"left\" style=\"margin-top:0;margin-bottom:8px;padding:7px;white-space:pre-wrap;font-size:12px;background-color:")
            + colour("raisedBg") + QStringLiteral("\">") + source.toHtmlEscaped() + QStringLiteral("</pre>");
    }
    void formatMath() {
        // One bounded Rust call per batch, never one FFI call per character/run.
        for (qsizetype first = 0; first < m_math.size();) {
            QString batch; QVector<QPair<qsizetype, qsizetype>> ranges;
            qsizetype next = first;
            while (next < m_math.size()) {
                const auto &run = m_math[next];
                if (!run.rendered.isEmpty() || run.wrapped.toUtf8().size() > 60000) { ++next; ranges.append({-1, -1}); continue; }
                if (!batch.isEmpty() && batch.size() + run.wrapped.size() > 20000) break;
                const auto start = batch.size(); batch += run.wrapped; ranges.append({start, batch.size()}); batch += QLatin1Char('\n'); ++next;
            }
            const auto spans = m_reader && !batch.isEmpty() ? m_reader->aiMathMarkup(batch) : QVariantList{};
            for (qsizetype index = first; index < next; ++index) {
                auto &run = m_math[index]; const auto range = ranges[index - first];
                const auto found = std::find_if(spans.cbegin(), spans.cend(), [&](const QVariant &value) {
                    const auto span = value.toMap(); return span.value("start").toLongLong() == range.first && span.value("end").toLongLong() == range.second;
                });
                if (!run.rendered.isEmpty()) continue;
                run.rendered = mathFallback(run.source);
                if (found != spans.cend()) {
                    const auto span = found->toMap();
                    const auto markup = span.value("markup").toString();
                    if (span.value("rendered").metaType().id() != QMetaType::Bool
                        || span.value("display").metaType().id() != QMetaType::Bool || markup.isEmpty()) {
                        m_limited = true; return;
                    }
                    if (span.value("rendered").toBool()) run.rendered = markup;
                }
            }
            first = next;
        }
    }
    QString expandInlines(const QString &html) {
        QString result; qsizetype position = 0;
        while (position < html.size()) {
            const auto start = html.indexOf(m_inlinePrefix, position);
            if (start < 0) { append(result, QStringView(html).mid(position)); break; }
            append(result, QStringView(html).mid(position, start - position));
            const auto end = html.indexOf(QLatin1Char(';'), start + m_inlinePrefix.size());
            bool ok = false;
            const auto index = end < 0 ? -1 : QStringView(html).mid(start + m_inlinePrefix.size(), end - start - m_inlinePrefix.size()).toInt(&ok);
            if (!ok || index < 0 || index >= m_inline.size()) { m_limited = true; return {}; }
            append(result, m_inline[index].rendered); position = end + 1;
        }
        return result;
    }
    void formatInlines() {
        // Each Markdown paragraph owns its code-delimiter state. Combining
        // independent blocks into one string would let an unfinished backtick
        // suppress formulas in later blocks. These bounded native UI queries
        // reuse Rust's detector, never duplicate its math/currency grammar.
        m_renderingInline = true;
        int queries = 0;
        for (auto &run : m_inline) {
            m_inlineMath.clear();
            const bool hasMarkers = run.text.contains(QLatin1Char('$'))
                || run.text.contains(QStringLiteral("\\(")) || run.text.contains(QStringLiteral("\\["));
            QVariantList spans;
            if (m_reader && hasMarkers) {
                if (++queries > 256) { m_limited = true; return; }
                spans = m_reader->aiMathMarkup(run.text);
            }
            qsizetype previous = 0;
            for (const auto &value : spans) {
                const auto span = value.toMap(); bool startOk = false, endOk = false;
                const auto start = span.value("start").toLongLong(&startOk);
                const auto end = span.value("end").toLongLong(&endOk);
                const auto markup = span.value("markup").toString();
                if (!startOk || !endOk || start < previous || end <= start
                    || end > run.text.size() || markup.isEmpty()
                    || span.value("rendered").metaType().id() != QMetaType::Bool
                    || span.value("display").metaType().id() != QMetaType::Bool) { m_limited = true; return; }
                m_inlineMath.insert(start, {end, markup}); previous = end;
            }
            run.rendered = inlineText(run.text, 0);
            if (m_limited) return;
        }
    }
    QString inlineText(QStringView text, int depth, qsizetype offset = 0) {
        if (!m_renderingInline) {
            const auto marker = m_inlinePrefix + QString::number(m_inline.size()) + QLatin1Char(';');
            m_inline.append({text.toString(), {}});
            return marker;
        }
        if (depth > maximumDepth) { m_limited = true; return {}; }
        QString result;
        for (qsizetype i = 0; i < text.size() && work();) {
            const auto foundMath = m_inlineMath.constFind(offset + i);
            if (foundMath != m_inlineMath.cend() && foundMath->end <= offset + text.size()) {
                if (m_math.size() >= 256) { m_limited = true; return {}; }
                const auto marker = m_prefix + QString::number(m_math.size()) + QLatin1Char(';');
                m_math.append({marker, {}, {}, foundMath->markup});
                append(result, marker); i = foundMath->end - offset; continue;
            }
            const auto character = text[i];
            if (character == QLatin1Char('\\') && i + 1 < text.size()) {
                append(result, escape(text.mid(i + 1, 1))); i += 2; continue;
            }
            if (character == QLatin1Char('`')) {
                const auto end = closing(text, u"`", i + 1);
                const auto length = end < 0 ? text.size() - i - 1 : end - i - 1;
                append(result, QStringLiteral("<code>") + escape(text.mid(i + 1, length)) + QStringLiteral("</code>"));
                i = end < 0 ? text.size() : end + 1; continue;
            }
            if (character == QLatin1Char('*') || character == QLatin1Char('_') || (character == QLatin1Char('~') && i + 1 < text.size() && text[i + 1] == character)) {
                const bool doubled = i + 1 < text.size() && text[i + 1] == character;
                const auto marker = text.mid(i, doubled ? 2 : 1);
                const auto end = closing(text, marker, i + marker.size());
                if (end > i + marker.size() || (end < 0 && doubled && character != QLatin1Char('~'))) {
                    const auto body = end < 0 ? text.mid(i + marker.size()) : text.mid(i + marker.size(), end - i - marker.size());
                    const auto tag = character == QLatin1Char('~') ? QStringLiteral("s") : doubled ? QStringLiteral("b") : QStringLiteral("i");
                    append(result, QLatin1Char('<') + tag + QLatin1Char('>') + inlineText(body, depth + 1, offset + i + marker.size()) + QStringLiteral("</") + tag + QLatin1Char('>'));
                    i = end < 0 ? text.size() : end + marker.size(); continue;
                }
            }
            if (character == QLatin1Char('[')) {
                const auto close = labelClosing(text, i + 1);
                if (close > i + 3 && text.mid(i + 1, 2) == u"p.") {
                    const auto digits = text.mid(i + 3, close - i - 3); bool valid = !digits.isEmpty();
                    for (const auto digit : digits) valid = valid && digit >= QLatin1Char('0') && digit <= QLatin1Char('9');
                    bool ok = false; const int page = digits.toInt(&ok);
                    if (valid && ok && m_pages.contains(page)) { append(result, QStringLiteral("<a href=\"p.") + QString::number(page) + QStringLiteral("\" style=\"color:") + colour("accent") + QStringLiteral("\">") + escape(text.mid(i, close + 1 - i)) + QStringLiteral("</a>")); i = close + 1; continue; }
                }
                if (close >= 0 && close + 1 < text.size() && text[close + 1] == QLatin1Char('(')) {
                    qsizetype end = close + 2; int nesting = 1;
                    for (; end < text.size() && work(); ++end) { if (text[end] == QLatin1Char('(')) ++nesting; if (text[end] == QLatin1Char(')') && --nesting == 0) break; }
                    if (end < text.size()) {
                        const QUrl url(text.mid(close + 2, end - close - 2).toString().trimmed(), QUrl::TolerantMode);
                        if (safe(url)) { append(result, QStringLiteral("<a href=\"") + url.toString(QUrl::FullyEncoded).toHtmlEscaped() + QStringLiteral("\" style=\"color:") + colour("accent") + QStringLiteral("\">") + inlineText(text.mid(i + 1, close - i - 1), depth + 1, offset + i + 1) + QStringLiteral("</a>")); i = end + 1; continue; }
                    }
                }
            }
            if (character == QLatin1Char('<')) {
                const auto end = closing(text, u">", i + 1);
                if (end >= 0) { const QUrl url(text.mid(i + 1, end - i - 1).toString(), QUrl::TolerantMode); if (safe(url)) { append(result, QStringLiteral("<a href=\"") + url.toString(QUrl::FullyEncoded).toHtmlEscaped() + QStringLiteral("\" style=\"color:") + colour("accent") + QStringLiteral("\">") + escape(text.mid(i + 1, end - i - 1)) + QStringLiteral("</a>")); i = end + 1; continue; } }
            }
            append(result, escape(text.mid(i, 1))); ++i;
        }
        return result;
    }
    bool safe(const QUrl &url) const {
        // Native URL encoding accepts characters such as ^ in a destination.
        // Encoding never widens the allowed schemes, and activation is explicit.
        const auto scheme = url.scheme().toLower();
        return url.isValid() && (scheme == QStringLiteral("http") || scheme == QStringLiteral("https") || scheme == QStringLiteral("mailto"));
    }
    std::optional<ListItem> listItem(const QString &raw) const {
        int indent = 0; while (indent < raw.size() && (raw[indent] == QLatin1Char(' ') || raw[indent] == QLatin1Char('\t'))) ++indent;
        const auto text = raw.trimmed(); if (text.size() < 2) return {};
        qsizetype marker = 0; QString number;
        if (QStringLiteral("-*+").contains(text.front())) marker = 1;
        else { while (marker < text.size() && text[marker] >= QLatin1Char('0') && text[marker] <= QLatin1Char('9')) ++marker; if (!marker || marker + 1 >= text.size() || (text[marker] != QLatin1Char('.') && text[marker] != QLatin1Char(')'))) return {}; number = text.left(marker); ++marker; }
        if (marker >= text.size() || text[marker] != QLatin1Char(' ')) return {};
        return ListItem{indent, number, text.mid(marker + 1)};
    }
    int heading(const QString &line) const { int count = 0; while (count < line.size() && line[count] == QLatin1Char('#')) ++count; return count >= 1 && count <= 6 && count < line.size() && line[count] == QLatin1Char(' ') ? count : 0; }
    bool divider(const QString &line) const { QString value; for (const auto ch : line) if (!ch.isSpace()) value += ch; return value.size() >= 3 && (value == QString(value.size(), QLatin1Char('-')) || value == QString(value.size(), QLatin1Char('*')) || value == QString(value.size(), QLatin1Char('_'))); }
    bool startsBlock(const QString &line) const { const auto s = line.trimmed(); return s.isEmpty() || s.startsWith("```") || s.startsWith("~~~") || s.startsWith("$$") || s.startsWith("\\[") || heading(s) || divider(s) || s.startsWith('>') || listItem(line).has_value() || s.contains('|'); }
    QStringList cells(const QString &row) {
        QStringList result; QString current; bool code = false;
        for (qsizetype i = 0; i < row.size() && work(); ++i) {
            const auto ch = row[i];
            if (ch == QLatin1Char('\\') && i + 1 < row.size() && row[i + 1] == QLatin1Char('|')) { current += QLatin1Char('|'); ++i; continue; }
            if (ch == QLatin1Char('`')) code = !code;
            if (ch == QLatin1Char('|') && !code) { result += current.trimmed(); current.clear(); } else current += ch;
        }
        result += current.trimmed(); if (row.startsWith('|') && result.front().isEmpty()) result.removeFirst(); if (row.endsWith('|') && !result.isEmpty() && result.back().isEmpty()) result.removeLast(); return result;
    }
    bool separator(const QStringList &row) const { if (row.isEmpty()) return false; for (auto cell : row) { if (cell.startsWith(':')) cell.remove(0, 1); if (cell.endsWith(':')) cell.chop(1); if (cell.isEmpty() || cell != QString(cell.size(), QLatin1Char('-'))) return false; } return true; }
    void addBlock(QVector<NativeBlock> &blocks, NativeBlock block) {
        if (block.kind == "prose" && !blocks.isEmpty() && blocks.last().kind == "prose") {
            // Coalesce in owned storage, avoiding a QVariant copy/detach of the
            // entire accumulated paragraph string on every small paragraph.
            append(blocks.last().text, block.text);
        } else {
            if (++m_blockCount + m_nativeCells > 512) { m_limited = true; return; }
            blocks.append(std::move(block));
        }
    }
    QString blocks(const QStringList &lines, int depth, QVector<NativeBlock> &plan) {
        if (depth > maximumDepth) { m_limited = true; return {}; }
        QString output; QVector<int> indents;
        for (qsizetype index = 0; index < lines.size() && work();) {
            const auto beginning = output.size(); NativeBlock native;
            const auto capture = qScopeGuard([&] {
                if (output.size() == beginning) return;
                if (native.kind.isEmpty()) native = {"prose", output.mid(beginning), {}, {}};
                addBlock(plan, std::move(native));
            });
            const auto line = lines[index].trimmed(); if (line.isEmpty()) { ++index; indents.clear(); continue; }
            if (line.startsWith("```") || line.startsWith("~~~")) {
                const auto marker = line.left(3), language = line.mid(3).trimmed(); QStringList code; ++index;
                while (index < lines.size() && !lines[index].trimmed().startsWith(marker) && work()) code += lines[index++];
                if (index < lines.size()) ++index;
                native = {"code", code.join('\n'), language, {}};
                m_hasNativeBlocks = true;
                if (!language.isEmpty()) append(output, QStringLiteral("<p style=\"margin:0;font-size:9px;color:") + colour("textSecondary") + QStringLiteral("\">") + escape(language) + QStringLiteral("</p>"));
                append(output, QStringLiteral("<pre style=\"margin-top:0;margin-bottom:8px;padding:7px;white-space:pre-wrap;font-size:12px;background-color:") + colour("raisedBg") + QStringLiteral("\">") + code.join('\n').toHtmlEscaped() + QStringLiteral("</pre>")); continue;
            }
            if (line.startsWith("$$") || line.startsWith("\\[")) {
                const auto opener = line.left(2), closer = opener == QStringLiteral("$$") ? QStringLiteral("$$") : QStringLiteral("\\]");
                QStringList body; auto rest = line.mid(2); auto end = rest.indexOf(closer); ++index;
                if (end >= 0) body += rest.left(end);
                else { if (!rest.isEmpty()) body += rest; while (index < lines.size() && work()) { auto next = lines[index++]; end = next.indexOf(closer); body += end < 0 ? next : next.left(end); if (end >= 0) break; } }
                const auto source = body.join('\n').trimmed(); append(output, QStringLiteral("<div align=\"center\" style=\"margin-top:4px;margin-bottom:8px\">") + math(source, opener + source + closer) + QStringLiteral("</div>")); continue;
            }
            if (const int level = heading(line)) { const auto size = level == 1 ? QStringLiteral("17") : level == 2 ? QStringLiteral("14.5") : QStringLiteral("13"); append(output, QStringLiteral("<p style=\"margin-top:4px;margin-bottom:8px;font-size:") + size + QStringLiteral("px;font-weight:") + (level <= 2 ? QStringLiteral("700") : QStringLiteral("600")) + QStringLiteral("\">") + inlineText(line.mid(level).trimmed(), 0) + QStringLiteral("</p>")); ++index; indents.clear(); continue; }
            if (divider(line)) { append(output, QStringLiteral("<hr/>")); ++index; indents.clear(); continue; }
            if (line.contains('|')) {
                QVector<QStringList> rows; qsizetype columns = 0;
                while (index < lines.size() && !lines[index].trimmed().isEmpty() && lines[index].contains('|') && work()) { auto row = cells(lines[index++].trimmed()); columns = qMax(columns, row.size()); rows.append(std::move(row)); if (columns && rows.size() > maximumCells / columns) { m_limited = true; return {}; } }
                QStringList alignment; if (rows.size() > 1 && separator(rows[1])) { alignment = rows[1]; rows.remove(1); }
                // Row/column bounds above limit this product to maximumCells.
                // Bound native text controls before constructing their model.
                const auto count = rows.size() * columns;
                // Each cell has a hidden intrinsic-measurement document too.
                // The product above is <=4096, so doubling cannot overflow.
                const auto controls = count * 2;
                if (controls > 512 - m_blockCount - m_nativeCells - 1) { m_limited = true; return {}; }
                NativeTable table;
                for (qsizetype column = 0; column < columns; ++column) {
                    const auto align = column < alignment.size() ? alignment[column] : QString{};
                    table.alignments.append(align.startsWith(':') && align.endsWith(':') ? QStringLiteral("center") : align.endsWith(':') ? QStringLiteral("right") : QStringLiteral("left"));
                }
                append(output, QStringLiteral("<table border=\"1\" cellspacing=\"0\" cellpadding=\"5\" width=\"100%\" style=\"margin-bottom:8px;border-color:") + colour("separator") + QStringLiteral("\">"));
                for (qsizetype row = 0; row < rows.size(); ++row) {
                    QStringList cells; append(output, QStringLiteral("<tr>"));
                    for (qsizetype column = 0; column < columns; ++column) {
                        const auto text = column < rows[row].size() ? inlineText(rows[row][column], 0) : QString{};
                        cells.append(text); const auto tag = row == 0 ? QStringLiteral("th") : QStringLiteral("td");
                        append(output, QLatin1Char('<') + tag + QStringLiteral(" align=\"") + table.alignments[column] + QStringLiteral("\">") + text + QStringLiteral("</") + tag + QLatin1Char('>'));
                    }
                    table.rows.append(std::move(cells)); append(output, QStringLiteral("</tr>"));
                }
                if (columns > 0) {
                    m_nativeCells += int(controls); m_hasNativeBlocks = true;
                    native.kind = "table"; native.table = std::move(table);
                }
                append(output, QStringLiteral("</table>")); indents.clear(); continue;
            }
            if (line.startsWith('>')) {
                QStringList quote;
                while (index < lines.size() && lines[index].trimmed().startsWith('>') && work()) {
                    auto text = lines[index++].trimmed().mid(1); if (text.startsWith(' ')) text.remove(0, 1); quote += text;
                }
                QVector<NativeBlock> children; const auto quoted = blocks(quote, depth + 1, children);
                native = {"quote", {}, {}, std::move(children)};
                append(output, QStringLiteral("<table border=\"0\" cellspacing=\"0\" cellpadding=\"0\" style=\"margin-bottom:8px\"><tr><td width=\"2\" bgcolor=\"") + colour("separator") + QStringLiteral("\">&nbsp;</td><td width=\"10\">&nbsp;</td><td>") + quoted + QStringLiteral("</td></tr></table>"));
                indents.clear(); continue;
            }
            if (const auto item = listItem(lines[index])) {
                while (!indents.isEmpty() && indents.last() > item->indent) indents.removeLast();
                if (indents.isEmpty() || indents.last() < item->indent) indents.append(item->indent);
                QString body = item->text; ++index;
                while (index < lines.size() && !lines[index].trimmed().isEmpty() && !listItem(lines[index]) && !lines[index].trimmed().startsWith("```") && !lines[index].trimmed().startsWith("~~~") && work()) { int indent = 0; while (indent < lines[index].size() && (lines[index][indent] == ' ' || lines[index][indent] == '\t')) ++indent; if (indent <= item->indent) break; body += QLatin1Char(' ') + lines[index++].trimmed(); }
                const auto marker = item->number.isEmpty() ? indents.size() <= 1 ? QStringLiteral("•") : QStringLiteral("◦") : item->number + QLatin1Char('.');
                append(output, QStringLiteral("<p style=\"margin-top:0;margin-bottom:8px;margin-left:") + QString::number(qMin(qsizetype(5), indents.size() - 1) * 14) + QStringLiteral("px\">") + escape(marker) + QStringLiteral("&nbsp; ") + inlineText(body, 0) + QStringLiteral("</p>")); continue;
            }
            QString paragraph = line; bool hard = lines[index].endsWith("  "); ++index;
            while (index < lines.size() && !startsBlock(lines[index]) && work()) { paragraph += hard ? QLatin1Char('\n') : QLatin1Char(' '); paragraph += lines[index].trimmed(); hard = lines[index].endsWith("  "); ++index; }
            append(output, QStringLiteral("<p style=\"margin-top:0;margin-bottom:8px\">") + inlineText(paragraph, 0) + QStringLiteral("</p>")); indents.clear();
        }
        return output;
    }
    ReaderController *m_reader;
    QSet<int> m_pages;
    QMap<QString, QString> m_colours;
    QString m_prefix;
    QVector<MathRun> m_math;
    QVector<InlineRun> m_inline;
    QMap<qsizetype, InlineMath> m_inlineMath;
    QString m_inlinePrefix;
    bool m_renderingInline = false;
    QVector<NativeBlock> m_blocks;
    int m_blockCount = 0;
    int m_nativeCells = 0;
    bool m_hasNativeBlocks = false;
    qsizetype m_work = 2 * 1024 * 1024;
    bool m_limited = false;
};
}
QVariantMap ReadingMarkdown::render(const QString &source, ReaderController *reader,
    const QVariantList &pages, int pageCount, int bodySize, const QVariantMap &colours) const {
    const auto fallback = [&] { return QVariantMap{{"plain", true}, {"text", source}, {"warning", tr("This result is shown as plain text. Copy keeps the complete original text.")}}; };
    if (source.size() > maximumInput || source.toUtf8().size() > 128 * 1024 || bodySize < 8 || bodySize > 32 || pageCount < 0) return fallback();
    Formatter formatter(reader, source, pages, pageCount, colours);
    const auto html = formatter.document(source);
    const auto blocks = formatter.nativeBlocks(bodySize);
    if (formatter.limited()) return fallback();
    return {{"plain", false}, {"text", QStringLiteral("<div style=\"font-size:") + QString::number(bodySize) + QStringLiteral("px\">") + html + QStringLiteral("</div>")}, {"blocks", blocks}};
}
