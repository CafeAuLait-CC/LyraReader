import Foundation
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func aiCredentialSessionChecks() async throws {
        let suite = "lyra-credential-session-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = CountingCredentialStore()
        let accounts = ChatGPTAccountStore(defaults: defaults, vault: InMemoryAPIKeyStore())
        let settings = AISettingsStore(defaults: defaults, keyStore: vault, chatGPT: accounts)
        require(vault.reads == 0, "initial settings status never reads secret bytes")
        let first = try settings.readKey()
        let second = try settings.readKey()
        require(first == "test-key" && second == first && vault.reads == 1,
                "summary parts and follow-up requests unlock the credential once")
        require(settings.save(baseURL: "http://localhost:11434/v1", model: "local", temperature: 0.2,
                              maxTokens: 900, apiKey: "replacement"), "a replacement credential saves")
        let replaced = try settings.readKey()
        require(replaced == "replacement" && vault.reads == 1,
                "a saved replacement immediately replaces the in-memory credential")
        settings.connectionMode = .chatGPT
        settings.connectionMode = .apiKey
        _ = try settings.readKey()
        require(vault.reads == 2, "a connection change starts a new credential session")
        require(settings.save(baseURL: "http://localhost:1234/v1", model: "other", temperature: 0.2,
                              maxTokens: 900, apiKey: nil), "changing providers keeps the stored key")
        _ = try settings.readKey()
        require(vault.reads == 3, "a provider change validates its own credential session")
        require(settings.clearKey(), "clearing the credential succeeds")
        let cleared = try settings.readKey()
        require(cleared == nil, "clearing a credential also removes its in-memory copy")
        let representation = String(describing: defaults.dictionaryRepresentation())
        require(!representation.contains("replacement") && !representation.contains("test-key"),
                "the unlocked session never writes secrets to defaults")

        let id = UUID()
        let account = ChatGPTAccountStore.Account(id: id, clientID: "test-client", subject: "test-subject",
            email: "test@example.invalid", label: "Test", connected: true, model: "test-model")
        defaults.set(try JSONEncoder().encode([account]), forKey: "chatGPTAccounts")
        defaults.set(id.uuidString, forKey: "chatGPTSelectedAccount")
        let credential = ChatGPTAccountStore.Credential(accessToken: "session-token", refreshToken: "refresh",
            idToken: "id", expiresAt: Date().addingTimeInterval(3600), scopes: [])
        let tokens = CountingCredentialStore()
        tokens.key = String(decoding: try JSONEncoder().encode([id.uuidString: credential]), as: UTF8.self)
        let chat = ChatGPTAccountStore(defaults: defaults, vault: tokens)
        let tokenA = try await chat.accessToken(for: id)
        let tokenB = try await chat.accessToken(for: id)
        require(tokenA == "session-token" && tokenB == tokenA && tokens.reads == 1,
                "ChatGPT request parts also reuse one keychain unlock")
    }
}

private final class CountingCredentialStore: AIAPIKeyStore {
    var key: String? = "test-key"
    var reads = 0
    func readKey() throws -> String? { reads += 1; return key }
    func saveKey(_ key: String) throws { self.key = key }
    func deleteKey() throws { key = nil }
    func hasKey() throws -> Bool { key != nil }
}
