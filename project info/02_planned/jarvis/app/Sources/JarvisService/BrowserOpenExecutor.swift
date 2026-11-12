import AppKit
import Foundation
import JarvisDomain

public enum BrowserOpenError: Error { case invalidRequest, openFailed, unavailable }

/// Opens an approved HTTPS URL; no page contents are read or returned.
public struct BrowserOpenExecutor: ToolExecutor, Sendable {
    private let opener: @Sendable (URL) async -> Bool
    private let exactOpener: (@Sendable (URL) async -> Bool)?

    public init() {
        self.exactOpener = { url in
            do {
                _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                return true
            } catch { return false }
        }
        self.opener = { url in
            await MainActor.run {
                BrowserOpenExecutor.openOnMainActorIfNotCancelled(url) { NSWorkspace.shared.open($0) }
            }
        }
    }

    public init(opener: @escaping @Sendable (URL) async -> Bool) { self.opener = opener; self.exactOpener = nil }

    init(opener: @escaping @Sendable (URL) async -> Bool, exactOpener: @escaping @Sendable (URL) async -> Bool) {
        self.opener = opener
        self.exactOpener = exactOpener
    }

    @MainActor
    static func openOnMainActorIfNotCancelled(_ url: URL, opener: (URL) -> Bool) -> Bool {
        guard !Task.isCancelled else { return false }
        return opener(url)
    }

    public func execute(_ request: ToolRequest) async throws -> ToolResult {
        guard request.name == "browser_open", request.sideEffect == .externalSend,
              request.payload == "Open in browser", request.scope == nil,
              let url = BrowserOpenURL.validated(request.target) else { throw BrowserOpenError.invalidRequest }
        try Task.checkCancellation()
        guard await opener(url) else { throw BrowserOpenError.openFailed }
        return ToolResult(summary: "Browser open requested")
    }

    /// Internal path for targets recovered from an approved one-use ticket.
    func executeApprovedExact(_ request: ToolRequest, gate: ExactBrowserSessionGate, generation: UInt64) async throws -> ToolResult {
        guard request.name == "browser_open", request.sideEffect == .externalSend,
              request.payload == "Open in browser", request.scope == nil,
              let url = BrowserOpenURL.validatedExact(request.target) else { throw BrowserOpenError.invalidRequest }
        try Task.checkCancellation()
        guard let exactOpener else { throw BrowserOpenError.unavailable }
        let attempt = gate.pendingOpen(generation: generation)
        // Closing after the pending → started transition cannot revoke this
        // open. The async system API runs outside the lock and main actor.
        try gate.beginOpen(attempt)
        let opened = await exactOpener(url)
        guard opened else { throw BrowserOpenError.openFailed }
        return ToolResult(summary: "Browser open requested")
    }
}
