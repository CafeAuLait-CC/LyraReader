import AppKit
import Foundation
import LyraReaderBindings
@testable import LyraReaderKit
import SwiftUI

@MainActor private final class InterleafLayoutHandle: AIChatHandle {
    var pending: [AIStreamEvent] = [.partStarted(index: 0, total: 1, label: "Synthetic region")]
    private(set) var isFinished = false
    func poll() -> [AIStreamEvent] {
        let events = pending; pending = []
        if events.contains(where: { if case .done = $0 { return true }; return false }) { isFinished = true }
        return events
    }
    func cancel() { pending = []; isFinished = true }
}

@MainActor private final class InterleafLayoutService: AIChatServicing {
    let base: RustAIChatService
    var handle = InterleafLayoutHandle()
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord { try await base.prepare(request) }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        handle = InterleafLayoutHandle(); return handle
    }
}

@MainActor private final class InterleafGrowthProbe: NSObject {
    let marker: AIRegionCardMarkerView
    let paper: PaperRegionHost
    let canvas: MetalCanvasView
    let page: Int
    var contentTops: [CGFloat] = []
    var gapErrors: [CGFloat] = []
    init(marker: AIRegionCardMarkerView, paper: PaperRegionHost, canvas: MetalCanvasView, page: Int) {
        self.marker = marker; self.paper = paper
        self.canvas = canvas; self.page = page
        super.init()
        marker.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(sample),
            name: NSView.frameDidChangeNotification, object: marker)
    }
    @objc func sample() {
        contentTops.append(marker.convert(marker.bounds, to: paper).minY)
        let segments = canvas.annotationPageFrames.filter { $0.index == page }.sorted { $0.topPt < $1.topPt }
        if segments.count == 2 {
            let gap = (segments[1].topPt - segments[0].topPt - segments[0].heightPt) * canvas.zoom
            gapErrors.append(abs(gap - paper.bounds.height))
        }
    }
}

