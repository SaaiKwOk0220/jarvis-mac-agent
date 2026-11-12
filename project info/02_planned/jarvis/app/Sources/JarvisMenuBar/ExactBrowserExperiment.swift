import Foundation
import CoreFoundation

enum ExactBrowserExperiment {
    static let bundleID = "local.jarvis.browser-experiment"
    static func enabled(experimentalBuild: Bool, bundleID: String?, marker: Bool, optIn: String?) -> Bool {
        experimentalBuild && bundleID == Self.bundleID && marker && optIn == "1"
    }
    static var toggleAllowed: Bool {
        #if JARVIS_EXACT_BROWSER_EXPERIMENT
        return Bundle.main.bundleIdentifier == bundleID && CFGetTypeID(Bundle.main.object(forInfoDictionaryKey: "JarvisBrowserExperiment") as CFTypeRef) == CFBooleanGetTypeID() && (Bundle.main.object(forInfoDictionaryKey: "JarvisBrowserExperiment") as? Bool == true)
        #elseif JARVIS_EXACT_BROWSER_EXPERIMENT
        return Bundle.main.bundleIdentifier == bundleID && AppStorageNamespace.isTrueBoolean(Bundle.main.object(forInfoDictionaryKey: "JarvisBrowserExperiment"))
        #else
        return false
        #endif
    }
    static var current: Bool {
        #if JARVIS_EXACT_BROWSER_EXPERIMENT
        return enabled(experimentalBuild: true, bundleID: Bundle.main.bundleIdentifier,
                       marker: Bundle.main.object(forInfoDictionaryKey: "JarvisBrowserExperiment") as? Bool == true,
                       optIn: ProcessInfo.processInfo.environment["JARVIS_EXACT_BROWSER_OPT_IN"])
        #else
        return false
        #endif
    }
    static var directoryName: String {
        Bundle.main.bundleIdentifier == bundleID && Bundle.main.object(forInfoDictionaryKey: "JarvisBrowserExperiment") as? Bool == true
            ? "Jarvis-Browser-Experiment" : "Jarvis"
    }
}
