import AppKit
import Combine
import Foundation
import LyraReaderBindings
import SwiftUI

/// The transport the Settings > AI connection test uses. It is deliberately narrower than
/// `AIChatServicing`: the test has no document, history or preview to keep, and an injected
/// implementation lets the checks script one response without opening a socket.
@MainActor
public protocol AIConnectionTesting: AnyObject {
    /// Build the one-ping plan. Local work only; no key and no network.
    func prepare(_ settings: AIProviderSettings) throws -> AiPlanRecord
    /// Start the plan through the real Rust worker (or a scripted handle in a check).
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle
}

/// Production connection test: the same Rust prompt builder, worker, transport, SSE parser and
/// error mapping as the panel. The key crosses the FFI only when `start` runs.
@MainActor
public final class RustAIConnectionTestService: AIConnectionTesting {
    /// The deterministic network-free provider used by the checks. The app leaves this false.
    public let useMockProvider: Bool

    public init(useMockProvider: Bool = false) {
        self.useMockProvider = useMockProvider
    }

    public func prepare(_ settings: AIProviderSettings) throws -> AiPlanRecord {
        try buildAiConnectionTestPlan(baseUrl: settings.baseURL, model: settings.model)
    }

    public func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        let handle = try startAiRequest(
            plan: plan,
            apiKey: apiKey,
            useMockProvider: useMockProvider
        )
        return RustAIChatHandle(handle: handle)
    }
}

/// One Test Connection run: build the smallest request, start it, poll the same stream events the
/// panel reads, and keep only what the inline result needs.
///
/// Nothing here is persisted. The plan, the key and the handle are local; the handle is released
/// as soon as the run ends, and `cancel()` stops and releases it immediately. The last result is
/// view state only and is replaced by the next run.
@MainActor
public final class AIConnectionTestModel: ObservableObject {
    public enum Status: Equatable {
        case idle
        case running
        case success(model: String, milliseconds: Int)
        case failure(message: String, hint: AIOfflineHint?)
    }

    @Published public private(set) var status: Status = .idle
    /// The model name the Rust builder resolved from the settings, including its trim rules.
    @Published public private(set) var resolvedModel: String?

    private let service: any AIConnectionTesting
    private let clock = ContinuousClock()
    private var handle: (any AIChatHandle)?
    private var pollTask: Task<Void, Never>?
    private var startedAt: ContinuousClock.Instant?

    public init(service: any AIConnectionTesting = RustAIConnectionTestService()) {
        self.service = service
    }

    public var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// The one line (or two, for a classified transport failure) shown under the button.
    public var statusText: String? {
        switch status {
        case .idle:
            return nil
        case .running:
            return resolvedModel.map { "Testing \($0)…" } ?? "Testing the connection…"
        case .success(let model, let milliseconds):
            return "Connected to \(model) in \(milliseconds) ms."
        case .failure(let message, let hint):
            guard let hint else { return message }
            return message + "\n" + hint.sentence
        }
    }

    public var isSuccess: Bool {
        if case .success = status { return true }
        return false
    }

    /// Run one test with the settings currently in the form. A key typed in the field is used
    /// before it is saved; otherwise the stored key is read at this moment and not retained.
    public func start(settings: AIProviderSettings, apiKey: String) {
        cancel()
        resolvedModel = nil

        let plan: AiPlanRecord
        do {
            plan = try AIPlanWire.render(service.prepare(settings), connection: .apiKey)
        } catch {
            status = .failure(message: AIReadableError.message(error), hint: nil)
            return
        }

        resolvedModel = plan.model
        do {
            handle = try service.start(plan, apiKey: apiKey)
        } catch {
            handle = nil
            status = .failure(message: AIReadableError.message(error), hint: nil)
            return
        }

        startedAt = clock.now
        status = .running
        poll()
    }

    /// Stop the worker and release its handle. Used by the Cancel control and when Settings goes
    /// away; the next test starts from a clean slate.
    public func cancel() {
        pollTask?.cancel()
        pollTask = nil
        handle?.cancel()
        handle = nil
        startedAt = nil
        status = .idle
        resolvedModel = nil
    }

    /// Surface an error that happened before a plan could start (for example a Keychain read).
    public func reportFailure(_ message: String) {
        cancel()
        status = .failure(message: message, hint: nil)
    }

    private func poll() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let handle = self.handle else { return }
                let events = handle.poll()
                if !events.isEmpty, self.apply(events) { return }
                if handle.isFinished {
                    self.finishWithoutResult()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(30))
                } catch {
                    return
                }
            }
        }
    }

    /// Returns true when a terminal event was handled and polling must stop.
    private func apply(_ events: [AIStreamEvent]) -> Bool {
        for event in events {
            switch event {
            case .done:
                finishSuccessfully()
                return true
            case .error(let message, let cancelled, let failure):
                handle = nil
                startedAt = nil
                if cancelled {
                    if isRunning { status = .idle }
                } else {
                    status = .failure(
                        message: message,
                        hint: AIOfflineHint.forFailure(failure)
                    )
                }
                return true
            case .partStarted, .delta, .reasoningDelta, .usage, .diagnostics:
                continue
            }
        }
        return false
    }

    private func finishSuccessfully() {
        guard let startedAt else {
            handle = nil
            return
        }
        let elapsed = clock.now - startedAt
        let model = resolvedModel ?? ""
        self.startedAt = nil
        handle = nil
        status = .success(model: model, milliseconds: Self.milliseconds(elapsed))
    }

    private func finishWithoutResult() {
        handle = nil
        startedAt = nil
        if isRunning {
            status = .failure(
                message: "The AI request ended without a result.",
                hint: nil
            )
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}


/// The Test Connection control. It is a real `NSButton` rather than a SwiftUI `Button` so the
/// disabled state the reader sees is the state the accessibility tree and the native regression
/// checks read (`isEnabled`), not a redrawn SwiftUI label. It uses the standard rounded push-button
/// look and sits in the same Form row as a SwiftUI button would.
@MainActor
public struct AIConnectionTestButton: NSViewRepresentable {
    public let isRunning: Bool
    public let action: () -> Void

    public init(isRunning: Bool, action: @escaping () -> Void) {
        self.isRunning = isRunning
        self.action = action
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    public func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "Test Connection",
            target: context.coordinator,
            action: #selector(Coordinator.performTestConnection)
        )
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Sends one fixed ping to this endpoint and model. No document text is sent."
        button.setAccessibilityLabel("Test Connection")
        button.isEnabled = !isRunning
        return button
    }

    public func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = "Test Connection"
        button.isEnabled = !isRunning
    }

    @MainActor
    public final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performTestConnection() {
            action()
        }
    }
}