extension ReaderChecks {
    @MainActor static func interleafStreamingLayoutChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-interleaf-layout-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("synthetic.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: source)
        let domain = "lyra-interleaf-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: "mock"))
        settings.prereadingPolicy = "never"
        _ = settings.save(baseURL: "http://localhost:11434/v1", model: "mock", temperature: 0.2, maxTokens: 4096, apiKey: nil)
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        require(state.open(url: source), "the Interleaf layout fixture opens")
        state.sidebarVisible = true; state.rightPanelVisible = false
        state.toggleAITools()
        let service = InterleafLayoutService(engine: engine)
        state.regionChatServiceOverride = { service }
        state.regionAssistantFactory = { AIAssistantModel(settings: settings) }
        let host = NSHostingView(rootView: ReaderWindow(state: state,
            opener: DocumentOpenCoordinator(state: state), aiAssistant: AIAssistantModel(settings: settings)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { state.closeAllRegionCards(keepHistory: false); window.orderOut(nil); window.contentView = nil }
        func canvas(in view: NSView) -> MetalCanvasView? {
            if let found = view as? MetalCanvasView { return found }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        try await eventually("the real reader mounts the Interleaf canvas", { canvas(in: host) != nil })
        let canvas = canvas(in: host)!
        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
        }
        state.zoomPercent = 100
        await state.createRegionCard(page: 1, rect: CGRect(x: 60, y: 60, width: 300, height: 140))
        let card = state.regionCards[0]
        try await eventually("the Interleaf card is measured before streaming", {
            host.layoutSubtreeIfNeeded()
            return canvas.regionCardFrames.count == 1 && card.heightViewPt > 120
        })
        try await eventually("the paper reveal has completed before the clipping check", {
            state.regionPaperRevealProgress(for: card.id) >= 1
        })
        // Leave less space than the initial card needs, as in a tear close to the window foot.
        let target = state.regionGapTop(for: card.id)! - (canvas.visibleRect.height - 96) / state.zoomFactor
        state.scroll(byScreenPoints: (target - state.scrollYPt) * state.zoomFactor)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        print("INTERLEAF-START frame=\(canvas.regionCardFrames) viewport=\(canvas.visibleRect) scroll=\(state.scrollYPt) target=\(target)")
        require(canvas.regionCardFrames[0].maxY > canvas.visibleRect.maxY,
                "the streaming fixture starts with its paper clipped by the window bottom")
        let paper = descendants(PaperRegionHost.self, in: canvas).first!
        let probe = InterleafGrowthProbe(marker: descendants(AIRegionCardMarkerView.self, in: paper).first!,
            paper: paper, canvas: canvas, page: card.attachment.page)
        defer { NotificationCenter.default.removeObserver(probe) }
        probe.sample()
        card.question = "Explain this synthetic comparison."
        await card.send(context: state.aiReaderContext!)
        require(card.assistant.isSending, "the controlled stream starts without a provider: \(card.assistant.phase) \(card.assistant.errorMessage ?? card.assistant.statusNote ?? "no message")")
        let synthetic = "## Synthetic comparison\n\n" + (1...12).map {
            "- **Result \($0):** 这是一段用于验证窗口底部布局的合成回答。The measured result remains grounded in its source and uses consistent notation. [p.2]\n\n"
        }.joined()
        // Optional local Markdown replay remains offline and is never part of the fixtures.
        let replay: [String: String]
        if let file = ProcessInfo.processInfo.environment["LYRA_READER_INTERLEAF_REPLAY_FILE"] {
            replay = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        } else { replay = [:] }
        let text = replay["answer"] ?? synthetic
        let characters = Array(text)
        var heights: [CGFloat] = []
        for offset in stride(from: 0, to: characters.count, by: 8) {
            service.handle.pending.append(.delta(String(characters[offset..<min(offset + 8, characters.count)])))
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded(); heights.append(card.heightViewPt)
        }
        service.handle.pending.append(.done)
        try await eventually("the controlled Interleaf stream completes", { card.assistant.phase == .finished })
        var settled: [CGFloat] = []
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); settled.append(card.heightViewPt)
        }
        let limit = AIRegionCard.maximumHeight(in: canvas.visibleRect.height)
        print("INTERLEAF-LAYOUT stream=\(heights.min()!)...\(heights.max()!) settled=\(settled.min()!)...\(settled.max()!) viewport=\(canvas.visibleRect) limit=\(limit)")
        require((settled.max()! - settled.min()!) < 1,
                "the clipped paper stops changing height after the stream ends")
        require(abs(settled.last! - limit) < 1,
                "long streamed content reaches the bounded paper height without collapsing")
        await card.distill(context: state.aiReaderContext!)
        require(card.notesBusy, "the note-generation stream starts without a provider")
        let syntheticNote = "## Synthetic evidence\n\n### Key ideas\n\n" + (1...6).map {
            "- The **configuration \($0)** uses a bounded amount of computation. The comparison records both execution time and the quality of the measured output, with a separate source for each claim. [p.2]\n\n"
        }.joined()
        let noteCharacters = Array(replay["note"] ?? syntheticNote)
        for offset in stride(from: 0, to: noteCharacters.count, by: 8) {
            service.handle.pending.append(.delta(String(noteCharacters[offset..<min(offset + 8, noteCharacters.count)])))
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
        }
        service.handle.pending.append(.done)
        try await eventually("the generated note is displayed", { !card.knowledgeNote.isEmpty })
        try await Task.sleep(for: .milliseconds(250))
        var noteHeights: [CGFloat] = []
        var transcriptHeights: [CGFloat] = []
        var transcriptViewports: [CGFloat] = []
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded(); noteHeights.append(card.heightViewPt)
            if let transcript = descendants(NSScrollView.self, in: paper).first {
                transcriptHeights.append(transcript.documentView?.frame.height ?? 0)
                transcriptViewports.append(transcript.contentView.bounds.height)
            }
        }
        print("INTERLEAF-NOTE paper=\(noteHeights.min()!)...\(noteHeights.max()!) transcript=\(transcriptHeights.min()!)...\(transcriptHeights.max()!) viewport=\(transcriptViewports.last!)")
        require(noteHeights.max()! - noteHeights.min()! < 1, "the clipped generated note settles without a layout loop")
        require(!transcriptHeights.isEmpty && transcriptHeights.max()! - transcriptHeights.min()! < 1,
                "the note transcript stops remeasuring when its text is unchanged")
        let documentHeight = transcriptHeights.last!
        let viewportHeight = transcriptViewports.last!
        require(documentHeight <= viewportHeight + 1 || abs(noteHeights.last! - limit) < 1,
                "the note grows to its height limit before clipping a taller transcript "
                    + "(paper \(noteHeights.last!), limit \(limit), document \(documentHeight), viewport \(viewportHeight))")
        print("INTERLEAF-GROWTH content top=\(probe.contentTops.min()!)...\(probe.contentTops.max()!) samples=\(probe.contentTops.count)")
        require(probe.contentTops.allSatisfy { abs($0) < 1 },
                "the content stays at the paper top through every native layout while growing")
        print("INTERLEAF-GAP maximum error=\(probe.gapErrors.max() ?? -1) samples=\(probe.gapErrors.count)")
        require(probe.gapErrors.count > 10 && probe.gapErrors.allSatisfy { $0 < 0.5 },
                "the native paper and committed split-page gap grow together")
    }
}
