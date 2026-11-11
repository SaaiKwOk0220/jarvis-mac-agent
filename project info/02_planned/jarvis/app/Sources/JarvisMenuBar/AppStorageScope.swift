import Foundation

/// Keeps explicitly labelled experimental builds away from production data.
enum AppStorageScope {
    static func directory(experimental: Bool) -> String { experimental ? "Jarvis-VAD-Experiment" : "Jarvis" }
    static func directory(bundleID: String?, vadIsolation: Bool) -> String {
        if bundleID == "local.jarvis.browser-experiment" { return "Jarvis-Browser-Experiment" }
        if bundleID == "local.jarvis.safari-experiment" { return "Jarvis-Safari-Experiment" }
        return directory(experimental: vadIsolation)
    }
    static var currentDirectory: String {
        directory(bundleID: Bundle.main.bundleIdentifier, vadIsolation: Bundle.main.object(forInfoDictionaryKey: "JarvisExperimentalIsolation") as? Bool == true)
    }
}
