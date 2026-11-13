import Foundation

enum CombinedExperimentAccess {
    static let bundleID = "local.jarvis.combined-experiment"
    static func allowed(build: Bool, bundleID: String?, marker: Bool) -> Bool {
        build && bundleID == Self.bundleID && marker
    }
    static func enabled(identity: Bool, optIn: String?) -> Bool { identity && optIn == "1" }
    static var current: Bool {
        #if JARVIS_COMBINED_EXPERIMENT
        return allowed(build: true, bundleID: Bundle.main.bundleIdentifier,
                       marker: Bundle.main.object(forInfoDictionaryKey: "JarvisCombinedExperiment") as? Bool == true)
        #else
        return false
        #endif
    }
}
