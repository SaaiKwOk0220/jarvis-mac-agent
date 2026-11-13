import Foundation
import AVFoundation
import AppKit
import CoreVideo

guard CommandLine.arguments.count == 2 else { exit(2) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let video = directory.appendingPathComponent("synthetic.mov")
try? FileManager.default.removeItem(at: video)
let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
let width = 320, height = 180
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
guard writer.canAdd(input) else { fatalError("writer unavailable") }
writer.add(input)
guard writer.startWriting() else { print("writer failed: \(String(describing: writer.error))"); exit(1) }
writer.startSession(atSourceTime: .zero)
for index in 0..<8 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
    guard let buffer else { fatalError("buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { fatalError("base") }
    let row = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let pixels = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let isLeft = x < width / 2
            let red = index < 4 ? isLeft : !isLeft
            pixels[x*4] = red ? 0 : 255
            pixels[x*4+1] = 0
            pixels[x*4+2] = red ? 255 : 0
            pixels[x*4+3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 4)) else { fatalError("append failed") }
}
input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
guard finished.wait(timeout: .now() + 20) == .success, writer.status == .completed else { fatalError("finish failed") }
let asset = AVURLAsset(url: video, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
let generator = AVAssetImageGenerator(asset: asset)
generator.maximumSize = CGSize(width: 160, height: 160)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
for (number, seconds) in [0.25, 1.25].enumerated() {
    let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    let representation = NSBitmapImageRep(cgImage: frame)
    guard frame.width <= 160, frame.height <= 160,
          let left = representation.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB),
          let right = representation.colorAt(x: 140, y: 20)?.usingColorSpace(.deviceRGB),
          number == 0 ? left.redComponent > left.blueComponent && right.blueComponent > right.redComponent : left.blueComponent > left.redComponent && right.redComponent > right.blueComponent else { fatalError("unexpected frame colors") }
    guard let png = representation.representation(using: .png, properties: [:]), png.count <= 1_048_576 else { fatalError("png") }
    let path = directory.appendingPathComponent("frame-\(number).png")
    try png.write(to: path, options: .atomic)
    print("\(path.path) \(frame.width)x\(frame.height) \(png.count) bytes")
}
print("reference restriction \(asset.referenceRestrictions.rawValue)")
