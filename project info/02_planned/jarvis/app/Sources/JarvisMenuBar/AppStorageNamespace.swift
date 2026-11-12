import Foundation
import CoreFoundation

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
    static func safariReadEnabledInCurrentBuild(bundleID: String?, flag: String?) -> Bool {
        #if JARVIS_COMBINED_EXPERIMENT
        return CombinedExperimentAccess.enabled(identity: CombinedExperimentAccess.current, optIn: flag) && bundleID == CombinedExperimentAccess.bundleID
        #elseif JARVIS_SAFARI_EXPERIMENT_BUILD
        return safariReadEnabled(bundleID: bundleID, flag: flag)
        #else
        return false
        #endif
    }
    static func isTrueBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }
    static func allowsReadToggle(safariBuild: Bool, clickBuild: Bool, bundleID: String?, safariMarker: Bool, clickMarker: Bool) -> Bool {
        guard safariBuild, safariMarker else { return false }
        if clickBuild { return bundleID == "local.jarvis.safari-click-experiment" && clickMarker }
        return bundleID == "local.jarvis.safari-experiment"
    }
    static var allowsReadToggleInCurrentBuild: Bool {
        #if JARVIS_SAFARI_EXPERIMENT_BUILD
        let safariBuild = true
        #else
        let safariBuild = false
        #endif
        #if JARVIS_SAFARI_CLICK_EXPERIMENT
        let clickBuild = true
        #else
        let clickBuild = false
        #endif
        return allowsReadToggle(safariBuild: safariBuild, clickBuild: clickBuild,
                                bundleID: Bundle.main.bundleIdentifier,
                                safariMarker: isTrueBoolean(Bundle.main.object(forInfoDictionaryKey: "JarvisSafariExperiment")),
                                clickMarker: isTrueBoolean(Bundle.main.object(forInfoDictionaryKey: "JarvisSafariClickExperiment")))
    }
    static var current: String { directoryName(bundleID: Bundle.main.bundleIdentifier) }
}
