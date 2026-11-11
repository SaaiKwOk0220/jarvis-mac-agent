import XCTest
@testable import JarvisMenuBar

final class AppStorageNamespaceTests: XCTestCase {
    func testIntegratedScopesRemainSeparate() {
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.safari-experiment", vadIsolation: false), "Jarvis-Safari-Experiment")
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.vad-experiment", vadIsolation: true), "Jarvis-VAD-Experiment")
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.dev", vadIsolation: false), "Jarvis")
    }
    func testSafariRequiresExactExperimentBundleAndFlag() {
        for id in [nil, "local.jarvis.dev", "other"] as [String?] {
            XCTAssertFalse(AppStorageNamespace.safariReadEnabled(bundleID: id, flag: "1"))
        }
        XCTAssertFalse(AppStorageNamespace.safariReadEnabled(bundleID: "local.jarvis.safari-experiment", flag: nil))
        XCTAssertTrue(AppStorageNamespace.safariReadEnabled(bundleID: "local.jarvis.safari-experiment", flag: "1"))
    }
    func testExperimentUsesSeparateStorageNamespace() {
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: "local.jarvis.safari-experiment"), "Jarvis-Safari-Experiment")
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: "local.jarvis.dev"), "Jarvis")
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: nil), "Jarvis")
    }
}
