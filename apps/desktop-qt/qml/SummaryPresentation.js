// Presentation grammar mirrors ReaderMarkdown / AIReadingSummaryContent. It does
// not edit provider text, request bodies, saved notes, or trusted source pages.
function sections(source) {
    const lines = String(source || "").split(/\r\n|\n|\r/);
    const groups = [];
    let current = null, prose = [], blocks = 0, limited = false;
    function group() {
        if (!current) { current = {title: "", blocks: []}; groups.push(current); }
        return current;
    }
    function put(kind, text, language = "") {
        if (!text.trim()) return;
        group().blocks.push({kind: kind, text: text, language: language}); ++blocks;
    }
    function flush() { put("prose", prose.join("\n").trim()); prose = []; }
    for (let index = 0; index < lines.length; ++index) {
        // Bound native controls for pathological answers. Retain every remaining
        // character as selectable literal text instead of dropping the answer.
        if (groups.length >= 256 || blocks >= 512) {
            flush(); put("code", lines.slice(index).join("\n")); limited = true; break;
        }
        const raw = lines[index], line = raw.trim();
        if (line.indexOf("```") === 0 || line.indexOf("~~~") === 0) {
            flush(); const marker = line.slice(0, 3), code = [];
            for (++index; index < lines.length; ++index) {
                if (lines[index].trim().indexOf(marker) === 0) break;
                code.push(lines[index]);
            }
            put("code", code.join("\n"), line.slice(3).trim()); continue;
        }
        if (line.indexOf("$$") === 0 || line.indexOf("\\[") === 0) {
            const closer = line.indexOf("$$") === 0 ? "$$" : "\\]";
            prose.push(raw);
            if (line.slice(2).indexOf(closer) < 0) {
                for (++index; index < lines.length; ++index) {
                    prose.push(lines[index]);
                    if (lines[index].indexOf(closer) >= 0) break;
                }
            }
            continue;
        }
        const heading = /^(#{1,6}) (.+)$/.exec(line);
        if (heading) {
            flush(); current = {title: heading[2].trim(), blocks: []}; groups.push(current);
        } else prose.push(raw);
    }
    flush();
    return {groups: groups, limited: limited};
}

function headingText(text) {
    // Headings use plain native labels; provider HTML and URLs are never active.
    return String(text).replace(/\*\*([^*]+)\*\*/g, "$1")
        .replace(/`([^`]+)`/g, "$1").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
}
