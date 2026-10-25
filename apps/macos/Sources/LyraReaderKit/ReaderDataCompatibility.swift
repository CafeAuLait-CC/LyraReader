import Foundation

/// Upgrade only storage that is safe to copy.
///
/// `migratePreferences` copies preferences from the app's earlier bundle identifiers into the
/// current defaults. It runs once, and a value the current installation already wrote wins.
@MainActor public enum ReaderDataCompatibility {
    private static let migrationKey = "lyrareader.didMigratePreferences"

    public static func migratePreferences(
        defaults: UserDefaults = .standard,
        legacyDomains: [String] = ["com.alex.lyra", "com.alex.arisreader", "ArisReader"]
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        for domain in legacyDomains {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] {
                let destination = key.hasPrefix("lyra.")
                    ? "lyrareader." + key.dropFirst("lyra.".count) : key
                if defaults.object(forKey: destination) == nil {
                    defaults.set(value, forKey: destination)
                }
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}
