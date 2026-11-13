import XCTest
import Darwin
import AppKit
import ImageIO
@testable import JarvisMenuBar

final class VisionImageSelectionTests: XCTestCase {
    private func image(width: Int = 1, height: Int = 1) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testExplicitImageRejectsUnsupportedAndOversizedData() throws {
        XCTAssertThrowsError(try VisionImageSelection.validate(Data("not an image".utf8)))
        let png = try image()
        XCTAssertNoThrow(try VisionImageSelection.validate(png))
        XCTAssertThrowsError(try VisionImageSelection.validate(png + Data(count: 5 * 1024 * 1024)))
        XCTAssertThrowsError(try VisionImageSelection.validate(Data(png.prefix(32))))
        XCTAssertThrowsError(try VisionImageSelection.validate(try image(width: 9000)))
    }

    func testReadsRegularSelectedFileAndRejectsLinksAndPipes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try image()
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
        let original = try image()
        try original.write(to: file)
        let snapshot = try VisionImageSelection.snapshot(file)
        try Data([0xff, 0xd8, 0xff, 2]).write(to: file, options: .atomic)
        XCTAssertEqual(snapshot.data, original)
        XCTAssertEqual(snapshot.name, "a.png")
        let preview = try XCTUnwrap(CGImageSourceCreateWithData(snapshot.thumbnail as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(preview), 1)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(preview, 0, nil))
    }
}
