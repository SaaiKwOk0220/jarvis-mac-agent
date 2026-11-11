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

public enum SafariVisiblePageError: LocalizedError {
    case targetChanged
    public var errorDescription: String? { "The Safari page changed; start the request again." }
}

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

public enum SafariAXReadError: LocalizedError {
    case permissionDenied, unavailable, targetChanged, limitExceeded, notFocused, focusTimedOut
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要辅助功能权限才能读取 Safari。请打开系统设置 → 隐私与安全性 → 辅助功能，允许 Jarvis Safari Experiment（local.jarvis.safari-experiment）；如列表中没有该应用，请用 + 添加当前实验包。授权后返回 Jarvis，重新提交原请求并切换到目标 Safari 页面。Jarvis 不会自动更改权限。"
        case .unavailable: return "The Safari page could not be inspected safely."
        case .targetChanged: return "The Safari window or page changed; start the request again."
        case .limitExceeded: return "The Safari page exceeded the safe read limit."
        case .notFocused: return "Switch to the intended Safari window."
        case .focusTimedOut: return "Safari did not return to the foreground in time; start the request again."
        }
    }
}

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

    fileprivate static func element(_ element: AXUIElement, _ key: String) throws -> AXUIElement {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw SafariAXReadError.unavailable }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    fileprivate static func readPage(_ window: AXUIElement, includeText: Bool) throws -> (url: String, text: String) {
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

/// One capture keeps the actual AX window reference in an actor, never in storage.
/// AX cannot guarantee a document-atomic snapshot or rule out same-URL ABA.
actor SafariAXTargetCapture: SafariTargetCapturing {
    private var window: AXUIElement?
    private var processID: pid_t?
    private var launchDate: Date?
    private var expectedURL: String?
    private var captureInProgress = false
    private let identity = UUID()

    func capture() async throws -> SafariCapturedTarget {
        guard window == nil, !captureInProgress else { throw SafariAXReadError.unavailable }
        captureInProgress = true
        defer { captureInProgress = false }
        guard AXIsProcessTrusted() else { throw SafariAXReadError.permissionDenied }
        let front = await Self.frontmostSafari()
        guard let front else { throw SafariAXReadError.notFocused }
        let application = AXUIElementCreateApplication(front.pid)
        let candidate = try SafariFocusedPageAdapter.element(application, kAXFocusedWindowAttribute as String)
        let page = try SafariFocusedPageAdapter.readPage(candidate, includeText: false)
        guard let components = URLComponents(string: page.url), components.scheme == "https",
              components.user == nil, components.password == nil, components.fragment == nil,
              page.url.utf8.count <= 4096 else { throw SafariAXReadError.unavailable }
        let after = await Self.frontmostSafari()
        guard after?.pid == front.pid, after?.launched == front.launched,
              CFEqual(candidate, try SafariFocusedPageAdapter.element(application, kAXFocusedWindowAttribute as String)),
              try SafariFocusedPageAdapter.readPage(candidate, includeText: false).url == page.url else { throw SafariAXReadError.targetChanged }
        self.window = candidate
        self.processID = front.pid
        self.launchDate = front.launched
        self.expectedURL = page.url
        return SafariCapturedTarget(url: page.url, processID: front.pid, windowIdentity: identity)
    }

    /// Fails closed if the captured process, focused AX window or exact URL differs.
    func verify(_ target: SafariCapturedTarget) async throws {
        guard target.windowIdentity == identity, let window, let pid = processID,
              let launchDate, target.processID == pid, target.url == expectedURL else { throw SafariAXReadError.targetChanged }
        let front = await Self.frontmostSafari()
        guard let front else { throw SafariAXReadError.notFocused }
        guard front.pid == pid, front.launched == launchDate else { throw SafariAXReadError.targetChanged }
        let application = AXUIElementCreateApplication(pid)
        guard CFEqual(window, try SafariFocusedPageAdapter.element(application, kAXFocusedWindowAttribute as String)),
              try SafariFocusedPageAdapter.readPage(window, includeText: false).url == target.url else { throw SafariAXReadError.targetChanged }
    }

    /// Call only after exact-target approval. AX reads are not atomic; same-URL ABA remains possible.
    func read(_ target: SafariCapturedTarget) async throws -> String {
        try await verify(target)
        guard let window else { throw SafariAXReadError.targetChanged }
        let result = try SafariFocusedPageAdapter.readPage(window, includeText: true)
        guard result.url == target.url else { throw SafariAXReadError.targetChanged }
        try Task.checkCancellation()
        try await verify(target)
        return result.text
    }

    private static func frontmostSafari() async -> (pid: pid_t, launched: Date)? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Safari", let date = app.launchDate else { return nil }
            return (app.processIdentifier, date)
        }
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
              SafariSafeOrigin.validated(request.target) != nil else { throw SafariAXReadError.unavailable }
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

#if os(macOS)
/// Shared bounded traversal, injectable for tests. Individual AX calls and
/// their returned arrays cannot be given a hard time or memory bound here.
/// Cycles fail closed at the node limit.
enum SafariClickTraversal {
    static func find<Node>(root: Node, maxNodes: Int = 3000, maxDepth: Int = 30,
        expired: () -> Bool, inspect: (Node, Bool) throws -> (role: String, match: Bool, children: [Node])) throws -> [Node] {
        var stack: [(Node, Int, Bool)] = [(root, 0, false)]
        var found: [Node] = []
        var count = 0
        while let (node, depth, inWeb) = stack.popLast() {
            try Task.checkCancellation()
            count += 1
            guard count <= maxNodes, depth <= maxDepth, !expired() else { throw SafariAXReadError.limitExceeded }
            let item = try inspect(node, inWeb)
            guard !expired(), item.children.count <= maxNodes - count - stack.count else {
                throw SafariAXReadError.limitExceeded
            }
            if inWeb && item.match {
                found.append(node)
                guard found.count <= 1 else { throw SafariAXReadError.unavailable }
            }
            for child in item.children { stack.append((child, depth + 1, inWeb || item.role == "AXWebArea")) }
        }
        return found
    }
}

/// Captures an AX reference only; it never performs an action. AX snapshots
/// are not atomic and a same-URL document replacement cannot be ruled out.
enum SafariClickCandidateProvider {
    static func candidates(expected: SafariClickIdentity) async throws -> [SafariClickCandidate] {
        guard AXIsProcessTrusted(), !expected.title.isEmpty, expected.enabled else { throw SafariAXReadError.permissionDenied }
        let process = await MainActor.run { () -> (pid_t, Date)? in
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Safari" else { return nil }
            guard let launch = app.launchDate else { return nil }
            return (app.processIdentifier, launch)
        }
        guard let (pid, launchDate) = process, pid == expected.pid else { throw SafariAXReadError.notFocused }
        let app = AXUIElementCreateApplication(pid)
        let window = try SafariFocusedPageAdapter.element(app, kAXFocusedWindowAttribute as String)
        let page = try SafariFocusedPageAdapter.readPage(window, includeText: false)
        guard page.url == expected.url else { throw SafariAXReadError.targetChanged }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let nodes = try SafariClickTraversal.find(root: window, expired: { ContinuousClock.now >= deadline }) { node, inWeb in
            guard AXUIElementSetMessagingTimeout(node, 0.25) == .success else { throw SafariAXReadError.unavailable }
            var rawRole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &rawRole) == .success,
                  let role = rawRole as? String else { throw SafariAXReadError.unavailable }
            var match = false
            if inWeb && role == expected.role {
                var rawTitle: CFTypeRef?
                var rawEnabled: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXTitleAttribute as CFString, &rawTitle) == .success,
                      let title = rawTitle as? String,
                      AXUIElementCopyAttributeValue(node, kAXEnabledAttribute as CFString, &rawEnabled) == .success,
                      let enabled = rawEnabled as? Bool else { throw SafariAXReadError.unavailable }
                match = title == expected.title && enabled
            }
            var rawChildren: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &rawChildren)
            let children: [AXUIElement]
            if status == .success {
                guard let value = rawChildren as? [AXUIElement] else { throw SafariAXReadError.unavailable }
                children = value
            } else if status == .noValue || status == .attributeUnsupported { children = [] }
            else { throw SafariAXReadError.unavailable }
            return (role, match, children)
        }
        let results = nodes.map { SafariClickCandidate(element: $0, window: window, launchDate: launchDate, identity: expected) }
        let current = await MainActor.run { () -> (pid_t, Date)? in
            guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Safari", let launch = app.launchDate else { return nil }
            return (app.processIdentifier, launch)
        }
        guard current?.0 == pid, current?.1 == launchDate,
              CFEqual(window, try SafariFocusedPageAdapter.element(app, kAXFocusedWindowAttribute as String)),
              try SafariFocusedPageAdapter.readPage(window, includeText: false).url == expected.url else { throw SafariAXReadError.targetChanged }
        return results
    }
}
#endif
