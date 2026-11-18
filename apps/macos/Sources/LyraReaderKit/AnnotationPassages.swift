import AppKit
import NaturalLanguage
import SwiftUI
import LyraReaderBindings

/// Source geometry, Unicode offsets and context expansion share Rust's immutable map.
/// NaturalLanguage remains the native sentence-boundary provider, preserving macOS behaviour.
package struct AnnotationSentenceMap {
    package let text: String
    package let sentences: [Range<Int>]
    private let shared: LyraReaderAnnotationTextMap
    private var documentRanges: [String: Range<Int>] = [:]
    private var resolvedDocumentRanges: Set<String> = []

    package init(_ page: TextPage) throws {
        shared = try annotationTextMapForText(chars: page.sharedTextCharacters(maximum: 65_536))
        let text = shared.text()
        self.text = text
        let tokenizer = NLTokenizer(unit: .sentence)
        var sentences: [Range<Int>] = []
        var paragraphOffset = 0
        for paragraph in text.components(separatedBy: "\n\n") {
            tokenizer.string = paragraph
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let ns = NSRange(range, in: paragraph)
                sentences.append((paragraphOffset + ns.location)..<(paragraphOffset + ns.location + ns.length))
                return true
            }
            paragraphOffset += paragraph.utf16.count + 2
        }
        self.sentences = sentences.isEmpty && !text.isEmpty ? [0..<text.utf16.count] : sentences
    }
    private func range(_ record: AnnotationContextSpanRecord?) -> Range<Int>? {
        record.map { Int($0.start)..<Int($0.end) }
    }
    private func record(_ range: Range<Int>) throws -> AnnotationContextSpanRecord {
        guard let start = UInt32(exactly: range.lowerBound), let end = UInt32(exactly: range.upperBound) else {
            throw NSError(domain: "LyraReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The annotation context range is invalid."])
        }
        return AnnotationContextSpanRecord(start: start, end: end)
    }
    mutating func range(for annotation: DocumentAnnotation, page: TextPage) throws -> Range<Int>? {
        if resolvedDocumentRanges.contains(annotation.id) { return documentRanges[annotation.id] }
        let range = try span(overlapping: annotation.boxes.map {
            CGRect(x: $0.xPt, y: $0.yPt, width: $0.widthPt, height: $0.heightPt)
        }, page: page)
        resolvedDocumentRanges.insert(annotation.id)
        documentRanges[annotation.id] = range
        return range
    }
    package func span(overlapping regions: [CGRect], page _: TextPage) throws -> Range<Int>? {
        range(try shared.regionsSpan(regions: regions.map {
            AiSourceRectRecord(xPt: Double($0.minX), yPt: Double($0.minY),
                               widthPt: Double($0.width), heightPt: Double($0.height))
        }))
    }
    package func span(indices: [Int]) throws -> Range<Int>? {
        // Missing offsets, including negative indices, have always been omitted.
        range(try shared.indicesSpan(indices: indices.compactMap { UInt32(exactly: $0) }))
    }
    package func sentence(containing mark: Range<Int>) throws -> Range<Int> {
        let result = try shared.contextSpan(mark: record(mark), sentences: sentences.map { try record($0) })
        return Int(result.start)..<Int(result.end)
    }
}

package enum AnnotationSource: Hashable {
    case document(String), own(UUID)
    var key: String {
        switch self { case .document(let id): "pdf-\(id)"; case .own(let id): "own-\(id)" }
    }
}

package struct PassageMark: Identifiable {
    package var id: String { source.key }
    package let source: AnnotationSource
    package let range: Range<Int>
    package let kind: AppState.Annotation.Kind
    package let color: AnnotationColor
    package let opacity: Double
    package let note: String
    package let author: String?
    package let date: String?
}

