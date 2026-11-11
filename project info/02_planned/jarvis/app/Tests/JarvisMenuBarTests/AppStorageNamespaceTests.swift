import XCTest
@testable import JarvisMenuBar

final class AppStorageNamespaceTests: XCTestCase {
    func testExperimentUsesSeparateStorageNamespace() {
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: "local.jarvis.safari-experiment"), "Jarvis-Safari-Experiment")
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: "local.jarvis.dev"), "Jarvis")
        XCTAssertEqual(AppStorageNamespace.directoryName(bundleID: nil), "Jarvis")
    }
}
