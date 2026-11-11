import Foundation

/// Identifying metadata for a future captured AX element; not itself an AX identity.
struct SafariClickIdentity: Equatable, Sendable {
    var pid: Int32
    var window: String
    var url: String
    var role: String
    var title: String
    var enabled: Bool
    var requestDigest: String
}

/// Preliminary in-memory authorization primitive; it does not perform AX actions.
actor SafariClickTicketStore {
    private var entries: [UUID: (SafariClickIdentity, TimeInterval)] = [:]
    func issue(identity: SafariClickIdentity, now: TimeInterval) -> UUID {
        let token = UUID()
        entries[token] = (identity, now + 60)
        return token
    }
    func consume(token: UUID, current: SafariClickIdentity, now: TimeInterval) -> Bool {
        guard let (original, expires) = entries.removeValue(forKey: token) else { return false }
        return now < expires && original == current && current.enabled
    }
}

#if os(macOS)
import ApplicationServices

/// Holds actual AX references in memory. The provider must inspect the focused
/// Safari window and return only candidates belonging to its current web area.
struct SafariClickCandidate: @unchecked Sendable {
    let element: AXUIElement
    let identity: SafariClickIdentity
}

actor SafariClickCapture {
    enum CaptureError: Error { case ambiguousOrMissing, changed }
    typealias Provider = @Sendable () async throws -> [SafariClickCandidate]
    private let provider: Provider
    private var captured: SafariClickCandidate?

    init(provider: @escaping Provider) { self.provider = provider }

    func capture(expected: SafariClickIdentity) async throws {
        let matches = try await provider().filter { $0.identity == expected && $0.identity.enabled }
        guard matches.count == 1 else { throw CaptureError.ambiguousOrMissing }
        captured = matches[0]
    }

    /// Re-observes both metadata and the retained AX identity. No action is performed.
    func verify(expected: SafariClickIdentity) async throws {
        guard let original = captured, original.identity == expected else { throw CaptureError.changed }
        let matches = try await provider().filter { $0.identity == expected && $0.identity.enabled }
        guard matches.count == 1, CFEqual(original.element, matches[0].element) else {
            captured = nil
            throw CaptureError.changed
        }
    }
}
#endif
