import XCTest
@testable import JarvisMenuBar
final class ExactBrowserExperimentTests: XCTestCase {
    func testNormalBuildNeverEnablesExperiment() {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT
        XCTAssertFalse(ExactBrowserExperiment.current)
        #endif
    }
    func testRequiresBuildIdentityMarkerAndExplicitOptIn() {
        XCTAssertFalse(ExactBrowserExperiment.enabled(experimentalBuild: false, bundleID: ExactBrowserExperiment.bundleID, marker: true, optIn: "1"))
        XCTAssertFalse(ExactBrowserExperiment.enabled(experimentalBuild: true, bundleID: "local.jarvis.dev", marker: true, optIn: "1"))
        XCTAssertFalse(ExactBrowserExperiment.enabled(experimentalBuild: true, bundleID: ExactBrowserExperiment.bundleID, marker: false, optIn: "1"))
        XCTAssertFalse(ExactBrowserExperiment.enabled(experimentalBuild: true, bundleID: ExactBrowserExperiment.bundleID, marker: true, optIn: nil))
        XCTAssertTrue(ExactBrowserExperiment.enabled(experimentalBuild: true, bundleID: ExactBrowserExperiment.bundleID, marker: true, optIn: "1"))
    }
}
