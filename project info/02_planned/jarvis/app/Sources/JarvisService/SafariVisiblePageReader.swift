import Foundation
import JarvisDomain

/// A snapshot supplied by a trusted, focused-window Safari accessibility adapter.
public struct SafariPageSnapshot: Sendable {
    public let bundleID: String
    public let url: String
    public let text: String

    public init(bundleID: String, url: String, text: String) {
        self.bundleID = bundleID
        self.url = url
        self.text = text
    }
}

public enum SafariVisiblePageError: Error { case targetChanged }

/// Validates snapshots before returning visible page text; no platform adapter is provided.
public struct SafariVisiblePageReader: Sendable {
    private let snapshot: @Sendable (String) async throws -> SafariPageSnapshot

    public init(snapshot: @escaping @Sendable (String) async throws -> SafariPageSnapshot) {
        self.snapshot = snapshot
    }

    public func read(expectedURL: String) async throws -> String {
        let value = try await snapshot(expectedURL)
        guard value.bundleID == "com.apple.Safari", value.url == expectedURL else {
            throw SafariVisiblePageError.targetChanged
        }
        return value.text
    }
}

#if os(macOS)
import AppKit
import ApplicationServices

public enum SafariAXReadError: Error { case permissionDenied, unavailable, targetChanged, limitExceeded, notFocused, focusTimedOut }

/// Reads only Safari's focused window and verifies the same window and URL after traversal.
public enum SafariFocusedPageAdapter {
    public static func snapshot(expectedURL: String) async throws -> SafariPageSnapshot {
        guard AXIsProcessTrusted() else { throw SafariAXReadError.permissionDenied }
        let frontPID = await MainActor.run { () -> pid_t? in
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Safari" else { return nil }
            return app.processIdentifier
        }
        guard let pid = frontPID else { throw SafariAXReadError.notFocused }
        let application = AXUIElementCreateApplication(pid)
        let window = try element(application, kAXFocusedWindowAttribute as String)
        let before = try readPage(window, includeText: false)
        guard before.url == expectedURL else { throw SafariAXReadError.targetChanged }
        let first = try readPage(window, includeText: true)
        guard first.url == expectedURL else { throw SafariAXReadError.targetChanged }
        let currentPID = await MainActor.run { () -> pid_t? in
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Safari" else { return nil }
            return app.processIdentifier
        }
        guard currentPID == pid else { throw SafariAXReadError.targetChanged }
        let currentWindow = try element(application, kAXFocusedWindowAttribute as String)
        guard CFEqual(window, currentWindow) else { throw SafariAXReadError.targetChanged }
        let second = try readPage(currentWindow, includeText: false)
        guard first.url == second.url else { throw SafariAXReadError.targetChanged }
        return SafariPageSnapshot(bundleID: "com.apple.Safari", url: first.url, text: first.text)
    }

    private static func element(_ element: AXUIElement, _ key: String) throws -> AXUIElement {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw SafariAXReadError.unavailable }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private static func readPage(_ window: AXUIElement, includeText: Bool) throws -> (url: String, text: String) {
        var stack: [(AXUIElement, Int, Bool)] = [(window, 0, false)]
        var count = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pageURL: String?
        var text = [String]()
        while let (node, depth, insideWebArea) = stack.popLast() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SafariAXReadError.limitExceeded }
            guard AXUIElementSetMessagingTimeout(node, 0.25) == .success else { throw SafariAXReadError.unavailable }
            count += 1
            guard count <= 3000, depth <= 30 else { throw SafariAXReadError.limitExceeded }
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String else { throw SafariAXReadError.unavailable }
            if role == "AXWebArea" {
                var rawURL: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &rawURL) == .success,
                      let url = rawURL as? URL, url.scheme?.lowercased() == "https", url.host != nil,
                      url.user == nil, url.password == nil, pageURL == nil else { throw SafariAXReadError.unavailable }
                pageURL = url.absoluteString
            }
            if includeText && insideWebArea && role == kAXStaticTextRole as String {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &value) == .success,
                   let string = value as? String, !string.isEmpty {
                    text.append(string)
                    guard text.reduce(0, { $0 + $1.utf8.count }) <= 32_000 else { throw SafariAXReadError.limitExceeded }
                }
            }
            var childrenValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenValue)
            if status == .success {
                guard let children = childrenValue as? [AXUIElement] else { throw SafariAXReadError.unavailable }
                for child in children.reversed() { stack.append((child, depth + 1, insideWebArea || role == "AXWebArea")) }
            } else if status != .noValue && status != .attributeUnsupported {
                throw SafariAXReadError.unavailable
            }
        }
        guard let pageURL else { throw SafariAXReadError.unavailable }
        return (pageURL, text.joined(separator: "\n"))
    }
}
#endif

/// Reads accessibility text after an explicitly approved exact HTTPS origin.
public struct SafariPageReadExecutor: ToolExecutor, Sendable {
    private let reader: SafariVisiblePageReader
    private let focusTimeout: Duration
    private let focusPollInterval: Duration
    public init(reader: SafariVisiblePageReader, focusTimeout: Duration = .seconds(15), focusPollInterval: Duration = .milliseconds(250)) {
        self.reader = reader
        self.focusTimeout = focusTimeout
        self.focusPollInterval = focusPollInterval
    }
    public func execute(_ request: ToolRequest) async throws -> ToolResult {
        guard request.name == "safari_read", request.sideEffect == .read,
              request.payload == "Read Safari accessibility text", request.scope == nil,
              BrowserOpenURL.validated(request.target) != nil else { throw SafariAXReadError.unavailable }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: focusTimeout)
        while true {
            try Task.checkCancellation()
            do {
                let text = try await reader.read(expectedURL: request.target)
                try Task.checkCancellation()
                return ToolResult(summary: text)
            } catch SafariAXReadError.notFocused {
                guard ContinuousClock.now < deadline else { throw SafariAXReadError.focusTimedOut }
                try await Task.sleep(for: focusPollInterval)
            }
        }
    }
}
