import Foundation
import LyraReaderKit

extension ReaderChecks {
    @MainActor static func renameCompatibilityChecks() {
        let domain = "lyrareader.rename-check.\(UUID())"
        let oldDomain = domain + ".legacy"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: oldDomain)
        }
        let accounts = Data("old-account-metadata".utf8)
        defaults.setPersistentDomain([
            "lyra.paperAppearance": "warm", "lyra.recentDocuments": Data("[]".utf8),
            "readerLayoutMode": "facing", "chatGPTAccounts": accounts,
            "readingPosition:/paper.pdf": 125.0
        ], forName: oldDomain)
        defaults.set("night", forKey: "lyrareader.paperAppearance")
        ReaderDataCompatibility.migratePreferences(defaults: defaults, legacyDomains: [oldDomain])
        require(defaults.string(forKey: "lyrareader.paperAppearance") == "night",
                "rename preserves the new installation's preference over the old value")
        require(defaults.string(forKey: "readerLayoutMode") == "facing"
                && defaults.data(forKey: "chatGPTAccounts") == accounts
                && defaults.double(forKey: "readingPosition:/paper.pdf") == 125,
                "rename imports layout, account metadata and document reading positions")
        require(defaults.data(forKey: "lyrareader.recentDocuments") == Data("[]".utf8),
                "rename imports recent documents under the new preference key")
        defaults.removeObject(forKey: "lyrareader.recentDocuments")
        ReaderDataCompatibility.migratePreferences(defaults: defaults, legacyDomains: [oldDomain])
        require(defaults.data(forKey: "lyrareader.recentDocuments") == nil,
                "rename does not resurrect history cleared after the first migration")
        print("Rename compatibility checks passed")
    }
}
