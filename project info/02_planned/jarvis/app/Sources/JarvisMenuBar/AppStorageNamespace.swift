import Foundation

/// Keeps the experimental build separate from the regular development app.
enum AppStorageNamespace {
    static func directoryName(bundleID: String?) -> String {
        bundleID == "local.jarvis.safari-experiment" ? "Jarvis-Safari-Experiment" : "Jarvis"
    }
    static func safariReadEnabled(bundleID: String?, flag: String?) -> Bool {
        bundleID == "local.jarvis.safari-experiment" && flag == "1"
    }
    static var current: String { directoryName(bundleID: Bundle.main.bundleIdentifier) }
}
