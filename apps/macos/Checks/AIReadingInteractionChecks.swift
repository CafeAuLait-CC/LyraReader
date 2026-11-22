import AppKit
import Foundation
import LyraReaderBindings
import SwiftUI
@testable import LyraReaderKit

@MainActor private final class InteractionChatService: AIChatServicing {
    let base: RustAIChatService
    var starts = 0
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord { try await base.prepare(request) }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        starts += 1; return InteractionChatHandle()
    }
}
@MainActor private final class InteractionChatHandle: AIChatHandle {
    var isFinished = false
    func poll() -> [AIStreamEvent] {
        guard !isFinished else { return [] }; isFinished = true
        return [.partStarted(index: 0, total: 1, label: "Synthetic document"),
                .delta("A synthetic supported answer [p.1]."), .done]
    }
    func cancel() { isFinished = true }
}

extension ReaderChecks {
    @MainActor static func aiReadingInteractionChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-reading-input-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("synthetic.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let domain = "lyra-reading-input-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: "mock"))
        settings.prereadingPolicy = "never"
        _ = settings.save(baseURL: "http://localhost:11434/v1", model: "mock", temperature: 0.2, maxTokens: 512, apiKey: nil)
        let engine = try RustEngine(); let state = AppState(engine: engine)
        require(state.open(url: source), "the input interaction fixture opens")
        let reading = AIReadingModel(settings: settings, audit: AIAuditTrail.shared)
        let service = InteractionChatService(engine: engine); reading.serviceOverride = service
        await reading.bind(state)
        let result = AiReadingRecord.make(kind: "summary", title: "Synthetic note", content: "A supported idea [p.1].", sourceID: "document", pages: [1])
        reading.store.put(result)
        let note = reading.store.keep(result)!
        let navigation = AIAssistantModel(settings: settings); navigation.selectedTab = .regions
        reading.selectedNoteID = note.id
        let host = NSHostingView(rootView: AIReadingSidebar(state: state, navigation: navigation, reading: reading, isActive: false))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        defer { reading.cancelPresentation(); window.orderOut(nil); window.contentView = nil }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
        }
        try await eventually("personal thoughts expose a real editable native field", {
            host.layoutSubtreeIfNeeded()
            return !find(AIReadingTextView.self, in: host).isEmpty
        })
        let thoughts = find(AIReadingTextView.self, in: host)[0]
        require(thoughts.bounds.height >= thoughts.enclosingScrollView!.contentView.bounds.height,
                "the entire personal-thoughts box accepts text input")
        require(window.makeFirstResponder(thoughts), "personal thoughts accept keyboard focus directly")
        try captureReadingInteraction(host, name: "thoughts-input")
        let entered = "My independent thought Ω\nA second line"
        thoughts.insertText(entered, replacementRange: NSRange(location: 0, length: thoughts.string.utf16.count))
        try await eventually("typing personal thoughts updates the saved note", {
            reading.store.records.first(where: { $0.id == note.id })?.thoughts == entered
        })
        require(reading.store.records.first(where: { $0.id == note.id })?.content == result.content,
                "personal thoughts preserve the generated note body")
        await reading.store.flush()
        let restored = AIReadingStore()
        await restored.load(document: source, identity: state.aiReaderContext!.documentKey)
        require(restored.records.first(where: { $0.id == note.id })?.thoughts == entered,
                "personal thoughts survive a new store without a separate edit mode")

        func assertTrackPalette(_ scroller: NSScroller, label: String, empty: Bool) {
            guard scroller.scrollerStyle == .legacy, !scroller.isHidden, scroller.bounds.width > 1 else { return }
            scroller.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let bitmap = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) else {
                    fail("FAIL: reading scrollbar bitmap is unavailable")
                }
                scroller.cacheDisplay(in: scroller.bounds, to: bitmap)
                let backgroundArea = CGRect(x: 0, y: host.bounds.midY, width: 4, height: 4)
                guard let background = host.bitmapImageRepForCachingDisplay(in: backgroundArea) else {
                    fail("FAIL: reading panel background bitmap is unavailable")
                }
                host.cacheDisplay(in: backgroundArea, to: background)
                guard let expected = background.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else {
                    fail("FAIL: reading panel background pixels are unavailable")
                }
                let points = [(1, 1)] + (empty ? [(bitmap.pixelsWide / 2, bitmap.pixelsHigh / 2)] : [])
                for (x, y) in points {
                    guard let actual = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                        fail("FAIL: reading scrollbar pixels are unavailable")
                    }
                    let matches = abs(actual.redComponent - expected.redComponent) < 0.02
                        && abs(actual.greenComponent - expected.greenComponent) < 0.02
                        && abs(actual.blueComponent - expected.blueComponent) < 0.02
                    if !matches {
                        fail("FAIL: \(label) track actual=\(actual), expected=\(expected), "
                            + "appearance=\(scroller.effectiveAppearance.name), "
                            + "enabled=\(scroller.isEnabled), proportion=\(scroller.knobProportion)")
                    }
                    require(matches, "\(label) keeps its reserved track in the panel palette at \(x),\(y)")
                }
            }
        }
        reading.selectedNoteID = nil
        for populated in [false, true] {
            if populated {
                reading.store.putAll((0..<24).map { index in
                    .make(kind: "note", title: "Synthetic note \(index)",
                          content: "A local paragraph for checking real note-list scrolling.",
                          sourceID: "scroll:\(index)", pages: [1])
                })
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for style in [NSScroller.Style.legacy, .overlay] {
                    for width: CGFloat in [480, 320, 520, 414] {
                        window.setContentSize(CGSize(width: width, height: 800))
                        try await eventually("the resized notes list exposes one native scroll view", {
                            host.layoutSubtreeIfNeeded()
                            return find(NSScrollView.self, in: host).count == 1
                        })
                        let scroll = find(NSScrollView.self, in: host)[0]
                        scroll.scrollerStyle = style; scroll.tile()
                        let label = "notes \(populated ? "long" : "short") \(appearance.rawValue) \(style.rawValue) \(width) pt"
                        try await eventuallyExplaining("\(label) keeps its scroll viewport flush with the panel edge", {
                            "scroll=\(host.convert(scroll.bounds, from: scroll)), host=\(host.bounds)"
                        }, {
                            host.layoutSubtreeIfNeeded()
                            return abs(host.convert(scroll.bounds, from: scroll).maxX - host.bounds.maxX) < 0.5
                        })
                        try await eventually("\(label) keeps the Lyra native scroller after resizing", {
                            scroll.verticalScroller is LyraReaderSidebarScroller
                        })
                        try await eventuallyExplaining("\(label) keeps any visible scrollbar at the panel edge", {
                            "scroller=\(String(describing: scroll.verticalScroller?.frame)), "
                                + "hidden=\(String(describing: scroll.verticalScroller?.isHidden)), "
                                + "document=\(String(describing: scroll.documentView?.frame)), clip=\(scroll.contentView.bounds)"
                        }, {
                            host.layoutSubtreeIfNeeded()
                            guard let scroller = scroll.verticalScroller else { return false }
                            if !populated && (scroller.isHidden || scroller.bounds.width < 1) { return true }
                            let track = host.convert(scroller.bounds, from: scroller)
                            return track.width > 1 && abs(track.maxX - host.bounds.maxX) <= 2
                        })
                        guard let scroller = scroll.verticalScroller else { fail("FAIL: missing notes scroller") }
                        assertTrackPalette(scroller, label: label, empty: !populated)
                        if populated {
                            try await eventually("\(label) retains a working thumb for overflowing notes", {
                                (scroll.verticalScroller?.knobProportion ?? 1) < 1 && scroll.verticalScroller?.isEnabled == true
                            })
                        } else {
                            require((scroll.documentView?.frame.height ?? .infinity) <= scroll.contentView.bounds.height + 1,
                                    "\(label) fits without a scrollable range")
                        }
                    }
                }
            }
            try captureReadingInteraction(host, name: "notes-\(populated ? "long" : "short")-resized-scrollbar")
        }
        reading.summarySelection = true; reading.translationSelection = true
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for style in [NSScroller.Style.legacy, .overlay] {
                for tab in [AIAssistantTab.summary, .translation] {
                    navigation.selectedTab = .regions
                    try await eventually("the long notes list scrolls before changing tools", {
                        host.layoutSubtreeIfNeeded()
                        return find(NSScrollView.self, in: host).contains {
                            ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1
                                && $0.verticalScroller?.isEnabled == true
                        }
                    })
                    navigation.selectedTab = tab
                    try await eventually("the shorter tool installs its own scroll view", {
                        host.layoutSubtreeIfNeeded()
                        return find(NSScrollView.self, in: host).count == 1
                            && find(AITranslationControlMarker.self, in: host).contains { $0.id == "segment-Whole document" }
                    })
                    let scroll = find(NSScrollView.self, in: host)[0]
                    scroll.scrollerStyle = style; scroll.tile()
                    try await eventuallyExplaining("\(tab) settles without inheriting the long notes scrollbar", {
                        "attached=\(scroll.window != nil), scroller=\(String(describing: scroll.verticalScroller)), "
                            + "document=\(String(describing: scroll.documentView?.frame)), clip=\(scroll.contentView.bounds)"
                    }, {
                        host.layoutSubtreeIfNeeded()
                        return scroll.verticalScroller is LyraReaderSidebarScroller
                            && (scroll.documentView?.frame.height ?? .infinity) <= scroll.contentView.bounds.height + 1
                    })
                    guard let scroller = scroll.verticalScroller else { fail("FAIL: missing tool scroller") }
                    assertTrackPalette(scroller, label: "\(tab) after long notes \(appearance.rawValue)", empty: true)
                }
            }
        }
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(CGSize(width: 480, height: 800))

        reading.newSession(pageCount: 1); navigation.selectedTab = .chat
        try await eventually("the chat input mounts", {
            host.layoutSubtreeIfNeeded()
            return find(AIReadingTextView.self, in: host).contains { $0.placeholder == aiReadingLabel("Ask about this document…") }
        })
        let input = find(AIReadingTextView.self, in: host).first { $0.placeholder == aiReadingLabel("Ask about this document…") }!
        try captureReadingInteraction(host, name: "chat-input")
        func inkTop() -> CGFloat {
            let bitmap = input.bitmapImageRepForCachingDisplay(in: input.bounds)!
            input.cacheDisplay(in: input.bounds, to: bitmap)
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.alphaComponent > 0.3 && color.greenComponent < 0.75 && color.redComponent < 0.85 {
                        return CGFloat(y) * input.bounds.height / CGFloat(bitmap.pixelsHigh)
                    }
                }
            }
            fail("FAIL: the input fixture contains no rendered glyphs")
        }
        let placeholderTop = inkTop()
        input.insertText(input.placeholder, replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        require(abs(inkTop() - placeholderTop) <= 1, "placeholder and entered text share the same rendered line origin")
        input.insertText("", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        require(window.makeFirstResponder(input), "the chat composer accepts native keyboard input")
        func enter(_ modifiers: NSEvent.ModifierFlags = []) {
            input.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        }
        input.insertText("这篇文章的研究目的是什么？", replacementRange: input.selectedRange())
        enter(.shift)
        require(input.string.contains("\n") && service.starts == 0, "Shift+Return inserts a line without sending")
        input.insertText("Please explain briefly.", replacementRange: input.selectedRange())
        enter()
        try await eventually("Return sends the multilingual question to the mock provider", {
            reading.chat.phase == .finished && service.starts == 1
        })
        require(reading.chat.chatTurns.last?.question.contains("\n") == true,
                "the sent question retains the Shift+Return line break")
        input.setMarkedText("未完成", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        require(input.hasMarkedText(), "the composer has an active input-method composition")
        enter()
        try await Task.sleep(for: .milliseconds(150))
        require(service.starts == 1, "Return used to commit marked text cannot send another request")
        input.unmarkText()

        let summary = NSHostingView(rootView: AIReadingSummaryContent(
            text: "# Overview\n\nVisible overview.\n\n## Key ideas\n\nVisible ideas.\n\n## Further details\n\nHidden synthetic detail.",
            pageCount: 1, pages: [1], onJump: { _ in }))
        window.contentView = summary
        try await eventually("the summary heading lays out", {
            summary.layoutSubtreeIfNeeded()
            return find(AIReadingHeadingMarker.self, in: summary).contains { $0.index == 2 }
        })
        func detailVisible() -> Bool { find(NSTextView.self, in: summary).contains { $0.string.contains("Hidden synthetic detail") } }
        require(!detailVisible(), "the later summary section begins collapsed")
        func clickHeading() {
            summary.layoutSubtreeIfNeeded()
            let marker = find(AIReadingHeadingMarker.self, in: summary).first { $0.index == 2 }!
            let rect = marker.convert(marker.bounds, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: rect.maxX - 12, y: rect.midY),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
        }
        clickHeading()
        try await eventually("clicking the far side of a summary heading expands its section", { detailVisible() })
        try captureReadingInteraction(summary, name: "summary-expanded")
        clickHeading()
        try await eventually("clicking the whole heading again collapses its section", { !detailVisible() })
    }

    @MainActor static func captureReadingInteraction(_ view: NSView, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["LYRA_AI_EVIDENCE"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("FAIL: no interaction bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("FAIL: no interaction PNG") }
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("interaction-\(name).png"))
    }
}
