import XCTest
import Darwin
@testable import JarvisMenuBar

final class VisionImageSelectionTests: XCTestCase {
    func testExplicitImageRejectsUnsupportedAndOversizedData() throws {
        XCTAssertThrowsError(try VisionImageSelection.validate(Data("not an image".utf8)))
        let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        XCTAssertNoThrow(try VisionImageSelection.validate(signature))
        XCTAssertThrowsError(try VisionImageSelection.validate(signature + Data(count: 5 * 1024 * 1024)))
    }

    func testReadsRegularSelectedFileAndRejectsLinksAndPipes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let file = directory.appendingPathComponent("a.png")
        try png.write(to: file)
        XCTAssertEqual(try VisionImageSelection.read(file), png)
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try VisionImageSelection.read(link))
        let pipe = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try VisionImageSelection.read(pipe))
    }

    func testSnapshotKeepsSelectedBytesAfterFileReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.png")
        let original = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1])
        try original.write(to: file)
        let snapshot = try VisionImageSelection.snapshot(file)
        try Data([0xff, 0xd8, 0xff, 2]).write(to: file, options: .atomic)
        XCTAssertEqual(snapshot.data, original)
        XCTAssertEqual(snapshot.name, "a.png")
    }
}
