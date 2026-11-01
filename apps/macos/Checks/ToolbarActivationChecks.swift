import AppKit
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func toolbarActivationChecks(root: URL) async throws {
        let state = AppState(engine: try RustEngine())
        require(state.open(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")),
                "the workspace toggle fixture opens")
        state.rightPanelVisible = false
        state.aiToolsVisible = true
        let defaults = UserDefaults(suiteName: "lyra-toolbar-activation-\(UUID())")!
        let model = AIAssistantModel(settings: AISettingsStore(defaults: defaults,
                                    keyStore: InMemoryAPIKeyStore(key: nil)))
        for tab in [AIAssistantTab.summary, .translation, .chat, .regions] {
            state.toggleAssistantWorkspace(tab, model: model)
            require(state.rightPanelVisible && model.selectedTab == tab,
                    "\(tab) opens its workspace")
            state.toggleAssistantWorkspace(tab, model: model)
            require(!state.rightPanelVisible && !state.regionSelectionArmed,
                    "\(tab) closes its workspace on the second activation")
        }
        state.toggleAssistantWorkspace(.summary, model: model)
        state.toggleAssistantWorkspace(.chat, model: model)
        require(state.rightPanelVisible && model.selectedTab == .chat,
                "a different Lyra tool switches the open workspace")
        state.rightPanelVisible = false
        state.toggleRegionSelection()
        require(state.regionSelectionArmed, "Interleaf arms region selection")
        state.toggleRegionSelection()
        require(!state.regionSelectionArmed, "Interleaf toggles back to the reading pointer")
        state.toggleRegionSelection()
        state.toggleAssistantWorkspace(.translation, model: model)
        require(!state.regionSelectionArmed && state.rightPanelVisible,
                "opening a workspace cancels Interleaf selection")
    }
}