package struct AnnotationPassage: Identifiable {
    package let id: String
    package let page: Int
    package let text: String
    package let start: Int
    package let marks: [PassageMark]

    @MainActor package func attributed(appearance: PaperAppearance) -> AttributedString {
        var result = AttributedString(text)
        for mark in marks {
            let range = NSRange(location: max(0, mark.range.lowerBound - start), length: mark.range.count)
            guard let swiftRange = Range(range, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result) else { continue }
            let span = lower..<upper
            let color = Color(nsColor: appearance.displayColor(mark.color.nsColor.withAlphaComponent(mark.opacity)))
            switch mark.kind {
            case .highlight: result[span].backgroundColor = color
            case .underline: result[span].swiftUI.underlineStyle = Text.LineStyle(color: color)
            case .strikeout: result[span].swiftUI.strikethroughStyle = Text.LineStyle(color: color)
            default: break
            }
        }
        return result
    }

    @MainActor package static func build(document: [DocumentAnnotation], own: [AppState.Annotation],
                                 pages: [Int: TextPage], maps: inout [Int: AnnotationSentenceMap], report: (String) -> Void) -> [Self] {
        var grouped: [Int: [(range: Range<Int>, mark: PassageMark)]] = [:]
        for annotation in document where annotation.visible && !annotation.isReply && annotation.drawing == .markup {
            guard let page = pages[annotation.page], maps[annotation.page] != nil else { continue }
            do {
                guard let range = try maps[annotation.page]?.range(for: annotation, page: page),
                      let map = maps[annotation.page] else { continue }
                let kind: AppState.Annotation.Kind = ["underline", "squiggly"].contains(annotation.kind) ? .underline
                    : (annotation.kind == "strikeout" ? .strikeout : .highlight)
                let mark = PassageMark(source: .document(annotation.id), range: range, kind: kind,
                    color: annotation.color ?? .init(red: 255, green: 221, blue: 90, alpha: 255),
                    opacity: annotation.opacity ?? 1, note: annotation.contents ?? "",
                    author: annotation.author, date: annotation.displayDate)
                grouped[annotation.page, default: []].append((try map.sentence(containing: range), mark))
            } catch { report(error.localizedDescription) }
        }
        for annotation in own where annotation.kind.isTextMarkup {
            guard let map = maps[annotation.page], let page = pages[annotation.page] else { continue }
            do {
                let resolved: Range<Int>?
                if let quads = annotation.fileQuads, !quads.isEmpty {
                    resolved = try map.span(overlapping: quads.map {
                        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    }, page: page)
                } else {
                    guard annotation.start >= 0, annotation.start < page.chars.count,
                          annotation.start <= annotation.end else { continue }
                    resolved = try map.span(indices: Array(annotation.start...min(annotation.end, page.chars.count - 1)))
                }
                guard let range = resolved else { continue }
                let mark = PassageMark(source: .own(annotation.id), range: range, kind: annotation.kind,
                    color: annotation.color, opacity: Double(annotation.color.alpha) / 255,
                    note: annotation.note, author: nil,
                    date: annotation.createdAt.formatted(date: .abbreviated, time: .shortened))
                grouped[annotation.page, default: []].append((try map.sentence(containing: range), mark))
            } catch { report(error.localizedDescription) }
        }
        var result: [Self] = []
        for page in grouped.keys.sorted() {
            guard let map = maps[page] else { continue }
            guard let entries = grouped[page] else { continue }
            let clusters: [AnnotationContextClusterRecord]
            do {
                clusters = try annotationContextClusters(ranges: entries.map {
                    AnnotationContextSpanRecord(start: UInt32($0.range.lowerBound), end: UInt32($0.range.upperBound))
                })
            } catch { report(error.localizedDescription); continue }

            for cluster in clusters {
                guard cluster.indices.allSatisfy({ Int($0) < entries.count }) else {
                    report("The annotation context returned an invalid mark index."); continue
                }
                let range = NSRange(location: Int(cluster.span.start), length: Int(cluster.span.end - cluster.span.start))
                result.append(Self(id: "\(page):\(range.location)", page: page,
                    text: (map.text as NSString).substring(with: range), start: range.location, marks: cluster.indices.map { entries[Int($0)].mark }))
            }
        }
        return result
    }
}

package struct AnnotationSidebarPage: Identifiable {
    package let id: Int
    package let rows: [Row]
    package let annotationCount: Int
    package enum Row: Identifiable {
        case passage(AnnotationPassage), document(AnnotationPanelRow), own(AppState.Annotation)
        indirect case thread(root: Row, replies: [AnnotationPanelRow])
        package var id: String {
            switch self {
            case .passage(let value): "passage-\(value.id)"
            case .document(let value): "document-\(value.id)"
            case .own(let value): "own-\(value.id)"
            case .thread(let root, _): root.id
            }
        }
        package func contains(_ source: AnnotationSource) -> Bool {
            switch self {
            case .passage(let value): value.marks.contains { $0.source == source }
            case .document(let value): source == .document(value.id)
            case .own(let value): source == .own(value.id)
            case .thread(let root, let replies): root.contains(source) || replies.contains { source == .document($0.id) }
            }
        }
    }

    @MainActor package static func build(passages: [AnnotationPassage], document: [DocumentAnnotation],
                                 own: [AppState.Annotation]) -> [Self] {
        var bySource: [AnnotationSource: AnnotationPassage] = [:]
        for passage in passages { for mark in passage.marks { bySource[mark.source] = passage } }
        var emitted: [String: (page: Int, index: Int)] = [:]
        var rows: [Int: [Row]] = [:]
        var counts: [Int: Int] = [:]
        func append(source: AnnotationSource, page: Int, fallback: Row) -> (page: Int, index: Int) {
            counts[page, default: 0] += 1
            if let passage = bySource[source], let existing = emitted[passage.id] { return existing }
            let position = (page: page, index: rows[page, default: []].count)
            if let passage = bySource[source] {
                emitted[passage.id] = position
                rows[page, default: []].append(.passage(passage))
            } else { rows[page, default: []].append(fallback) }
            return position
        }
        func attach(_ replies: [AnnotationPanelRow], to position: (page: Int, index: Int)) {
            guard !replies.isEmpty else { return }
            // Positions come from append; the arrays only grow or replace existing items.
            let root = rows[position.page]![position.index]
            if case .thread(let parent, let existing) = root {
                rows[position.page]![position.index] = .thread(root: parent, replies: existing + replies)
            } else { rows[position.page]![position.index] = .thread(root: root, replies: replies) }
            counts[position.page, default: 0] += replies.count
        }
        var adoptedParents: [String: Int] = [:]
        for annotation in own {
            if let identity = annotation.fileIdentity { adoptedParents[identity] = annotation.page }
        }
        let panel = AnnotationPanelModel.build(from: document, adoptedParents: adoptedParents)
        for section in panel.sections {
            var parent: (page: Int, index: Int)?
            for row in section.rows {
                if row.depth == 0 {
                    parent = append(source: .document(row.id), page: section.page, fallback: .document(row))
                } else if let parent { attach([row], to: parent) }
            }
        }
        for annotation in own {
            let position = append(source: .own(annotation.id), page: annotation.page, fallback: .own(annotation))
            if let identity = annotation.fileIdentity { attach(panel.adoptedReplies[identity] ?? [], to: position) }
        }
        return rows.keys.sorted().map { Self(id: $0, rows: rows[$0]!, annotationCount: counts[$0] ?? 0) }
    }
}
