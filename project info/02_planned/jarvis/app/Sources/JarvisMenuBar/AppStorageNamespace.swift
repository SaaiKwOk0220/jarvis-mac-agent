import Foundation

/// Keeps the experimental build separate from the regular development app.
enum AppStorageNamespace {
    static func directoryName(bundleID: String?) -> String {
        switch bundleID {
        case "local.jarvis.safari-experiment": return "Jarvis-Safari-Experiment"
        case "local.jarvis.safari-click-experiment": return "Jarvis-Safari-Click-Experiment"
        default: return "Jarvis"
        }
    }
    static func safariReadEnabled(bundleID: String?, flag: String?) -> Bool {
        bundleID == "local.jarvis.safari-experiment" && flag == "1"
    }
    static var current: String { directoryName(bundleID: Bundle.main.bundleIdentifier) }
}
