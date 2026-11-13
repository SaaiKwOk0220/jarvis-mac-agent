import AppKit
import Foundation
import SwiftUI

/// Renders a caller-supplied SwiftUI view without constructing the production App.
@MainActor
enum VisualPreviewHarness {
    enum PreviewError: Error { case invalidDestination, renderFailed }
    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, to output: URL) throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let destination = output.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination.hasPrefix(tempRoot + "/"), output.pathExtension.lowercased() == "png",
              width.isFinite, height.isFinite, (1...4096).contains(width), (1...4096).contains(height) else {
            throw PreviewError.invalidDestination
        }
        let suite = "local.jarvis.preview." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw PreviewError.renderFailed }
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosted = NSHostingView(rootView: view.defaultAppStorage(defaults).frame(width: width, height: height))
        hosted.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosted.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        hosted.displayIfNeeded()
        guard let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else { throw PreviewError.renderFailed }
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.renderFailed }
        try png.write(to: output, options: .atomic)
    }
}
