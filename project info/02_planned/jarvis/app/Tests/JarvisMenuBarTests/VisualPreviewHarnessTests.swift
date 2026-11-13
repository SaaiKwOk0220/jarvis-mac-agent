import Foundation
import SwiftUI
import XCTest

@MainActor
final class VisualPreviewHarnessTests: XCTestCase {
    func testRendersOnlyIntoTemporaryDirectory() throws {
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        try VisualPreviewHarness.render(Text("Preview"), width: 320, height: 180, to: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try VisualPreviewHarness.render(Text("Preview"), width: 320, height: 180, to: URL(fileURLWithPath: "/Users/preview.png")))
    }
}
