import AppKit
import Foundation
import LyraReaderBindings
import LyraReaderKit
import SwiftUI

// Settings > AI Test Connection checks. The success path uses the Rust mock provider (no socket);
// the failure paths use a scripted handle so the exact event the panel consumes is what the
// inline result shows. The 401/500 wording is pinned against the real client by the Rust
// `openai_client` tests; these checks prove the settings view displays it without replacing it.

@MainActor
private final class ConnectionTestHandleStub: AIChatHandle {
    private var events: [AIStreamEvent]
    private(set) var cancelled = false
    private var finished = false

    init(events: [AIStreamEvent]) {
        self.events = events
    }

    func poll() -> [AIStreamEvent] {
        if cancelled { return [] }
        let pending = events
        events = []
        if pending.contains(where: { event in
            switch event {
            case .done, .error: return true
            default: return false
            }
        }) {
            finished = true
        }
        return pending
    }

    func cancel() {
        cancelled = true
        finished = true
        events = []
    }

    var isFinished: Bool { finished }
}

@MainActor
private final class ScriptedConnectionTestService: AIConnectionTesting {
    private let base = RustAIConnectionTestService()
    private let events: [AIStreamEvent]
    private(set) var startCount = 0
    private(set) var requestedPlan: AiPlanRecord?
    private(set) var requestedKey: String?
    private(set) var lastHandle: ConnectionTestHandleStub?

    init(events: [AIStreamEvent]) {
        self.events = events
    }

    func prepare(_ settings: AIProviderSettings) throws -> AiPlanRecord {
        try base.prepare(settings)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        startCount += 1
        requestedPlan = plan
        requestedKey = apiKey
        let handle = ConnectionTestHandleStub(events: events)
        lastHandle = handle
        return handle
    }
}

@MainActor
private final class HangingConnectionTestService: AIConnectionTesting {
    private let base = RustAIConnectionTestService()
    private(set) var lastHandle: ConnectionTestHandleStub?

    func prepare(_ settings: AIProviderSettings) throws -> AiPlanRecord {
        try base.prepare(settings)
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        let handle = ConnectionTestHandleStub(events: [])
        lastHandle = handle
        return handle
    }
}

