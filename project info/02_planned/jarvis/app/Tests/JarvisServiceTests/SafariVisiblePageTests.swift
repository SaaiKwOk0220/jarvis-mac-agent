import JarvisDomain

import XCTest
@testable import JarvisService

final class SafariVisiblePageTests: XCTestCase {
    func testRejectsChangedTargetBeforeReturningPage() async throws {
        let reader = SafariVisiblePageReader { _ in SafariPageSnapshot(bundleID: "com.apple.Safari", url: "https://other.example/", text: "private") }
        do {
            _ = try await reader.read(expectedURL: "https://example.com/")
            XCTFail("Mismatched page must be rejected")
        } catch SafariVisiblePageError.targetChanged {}
    }
    func testReturnsOnlyMatchingSafariSnapshot() async throws {
        let reader = SafariVisiblePageReader { _ in SafariPageSnapshot(bundleID: "com.apple.Safari", url: "https://example.com/", text: "visible") }
        let text = try await reader.read(expectedURL: "https://example.com/")
        XCTAssertEqual(text, "visible")
    }
}

private actor PageSequence {
    var count = 0
    func next(_ expectedURL: String) -> SafariPageSnapshot {
        count += 1
        return SafariPageSnapshot(bundleID: "com.apple.Safari", url: expectedURL, text: "version \(count)")
    }
}

extension SafariVisiblePageTests {
    func testReaderDoesNotCachePageTextAcrossCalls() async throws {
        let pages = PageSequence()
        let reader = SafariVisiblePageReader { expected in await pages.next(expected) }
        let first = try await reader.read(expectedURL: "https://example.com/")
        let second = try await reader.read(expectedURL: "https://example.com/")
        XCTAssertEqual(first, "version 1")
        XCTAssertEqual(second, "version 2")
    }

    func testExecutorRejectsUnapprovedTargetShape() async throws {
        let reader = SafariVisiblePageReader { _ in XCTFail("invalid input must not read"); return SafariPageSnapshot(bundleID: "com.apple.Safari", url: "", text: "") }
        let executor = SafariPageReadExecutor(reader: reader)
        let request = ToolRequest(taskID: UUID(), name: "safari_read", sideEffect: .read, target: "https://example.com/private?token=secret", payload: "Read Safari accessibility text")
        do { _ = try await executor.execute(request); XCTFail("expected rejection") }
        catch SafariAXReadError.unavailable { }
    }
}
