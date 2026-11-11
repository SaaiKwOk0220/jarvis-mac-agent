import Foundation

/// Keeps explicitly labelled experimental builds away from production data.
enum AppStorageScope {
    static func directory(experimental: Bool) -> String { experimental ? "Jarvis-VAD-Experiment" : "Jarvis" }
    static var currentDirectory: String {
        directory(experimental: Bundle.main.object(forInfoDictionaryKey: "JarvisExperimentalIsolation") as? Bool == true)
    }
}