private struct ConnectionTestSettingsFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: AISettingsStore

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension ReaderChecks {
    @MainActor
    static func aiConnectionTestChecks(root: URL) async throws {
        try await connectionTestSuccessShowsModelAndDuration()
        try await connectionTest401And500ShowTheMappedError()
        try await connectionTestOfflineShowsTheOfflineSentence()
        try await connectionTestLoopbackRefusalShowsTheLocalServerSentence()
        try await connectionTestButtonIsDisabledWhileRunning()
        try await connectionTestIsCancelledWhenSettingsClose()
    }

    @MainActor
    private static func connectionSettings() throws -> ConnectionTestSettingsFixture {
        let suiteName = "lyra-reader-connection-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = AISettingsStore(
            defaults: defaults,
            keyStore: InMemoryAPIKeyStore(key: "sk-connection-check")
        )
        guard store.save(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "connection-check-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: "sk-connection-check"
        ) else {
            fatalError("FAIL: the connection-check settings did not save")
        }
        return ConnectionTestSettingsFixture(
            suiteName: suiteName,
            defaults: defaults,
            store: store
        )
    }

    /// The model name comes from the Rust plan (trimmed), and the duration is measured around the
    /// worker's Done event. The plan is also the proof that no document text travels: it has no
    /// pages, and the body contains only the fixed ping.
    @MainActor
    private static func connectionTestSuccessShowsModelAndDuration() async throws {
        let service = RustAIConnectionTestService(useMockProvider: true)
        let model = AIConnectionTestModel(service: service)
        let settings = AIProviderSettings(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "  resolved-connection-model  ",
            temperature: 0.9,
            maxTokens: 4096,
            reasoningMode: .high,
            reasoningEncoding: .reasoningEffort,
            vision: true
        )
        let key = "sk-connection-check-not-real"
        model.start(settings: settings, apiKey: key)

        try await eventually("the mock-provider connection test succeeds", { model.isSuccess })
        guard case .success(let resolved, let milliseconds) = model.status else {
            fatalError("FAIL: the success status is not a success")
        }
        require(resolved == "resolved-connection-model",
                "the inline result names the model the Rust builder resolved (\(resolved))")
        require(milliseconds >= 0,
                "the inline result reports a round-trip duration (\(milliseconds) ms)")
        require(model.statusText?.contains("resolved-connection-model") == true,
                "the result text shows the resolved model name")
        require(model.statusText?.contains("\(milliseconds) ms.") == true,
                "the result text shows the round-trip duration")

        let plan = try service.prepare(settings)
        require(plan.model == "resolved-connection-model",
                "the connection-test plan carries the trimmed model name")
        require(plan.parts.count == 1, "the connection test is one request")
        require(plan.parts[0].userPrompt == "ping",
                "the one user message is the fixed ping, not document text")
        require(plan.parts[0].pages.isEmpty && plan.parts[0].pageCharacters == 0,
                "the request has no page selection or page characters")
        require(plan.sourcePages.isEmpty, "the request has no source pages")
        require(plan.parts[0].systemPrompt == "Reply OK.",
                "the request uses the fixed short system message")
        let body = plan.parts[0].wireBody
        require(body.contains("\"content\":\"ping\""),
                "the wire body contains the fixed ping")
        require(!body.contains("multi-page fixture for navigation and caching"),
                "no document text is in the connection-test request")
        require(!body.contains("Body text on page 1."),
                "no page body text is in the connection-test request")
        require(!body.contains(key), "the key is not in the connection-test request body")
        require(plan.previewHeaders.allSatisfy { !$0.value.contains(key) },
                "the preview headers never contain the key")
        print("PASS: the connection test shows the resolved model and duration and sends only a ping")
    }

    /// The 401/500 strings are the exact `http_error` mapping. The check asserts the inline result
    /// keeps that text verbatim rather than replacing it with a generic "failed" message.
    @MainActor
    private static func connectionTest401And500ShowTheMappedError() async throws {
        let cases: [(status: Int, reason: String, mapped: String)] = [
            (
                401,
                "Unauthorized",
                "Authentication failed (HTTP 401 Unauthorized). Check the API key in Settings > AI. Nothing further was sent."
            ),
            (
                500,
                "Internal Server Error",
                "The provider failed (HTTP 500 Internal Server Error)."
            ),
        ]
        for item in cases {
            let service = ScriptedConnectionTestService(events: [
                .error(message: item.mapped, cancelled: false, failure: .other),
            ])
            let model = AIConnectionTestModel(service: service)
            let key = "sk-connection-check-not-real"
            model.start(
                settings: AIProviderSettings(
                    baseURL: "https://api.example.com/v1",
                    model: "connection-check-model",
                    temperature: nil,
                    maxTokens: nil
                ),
                apiKey: key
            )
            try await eventually("the HTTP \(item.status) mapped error reaches the inline result", {
                if case .failure = model.status { return true }
                return false
            })
            require(service.startCount == 1, "the HTTP \(item.status) test starts one request")
            require(model.statusText == item.mapped,
                    "HTTP \(item.status) shows the panel's mapped error text inline")
            require(model.statusText?.contains("HTTP \(item.status)") == true,
                    "HTTP \(item.status) keeps the status in the inline result")
            require(model.statusText?.contains(key) == false,
                    "HTTP \(item.status) does not echo the key")
            require(model.statusText?.contains(AIOfflineHint.noNetworkSentence) == false,
                    "HTTP \(item.status) is not misreported as a network failure")
        }
        print("PASS: 401 and 500 show the mapped client error inline")
    }

    @MainActor
    private static func connectionTestOfflineShowsTheOfflineSentence() async throws {
        let service = ScriptedConnectionTestService(events: [
            .error(
                message: "provider unreachable: no network route: No route to host",
                cancelled: false,
                failure: .offline
            ),
        ])
        let model = AIConnectionTestModel(service: service)
        model.start(
            settings: AIProviderSettings(
                baseURL: "https://api.example.com/v1",
                model: "connection-check-model",
                temperature: nil,
                maxTokens: nil
            ),
            apiKey: "sk-connection-check-not-real"
        )
        try await eventually("the offline connection failure reaches the inline result", {
            if case .failure = model.status { return true }
            return false
        })
        guard case .failure(let message, let hint) = model.status else {
            fatalError("FAIL: the offline result is not a failure")
        }
        require(message.contains("No route to host"),
                "the offline result keeps the panel's raw error text")
        require(hint?.kind == .noNetwork, "the offline failure produces the no-network hint")
        require(model.statusText?.contains(AIOfflineHint.noNetworkSentence) == true,
                "the inline result shows the offline sentence")
        require(model.statusText?.contains(AIOfflineHint.localServerSentence) == false,
                "the offline result is not misreported as a local-server failure")
        print("PASS: a network-unreachable connection test shows the offline sentence")
    }

    @MainActor
    private static func connectionTestLoopbackRefusalShowsTheLocalServerSentence() async throws {
        let service = ScriptedConnectionTestService(events: [
            .error(
                message: "provider unreachable: the local server did not accept the connection: Connection refused",
                cancelled: false,
                failure: .localServer
            ),
        ])
        let model = AIConnectionTestModel(service: service)
        model.start(
            settings: AIProviderSettings(
                baseURL: "http://127.0.0.1:11434/v1",
                model: "connection-check-model",
                temperature: nil,
                maxTokens: nil
            ),
            apiKey: "sk-connection-check-not-real"
        )
        try await eventually("the local-server refusal reaches the inline result", {
            if case .failure = model.status { return true }
            return false
        })
        guard case .failure(_, let hint) = model.status else {
            fatalError("FAIL: the local-server result is not a failure")
        }
        require(hint?.kind == .localServer,
                "a refused loopback connection is the local-server category")
        require(model.statusText?.contains(AIOfflineHint.localServerSentence) == true,
                "the inline result shows the local-server sentence")
        require(model.statusText?.contains(AIOfflineHint.noNetworkSentence) == false,
                "a loopback refusal never claims this Mac has no network")
        print("PASS: a refused loopback connection test shows the local-server sentence")
    }

    /// Host the real settings form, start a test that never finishes, and read the AppKit button:
    /// while the worker is running it must be disabled, then enabled again after Cancel.
    @MainActor
    private static func connectionTestButtonIsDisabledWhileRunning() async throws {
        let fixture = try connectionSettings()
        defer { fixture.cleanup() }
        let service = HangingConnectionTestService()
        let tester = AIConnectionTestModel(service: service)
        let window = try hostSettings(store: fixture.store, tester: tester)
        defer { closeSettings(window) }
        let startButton = try await waitForButton(titled: "Test Connection", in: window)
        require(startButton.isEnabled, "the Test Connection button starts enabled")
        tester.start(settings: try fixture.store.providerSettings(), apiKey: "sk-connection-check")
        try await Task.sleep(for: .milliseconds(180))
        require(tester.isRunning, "the hanging test is still running")
        let runningButton = try await waitForButton(titled: "Test Connection", in: window)
        require(!runningButton.isEnabled,
                "the Test Connection button is disabled while the test is running")
        tester.cancel()
        try await Task.sleep(for: .milliseconds(120))
        require(!tester.isRunning, "Cancel ends the connection test")
        let cancelledButton = try await waitForButton(titled: "Test Connection", in: window)
        require(cancelledButton.isEnabled, "the Test Connection button is enabled again after Cancel")
        require(service.lastHandle?.cancelled == true, "Cancel cancels the worker's handle")
        print("PASS: the Test Connection button is disabled while running and Cancel re-enables it")
    }

    /// Closing the hosted Settings view must cancel the running test. This is the same
    /// `onDisappear` rule the Settings window uses; the handle checks that the Rust worker was
    /// actually told to stop, not merely hidden.
    @MainActor
    private static func connectionTestIsCancelledWhenSettingsClose() async throws {
        let fixture = try connectionSettings()
        defer { fixture.cleanup() }
        let service = HangingConnectionTestService()
        let tester = AIConnectionTestModel(service: service)
        var window: NSWindow? = try hostSettings(store: fixture.store, tester: tester)
        guard window != nil else {
            fatalError("FAIL: could not host the settings form")
        }
        tester.start(settings: try fixture.store.providerSettings(), apiKey: "sk-connection-check")
        try await Task.sleep(for: .milliseconds(120))
        guard let handle = service.lastHandle else {
            fatalError("FAIL: the hanging service did not start a handle")
        }
        require(tester.isRunning, "the test runs before Settings closes")
        require(handle.cancelled == false, "the handle is not cancelled before Settings closes")

        closeSettings(window)
        window = nil
        try await eventually("closing Settings cancels the connection test", {
            !tester.isRunning && handle.cancelled
        })
        require(handle.cancelled, "closing Settings cancels the worker's handle")
        require(tester.statusText == nil, "closing Settings leaves no inline result behind")
        print("PASS: closing Settings cancels the running connection test and clears the result")
    }

    @MainActor
    private static func hostSettings(
        store: AISettingsStore,
        tester: AIConnectionTestModel
    ) throws -> NSWindow {
        let host = NSHostingView(rootView: AISettingsView(store: store, connectionTest: tester))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private static func closeSettings(_ window: NSWindow?) {
        guard let window else { return }
        window.orderOut(nil)
        window.contentView = nil
    }

    @MainActor
    private static func waitForButton(titled title: String, in window: NSWindow) async throws -> NSButton {
        for _ in 0..<120 {
            if let view = window.contentView,
               let button = findButton(titled: title, in: view) {
                return button
            }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        fatalError("FAIL: the AI settings form has no \"\(title)\" button")
    }

    @MainActor
    private static func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           button.title == title || (button.accessibilityLabel() ?? "") == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(titled: title, in: subview) { return found }
        }
        return nil
    }
}
