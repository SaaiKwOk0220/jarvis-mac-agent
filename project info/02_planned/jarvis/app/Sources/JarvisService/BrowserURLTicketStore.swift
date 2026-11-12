import CryptoKit
import Foundation
import JarvisDomain

/// In-memory, expiring, one-use references to sensitive browser destinations.
public final class BrowserURLTicketStore: @unchecked Sendable {
    public struct Ticket: Sendable {
        public let id: UUID
        public let digest: String
        public init?(payload: String) {
            let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "ticket", let id = UUID(uuidString: String(parts[1])),
                  parts[2].count == 64, parts[2].allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
            self.id = id; self.digest = String(parts[2])
        }
        fileprivate init(id: UUID, digest: String) { self.id = id; self.digest = digest }
    }
    private struct Entry {
        let url: String
        let digest: String
        let expires: Date
        var taskID: UUID? = nil
        var requestID: UUID? = nil
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private let lifetime: TimeInterval
    var testEntryCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

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
        guard entry.digest == digest, entry.taskID == nil, entry.requestID == nil else { return nil }
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

    func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    public func revoke(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }

    /// Atomically bind a ticket to exactly one persisted request.
    public func bind(_ ticket: Ticket, taskID: UUID, requestID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[ticket.id], entry.digest == ticket.digest,
              Date() < entry.expires, entry.taskID == nil, entry.requestID == nil else { return false }
        entry.taskID = taskID; entry.requestID = requestID; entries[ticket.id] = entry
        return true
    }

    public func consumeBound(_ ticket: Ticket, taskID: UUID, requestID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[ticket.id], entry.digest == ticket.digest,
              entry.taskID == taskID, entry.requestID == requestID else { return nil }
        entries.removeValue(forKey: ticket.id)
        return Date() < entry.expires ? entry.url : nil
    }

    public func peekBound(_ ticket: Ticket, taskID: UUID, requestID: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[ticket.id], entry.digest == ticket.digest,
              entry.taskID == taskID, entry.requestID == requestID, Date() < entry.expires else { return nil }
        return entry.url
    }
}

public enum BrowserURLTicketError: Error { case invalidRequest }
