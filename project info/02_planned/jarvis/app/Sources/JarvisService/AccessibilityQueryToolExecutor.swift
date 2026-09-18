import Foundation
import AppKit
// `kAXTrustedCheckOptionPrompt` is declared as a plain C `var` in
// HIServices, which Swift 6 flags as non-concurrency-safe global mutable
// state. The framework predates Swift concurrency, so `@preconcurrency`
// downgrades that diagnostic for this import only; the constant is a
// process-wide immutable value in practice.
@preconcurrency import ApplicationServices
import JarvisDomain

/// Errors surfaced by `AccessibilityQueryToolExecutor`.
public enum AccessibilityQueryToolExecutorError: Error, Equatable, Sendable {
    case incompatibleSideEffect(SideEffect)
    case permissionRequired
    case appNotFound(String)
    case invalidPayload(String)
    case underlying(String)
}

/// Parameters for one accessibility-tree inspection. `target` is an
/// application bundle identifier (`com.*`); the executor resolves it to a
/// running process and walks its `AXUIElement` tree up to `maxDepth` levels
/// deep and `maxNodes` total nodes.
public struct AXQuery: Sendable, Equatable {
    public let target: String
    public let maxDepth: Int
    public let maxNodes: Int

    public init(target: String, maxDepth: Int = 4, maxNodes: Int = 200) {
        self.target = target
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }

    /// Parses the request payload as a JSON object. An empty payload (or an
    /// object without the relevant keys) keeps the defaults; a payload that is
    /// not a JSON object is rejected as `invalidPayload`.
    public init(payload: String, target: String) throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.init(target: target)
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw AccessibilityQueryToolExecutorError.invalidPayload(payload)
        }
        self.init(
            target: target,
            maxDepth: object["maxDepth"] as? Int ?? 4,
            maxNodes: object["maxNodes"] as? Int ?? 200
        )
    }
}

/// `ToolExecutor` that reads an app's macOS accessibility tree via
/// `AXUIElement` and returns a compact text rendering (role, title, value) for
/// the task timeline.
///
/// Read-only by design: only `sideEffect == .read` is accepted and the walk
/// never performs an AX action (no click, type, or set-attribute). The tree
/// read is abstracted behind a `@Sendable (AXQuery) async throws -> String`
/// closure so the default can drive real `AXUIElement` calls while tests
/// substitute a mock that never touches the Accessibility permission flow.
///
/// The `target` must be an application bundle identifier so the read-side
/// `Policy` application allowlist gate (`PolicyConfig.applicationBundleIDs`)
/// applies before the executor ever runs.
public struct AccessibilityQueryToolExecutor: ToolExecutor, Sendable {
    public let query: @Sendable (AXQuery) async throws -> String

    public init(query: @escaping @Sendable (AXQuery) async throws -> String = Self.defaultQuery) {
        self.query = query
    }

    public func execute(_ request: ToolRequest) async throws -> ToolResult {
        guard request.sideEffect == .read else {
            throw AccessibilityQueryToolExecutorError.incompatibleSideEffect(request.sideEffect)
        }
        let axQuery = try AXQuery(payload: request.payload, target: request.target)
        let tree = try await query(axQuery)
        return ToolResult(summary: "Accessibility tree of \(axQuery.target):\n\(tree)")
    }

    /// Default query that requires the Accessibility permission, resolves
    /// `axQuery.target` to a running process, and walks its element tree.
    /// Without the permission this triggers the system prompt and throws
    /// `.permissionRequired` so the menu bar can point the user at
    /// System Settings > Privacy & Security > Accessibility.
    public static func defaultQuery(_ axQuery: AXQuery) async throws -> String {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw AccessibilityQueryToolExecutorError.permissionRequired
        }

        // The target is a bundle identifier; fall back to a raw PID string so
        // the executor stays usable from callers that already hold one.
        let pid: pid_t
        if let intPID = pid_t(axQuery.target) {
            pid = intPID
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: axQuery.target).first {
            pid = app.processIdentifier
        } else {
            throw AccessibilityQueryToolExecutorError.appNotFound(axQuery.target)
        }

        let appElement = AXUIElementCreateApplication(pid)
        var output = ""
        var nodeCount = 0
        try walk(appElement, depth: 0, maxDepth: axQuery.maxDepth, maxNodes: axQuery.maxNodes,
                 output: &output, nodeCount: &nodeCount)
        return output
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        output: inout String,
        nodeCount: inout Int
    ) throws {
        guard depth <= maxDepth, nodeCount < maxNodes else { return }
        nodeCount += 1

        let indent = String(repeating: "  ", count: depth)
        let role = attribute(element, kAXRoleAttribute) ?? "?"
        let title = attribute(element, kAXTitleAttribute) ?? ""
        let value = attribute(element, kAXValueAttribute) ?? ""

        var line = "\(indent)\(role)"
        if !title.isEmpty { line += " \"\(title.prefix(60))\"" }
        if !value.isEmpty { line += " value=\"\(value.prefix(60))\"" }
        output += line + "\n"

        if let children = children(element) {
            for child in children {
                try walk(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes,
                         output: &output, nodeCount: &nodeCount)
            }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success, let value else { return nil }
        if let str = value as? String { return str }
        if let num = value as? NSNumber { return num.stringValue }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else { return nil }
        return array
    }
}
