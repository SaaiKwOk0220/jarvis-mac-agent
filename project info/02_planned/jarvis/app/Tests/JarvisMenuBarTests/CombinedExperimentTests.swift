import XCTest
@testable import JarvisMenuBar

final class CombinedExperimentTests: XCTestCase {
    func testIdentityRequiresBuildIDAndMarker() {
        XCTAssertFalse(CombinedExperimentAccess.allowed(build: false, bundleID: "local.jarvis.combined-experiment", marker: true))
        XCTAssertFalse(CombinedExperimentAccess.allowed(build: true, bundleID: "local.jarvis.dev", marker: true))
        XCTAssertFalse(CombinedExperimentAccess.allowed(build: true, bundleID: "local.jarvis.combined-experiment", marker: false))
        XCTAssertTrue(CombinedExperimentAccess.allowed(build: true, bundleID: "local.jarvis.combined-experiment", marker: true))
    }
    func testIndependentFlagsDefaultOff() {
        let identity = CombinedExperimentAccess.allowed(build: true, bundleID: "local.jarvis.combined-experiment", marker: true)
        XCTAssertFalse(CombinedExperimentAccess.enabled(identity: identity, optIn: nil))
        XCTAssertTrue(CombinedExperimentAccess.enabled(identity: identity, optIn: "1"))
        XCTAssertFalse(CombinedExperimentAccess.enabled(identity: false, optIn: "1"))
    }
    func testEachOptInIsIndependent() {
        for safari in [false, true] {
            for browser in [false, true] {
                let safariResult = CombinedExperimentAccess.enabled(identity: true, optIn: safari ? "1" : nil)
                let browserResult = CombinedExperimentAccess.enabled(identity: true, optIn: browser ? "1" : nil)
                XCTAssertEqual(safariResult, safari)
                XCTAssertEqual(browserResult, browser)
            }
        }
    }
    func testCombinedUsesPrivateSeparateStorage() {
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.combined-experiment", vadIsolation: false), "Jarvis-Combined-Experiment")
    }
}
