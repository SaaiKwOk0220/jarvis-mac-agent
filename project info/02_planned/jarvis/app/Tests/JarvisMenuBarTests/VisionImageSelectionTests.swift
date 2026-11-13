import XCTest
import Darwin
import AppKit
import ImageIO
import JarvisLLM
@testable import JarvisMenuBar

final class VisionImageSelectionTests: XCTestCase {
    private func image(width: Int = 1, height: Int = 1) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        var plain = Data(png.prefix(8))
        var offset = 8
        while offset + 12 <= png.count {
            let size = png[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let end = offset + size + 12
            let name = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if name != "eXIf" { plain.append(png[offset..<end]) }
            offset = end
        }
        return plain
    }
    private func hex(_ string: String) -> Data {
        let digits = Array(string.utf8)
        return Data(stride(from: 0, to: digits.count, by: 2).map { index in
            UInt8(String(decoding: digits[index..<(index + 2)], as: UTF8.self), radix: 16)!
        })
    }
    func testExplicitImageRejectsUnsupportedAndOversizedData() throws {
        XCTAssertThrowsError(try VisionImageSelection.validate(Data("not an image".utf8)))
        let png = try image()
        XCTAssertNoThrow(try VisionImageSelection.validate(png))
        XCTAssertThrowsError(try VisionImageSelection.validate(png + Data(count: 5 * 1024 * 1024)))
        XCTAssertThrowsError(try VisionImageSelection.validate(Data(png.prefix(32))))
        XCTAssertThrowsError(try VisionImageSelection.validate(Data(png.prefix(64))))
        XCTAssertThrowsError(try VisionImageSelection.validate(Data(png.prefix(min(100, png.count - 1)))))
        XCTAssertThrowsError(try VisionImageSelection.validate(Data(png.dropLast())))
        var invalidCRC = png
        invalidCRC[invalidCRC.count - 1] ^= 1
        XCTAssertThrowsError(try VisionImageSelection.validate(invalidCRC))
        let animation = Data([0, 0, 0, 8, 0x61, 0x63, 0x54, 0x4c, 0, 0, 0, 2, 0, 0, 0, 0, 0xf3, 0x8d, 0x93, 0x70])
        var animatedPNG = png
        animatedPNG.insert(contentsOf: animation, at: 33)
        XCTAssertThrowsError(try VisionImageSelection.validate(animatedPNG))
        var unknownCritical = png
        unknownCritical.insert(contentsOf: hex("0000000141424344782abb56c4"), at: 33)
        XCTAssertThrowsError(try VisionImageSelection.validate(unknownCritical))
        let metadata = Data([0,0,0,13,0x74,0x45,0x58,0x74,0x43,0x6f,0x6d,0x6d,0x65,0x6e,0x74,0,0x68,0x65,0x6c,0x6c,0x6f,0xe6,0xff,0xae,0x24])
        var pngWithMetadata = png
        pngWithMetadata.insert(contentsOf: metadata, at: 33)
        XCTAssertNoThrow(try VisionImageSelection.validate(pngWithMetadata))
        var brokenMetadata = pngWithMetadata
        brokenMetadata[40] ^= 1
        XCTAssertThrowsError(try VisionImageSelection.validate(brokenMetadata))
        let compressedMetadata = Data([0,0,0,15,0x69,0x43,0x43,0x50,0x78,0,0,0x78,0x9c,0x73,0x74,0xa4,0x3d,0,0,2,0xe9,0x19,0x65,0x3c,0xb7,0x89,0xe7])
        var pngWithCompressedMetadata = png
        pngWithCompressedMetadata.insert(contentsOf: compressedMetadata, at: 33)
        XCTAssertNoThrow(try VisionImageSelection.validate(pngWithCompressedMetadata))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try pngWithCompressedMetadata.write(to: file)
        let safeSnapshot = try VisionImageSelection.snapshot(file)
        XCTAssertNil(safeSnapshot.data.range(of: Data("iCCP".utf8)))
        XCTAssertNil(safeSnapshot.data.range(of: Data("sRGB".utf8)))
        XCTAssertNotNil(CGImageSourceCreateWithData(safeSnapshot.data as CFData, nil))
        let palette = Data([0,0,0,3,0x50,0x4c,0x54,0x45,0xff,0,0,0x19,0xe2,0x09,0x37])
        let dataChunk = try XCTUnwrap(png.range(of: Data([0x49,0x44,0x41,0x54])))
        var duplicatedPalette = png
        duplicatedPalette.insert(contentsOf: palette + palette, at: dataChunk.lowerBound - 4)
        XCTAssertThrowsError(try VisionImageSelection.validate(duplicatedPalette))
        let badDeflate = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0,0,0,0x0d,0x49,0x48,0x44,0x52,0,0,0,1,0,0,0,1,8,6,0,0,0,0x1f,0x15,0xc4,0x89,0,0,0,4,0x49,0x44,0x41,0x54,0x6a,0x75,0x6e,0x6b,0xcd,0x9c,0xa4,0x22,0,0,0,0,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82])
        XCTAssertThrowsError(try VisionImageSelection.validate(badDeflate))
        let badFilter = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0,0,0,0x0d,0x49,0x48,0x44,0x52,0,0,0,1,0,0,0,1,8,6,0,0,0,0x1f,0x15,0xc4,0x89,0,0,0,0x0d,0x49,0x44,0x41,0x54,0x78,0x9c,0x63,0x65,0x60,0x60,0xf8,0x0f,0,0x01,0x1d,0x01,0x05,0xda,0x51,0x64,0x7f,0,0,0,0,0x49,0x45,0x4e,0x44,0xae,0x42,0x60,0x82])
        XCTAssertThrowsError(try VisionImageSelection.validate(badFilter))
        XCTAssertThrowsError(try VisionImageSelection.validate(try image(width: 9000)))
    }

    func testPaletteTransparencyRetainedAndBoundedToPalette() throws {
        let good = hex("89504e470d0a1a0a0000000d494844520000000100000001080300000028cb34bb00000006504c5445ff00000000ff6ca1fd8e0000000274524e53ff00e5b7304a0000000a49444154789c636000000002000148afa4710000000049454e44ae426082")
        let bad = hex("89504e470d0a1a0a0000000d494844520000000100000001080300000028cb34bb00000006504c5445ff00000000ff6ca1fd8e0000000374524e53ff000044eef0330000000a49444154789c636000000002000148afa4710000000049454e44ae426082")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try good.write(to: file)
        let snapshot = try VisionImageSelection.snapshot(file)
        XCTAssertNotNil(snapshot.data.range(of: Data("tRNS".utf8)))
        XCTAssertThrowsError(try VisionImageSelection.validate(bad))
    }

    func testMacPNGMetadataIsRemovedBeforePreviewAndSubmission() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertNotNil(original.range(of: Data("eXIf".utf8)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try original.write(to: file)
        let snapshot = try VisionImageSelection.snapshot(file)
        XCTAssertNil(snapshot.data.range(of: Data("eXIf".utf8)))
        XCTAssertNil(snapshot.data.range(of: Data("sRGB".utf8)))
        XCTAssertNotNil(CGImageSourceCreateWithData(snapshot.thumbnail as CFData, nil))
    }

    func testReadsRegularSelectedFileAndRejectsLinksAndPipes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try image()
        let file = directory.appendingPathComponent("a.png")
        try png.write(to: file)
        let safe = try VisionImageSelection.read(file)
        XCTAssertNotNil(safe.range(of: Data("IDAT".utf8)))
        XCTAssertNil(safe.range(of: Data("sRGB".utf8)))
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
        XCTAssertNil(snapshot.data.range(of: Data("sRGB".utf8)))
        XCTAssertEqual(snapshot.name, "a.png")
        let preview = try XCTUnwrap(CGImageSourceCreateWithData(snapshot.thumbnail as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(preview), 1)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(preview, 0, nil))
    }

    func testSnapshotGateRemainsHeldUntilWorkerActuallyReturns() throws {
        try VisionImageSelection.withExclusiveSnapshot {
            XCTAssertThrowsError(try VisionImageSelection.withExclusiveSnapshot { 1 })
        }
        XCTAssertEqual(try VisionImageSelection.withExclusiveSnapshot { 2 }, 2)
        XCTAssertThrowsError(try VisionImageSelection.withExclusiveSnapshot { throw VisionError.invalidRequest })
        XCTAssertEqual(try VisionImageSelection.withExclusiveSnapshot { 3 }, 3)
    }

    func testSnapshotGateRejectsAnotherWorkerUntilFirstExits() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "worker exits")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            _ = try? VisionImageSelection.withExclusiveSnapshot {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try VisionImageSelection.withExclusiveSnapshot { 1 })
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(try VisionImageSelection.withExclusiveSnapshot { 2 }, 2)
    }
}
