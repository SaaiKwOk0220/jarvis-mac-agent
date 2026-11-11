import CryptoKit
import Foundation
import JarvisDomain

/// In-memory, expiring, one-use references to sensitive browser destinations.
public final class BrowserURLTicketStore: @unchecked Sendable {
    public struct Ticket: Sendable {
        public let id: UUID
        public let digest: String
    }
    private struct Entry {
        let url: String
        let digest: String
        let expires: Date
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 300) { self.lifetime = max(0, lifetime) }

    public func issue(url: String, now: Date = Date()) -> Ticket {
        let id = UUID()
        let digest = SHA256.hash(data: Data("\(id.uuidString):\(url)".utf8)).map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        entries[id] = Entry(url: url, digest: digest, expires: now.addingTimeInterval(lifetime))
        return Ticket(id: id, digest: digest)
    }

    public func peek(id: UUID, digest: String, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id], now < entry.expires, entry.digest == digest else { return nil }
        return entry.url
    }

    public func consume(id: UUID, digest: String, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id] else { return nil }
        guard now < entry.expires else { entries.removeValue(forKey: id); return nil }
        guard entry.digest == digest else { return nil }
        entries.removeValue(forKey: id)
        return entry.url
    }

    /// Produces a request containing only the destination origin and ticket metadata.
    public func persistableRequest(_ request: ToolRequest, ticket: Ticket) throws -> ToolRequest {
        guard request.name == "browser_open", request.sideEffect == .externalSend,
              request.payload == "Open in browser", request.scope == nil,
              peek(id: ticket.id, digest: ticket.digest) == request.target,
              let parts = URLComponents(string: request.target), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.host else { throw BrowserURLTicketError.invalidRequest }
        let origin = "https://\(host)" + (parts.port.map { ":\($0)" } ?? "")
        guard BrowserOpenURL.validated(origin) != nil else { throw BrowserURLTicketError.invalidRequest }
        return ToolRequest(id: request.id, taskID: request.taskID, name: request.name,
                           sideEffect: request.sideEffect, target: origin,
                           payload: "ticket:\(ticket.id.uuidString):\(ticket.digest)")
    }

    public func revoke(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }
}

public enum BrowserURLTicketError: Error { case invalidRequest }
