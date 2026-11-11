import AppKit
import Foundation
import JarvisDomain

public enum BrowserOpenError: Error { case invalidRequest, openFailed, unavailable }

/// Opens an approved HTTPS URL; no page contents are read or returned.
public struct BrowserOpenExecutor: ToolExecutor, Sendable {
    private let opener: @Sendable (URL) async -> Bool

    public init() {
        self.opener = { url in
            await MainActor.run {
                BrowserOpenExecutor.openOnMainActorIfNotCancelled(url) { NSWorkspace.shared.open($0) }
            }
        }
    }

    public init(opener: @escaping @Sendable (URL) async -> Bool) { self.opener = opener }

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
    func executeApprovedExact(_ request: ToolRequest) async throws -> ToolResult {
        guard request.name == "browser_open", request.sideEffect == .externalSend,
              request.payload == "Open in browser", request.scope == nil,
              let url = BrowserOpenURL.validatedExact(request.target) else { throw BrowserOpenError.invalidRequest }
        try Task.checkCancellation()
        guard await opener(url) else { throw BrowserOpenError.openFailed }
        return ToolResult(summary: "Browser open requested")
    }
}
