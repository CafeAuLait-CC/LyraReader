import AppKit
import LyraReaderBindings
import SwiftUI

/// Request review is an independent, nonmodal native window. Closing it cancels the send.
@MainActor
final class AIReadingReviewWindow: NSObject, NSWindowDelegate {
    private static var active: [UUID: AIReadingReviewWindow] = [:]
    private let id: UUID
    private let window: NSWindow
    private var completion: ((Bool) -> Void)?
    private var closing = false

    static func review(_ plan: AiPlanRecord) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let controller = AIReadingReviewWindow(id: id, plan: plan) { continuation.resume(returning: $0) }
                active[id] = controller
                controller.window.makeKeyAndOrderFront(nil)
            }
        } onCancel: {
            Task { @MainActor in active[id]?.finish(false) }
        }
    }
    private init(id: UUID, plan: AiPlanRecord, completion: @escaping (Bool) -> Void) {
        self.id = id
        self.completion = completion
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = aiReadingLabel("Review AI task")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: AIReadingReviewContent(plan: plan) { [weak self] in self?.finish($0) })
        window.center()
    }
    private func finish(_ approved: Bool) {
        guard !closing else { return }; closing = true
        let callback = completion; completion = nil
        callback?(approved)
        window.close()
        Self.active.removeValue(forKey: id)
    }
    func windowWillClose(_ notification: Notification) { finish(false) }
}

private struct AIReadingReviewContent: View {
    let plan: AiPlanRecord
    let finish: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(aiReadingLabel("Review AI task")).font(.title3.weight(.semibold))
            Text("\(plan.host) · \(plan.model)").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            Text("\(plan.sourcePageLabel) · \(plan.parts.count) requests in this task").font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(plan.parts.enumerated()), id: \.offset) { index, part in
                        DisclosureGroup("Request \(index + 1)") {
                            Text(part.wireBody).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Text(aiReadingLabel("A long summary may need a final synthesis of these results. It uses the same provider and source scope."))
                .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            HStack {
                Button(aiReadingLabel("Cancel")) { finish(false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(aiReadingLabel("Send task")) { finish(true) }.keyboardShortcut(.defaultAction)
                    .buttonStyle(ReaderPanelButtonStyle(prominent: true))
            }
        }.padding(20).background(LyraReaderTheme.panelBg)
    }
}

@MainActor
private final class AIPreReadingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class AIPreReadingWindow: NSObject, NSWindowDelegate {
    private static var active: [ObjectIdentifier: AIPreReadingWindow] = [:]
    private let knowledge: AIDocumentKnowledge
    private let window: NSWindow
    static func present(_ knowledge: AIDocumentKnowledge) {
        let key = ObjectIdentifier(knowledge)
        if let old = active[key] { old.window.makeKeyAndOrderFront(nil); return }
        let controller = AIPreReadingWindow(knowledge)
        active[key] = controller
        controller.window.makeKeyAndOrderFront(nil)
    }
    static func dismiss(_ knowledge: AIDocumentKnowledge) {
        active.removeValue(forKey: ObjectIdentifier(knowledge))?.window.close()
    }
    private init(_ knowledge: AIDocumentKnowledge) {
        self.knowledge = knowledge
        window = AIPreReadingPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.title = aiReadingLabel("Document prereading")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        let content = NSHostingView(rootView: AIDocumentKnowledgeSheet(knowledge: knowledge).clipShape(RoundedRectangle(cornerRadius: 12)))
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
    }
    func windowWillClose(_ notification: Notification) {
        if knowledge.phase == .consent { knowledge.continueWithoutSummary() }
        Self.active.removeValue(forKey: ObjectIdentifier(knowledge))
    }
}

struct AIPreReadingWindowBridge: ViewModifier {
    @ObservedObject var knowledge: AIDocumentKnowledge
    func body(content: Content) -> some View {
        content.onChange(of: knowledge.isPresented) { _, presented in
            if presented { AIPreReadingWindow.present(knowledge) }
            else { AIPreReadingWindow.dismiss(knowledge) }
        }
    }
}
