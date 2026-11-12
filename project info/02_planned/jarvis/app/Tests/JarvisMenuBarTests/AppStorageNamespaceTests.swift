import XCTest
@testable import JarvisMenuBar

final class AppStorageNamespaceTests: XCTestCase {
    func testIntegratedScopesRemainSeparate() {
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.browser-experiment", vadIsolation: false), "Jarvis-Browser-Experiment")
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.safari-experiment", vadIsolation: false), "Jarvis-Safari-Experiment")
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.vad-experiment", vadIsolation: true), "Jarvis-VAD-Experiment")
        XCTAssertEqual(AppStorageScope.directory(bundleID: "local.jarvis.dev", vadIsolation: false), "Jarvis")
    }
    func testCurrentBuildDoesNotEnableSafariFromSpoofedIdentity() {
        #if JARVIS_SAFARI_EXPERIMENT_BUILD
        XCTAssertTrue(AppStorageNamespace.safariReadEnabledInCurrentBuild(bundleID: "local.jarvis.safari-experiment", flag: "1"))
        #else
        XCTAssertFalse(AppStorageNamespace.safariReadEnabledInCurrentBuild(bundleID: "local.jarvis.safari-experiment", flag: "1"))
        #endif
        XCTAssertFalse(AppStorageNamespace.safariReadEnabledInCurrentBuild(bundleID: "local.jarvis.dev", flag: "1"))
        XCTAssertFalse(AppStorageNamespace.safariReadEnabledInCurrentBuild(bundleID: "local.jarvis.safari-experiment", flag: nil))
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
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: "local.jarvis.safari-click-experiment"), "Jarvis-Safari-Click-Experiment")
        XCTAssertFalse(AppStorageNamespace.safariReadEnabled(bundleID: "local.jarvis.safari-click-experiment", flag: "1"))
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: "local.jarvis.dev"), "Jarvis")
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: nil), "Jarvis")
    }
}

extension AppStorageNamespaceTests {
    func testReadToggleRequiresMatchingBuildIdentityAndMarkers() {
        XCTAssertTrue(AppStorageNamespace.allowsReadToggle(safariBuild: true, clickBuild: false, bundleID: "local.jarvis.safari-experiment", safariMarker: true, clickMarker: false))
        XCTAssertTrue(AppStorageNamespace.allowsReadToggle(safariBuild: true, clickBuild: true, bundleID: "local.jarvis.safari-click-experiment", safariMarker: true, clickMarker: true))
        XCTAssertFalse(AppStorageNamespace.allowsReadToggle(safariBuild: false, clickBuild: true, bundleID: "local.jarvis.safari-click-experiment", safariMarker: true, clickMarker: true))
        XCTAssertFalse(AppStorageNamespace.allowsReadToggle(safariBuild: true, clickBuild: false, bundleID: "local.jarvis.safari-click-experiment", safariMarker: true, clickMarker: true))
        XCTAssertFalse(AppStorageNamespace.allowsReadToggle(safariBuild: true, clickBuild: true, bundleID: "local.jarvis.safari-click-experiment", safariMarker: true, clickMarker: false))
        XCTAssertFalse(AppStorageNamespace.allowsReadToggle(safariBuild: true, clickBuild: true, bundleID: "local.jarvis.safari-click-experiment", safariMarker: false, clickMarker: true))
        XCTAssertFalse(AppStorageNamespace.allowsReadToggle(safariBuild: true, clickBuild: true, bundleID: "local.jarvis.safari-experiment", safariMarker: true, clickMarker: true))
    }
}

extension AppStorageNamespaceTests {
    func testMarkerRequiresTrueCFBooleanNotInteger() {
        XCTAssertTrue(AppStorageNamespace.isTrueBoolean(NSNumber(value: true)))
        XCTAssertFalse(AppStorageNamespace.isTrueBoolean(NSNumber(value: false)))
        XCTAssertFalse(AppStorageNamespace.isTrueBoolean(NSNumber(value: 1)))
        XCTAssertFalse(AppStorageNamespace.isTrueBoolean(nil))
    }
}
