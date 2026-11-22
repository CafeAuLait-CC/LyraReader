import Foundation

private let aiReadingResources: Bundle = {
    // Packaged macOS resources must live inside Contents/Resources so the app can be signed.
    // SwiftPM's generated accessor only looks at the bundle root and its development path.
    if let url = Bundle.main.resourceURL?.appendingPathComponent("LyraReader_LyraReaderKit.bundle"),
       let resources = Bundle(url: url) { return resources }
    return .module
}()

/// Use the signed app's resource bundle, or SwiftPM's bundle in standalone native checks.
func aiReadingLabel(_ key: String) -> String {
    NSLocalizedString(key, bundle: aiReadingResources, comment: "Lyra AI reading interface")
}
