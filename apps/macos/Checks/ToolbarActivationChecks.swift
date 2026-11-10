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
        state.toggleAITools()
        require(!state.aiToolsVisible && !state.rightPanelVisible && model.selectedTab == .translation,
                "closing Lyra closes its drawer and retains the chosen workspace")
        state.toggleAITools()
        require(!state.rightPanelVisible, "reopening Lyra starts with its drawer closed")
        for close: @MainActor () -> Void in [
            { state.aiToolsVisible = false },
            { state.toggleAnnotationTools() },
            { state.toggleContentEditing() },
            { state.toggleFillAndSign() },
            { state.toggleExport() },
        ] {
            state.aiToolsVisible = true
            state.rightPanelVisible = false
            state.toggleAssistantWorkspace(.chat, model: model)
            close()
            require(!state.aiToolsVisible && !state.rightPanelVisible && model.selectedTab == .chat,
                    "each secondary-row close path dismisses Lyra's drawer without resetting its workspace")
        }
    }
}
