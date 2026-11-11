import Foundation
import CryptoKit
import Security
import Network
import JarvisDomain
import JarvisPolicy

public struct LoopbackResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

/// JSON route handler for the process-local API. The transport must supply its peer address.
public final class LoopbackServer: @unchecked Sendable {
    private let service: any TaskServiceAPI
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var listener: NWListener?
    private let connectionQueue = DispatchQueue(label: "jarvis.loopback.connections")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiving: Set<ObjectIdentifier> = []
    private let connectionLimit = 32
    /// Process-local secret; never include in URLs, logs, or persisted state.
    public let authorizationToken: String?
    private let expectedAuthenticationCode: HMAC<SHA256>.MAC?
    private static let authenticationMessage = Data("jarvis-loopback-v1".utf8)

    public convenience init(service: any TaskServiceAPI) {
        self.init(service: service, tokenProvider: Self.makeAuthorizationToken)
    }

    // The injectable provider is internal so tests can verify entropy failure is fail-closed.
    init(service: any TaskServiceAPI, tokenProvider: () -> String?) {
        self.service = service
        let candidate = tokenProvider()
        let token = candidate.flatMap { value -> String? in
            guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return value
        }
        self.authorizationToken = token
        self.expectedAuthenticationCode = token.map {
            HMAC<SHA256>.authenticationCode(for: Self.authenticationMessage, using: SymmetricKey(data: Data($0.utf8)))
        }
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    private static func makeAuthorizationToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func handle(method: String, path: String, body: Data, peerHost: String) async -> LoopbackResponse {
        guard Self.isLoopback(peerHost) else {
            return error(status: 403, message: "loopback peers only")
        }
        do {
            let parts = path.split(separator: "/").map(String.init)
            let verb = method.uppercased()
            if verb == "POST", parts == ["tasks"] {
                let input = try decoder.decode(CreateTaskRequest.self, from: body)
                let task = try await service.createTask(title: input.title)
                return try response(status: 201, value: task)
            }
            if verb == "GET", parts == ["tasks"] {
                return try response(status: 200, value: await service.listTasks())
            }
            if verb == "GET", parts.count == 2, parts[0] == "tasks" {
                let id = parts[1]
                guard let taskID = UUID(uuidString: id) else { return error(status: 400, message: "invalid task id") }
                guard let task = try await service.getTask(id: taskID) else { return error(status: 404, message: "task not found") }
                return try response(status: 200, value: task)
            }
            if verb == "GET", parts.count == 3, parts[0] == "tasks", parts[2] == "requests" {
                guard let taskID = UUID(uuidString: parts[1]) else { return error(status: 400, message: "invalid task id") }
                return try response(status: 200, value: await service.listPendingApprovalRequests(taskID: taskID))
            }
            if verb == "GET", parts.count == 3, parts[0] == "tasks", parts[2] == "timeline" {
                guard let taskID = UUID(uuidString: parts[1]) else { return error(status: 400, message: "invalid task id") }
                return try response(status: 200, value: await service.listTimelineEvents(taskID: taskID))
            }
            if verb == "POST", parts.count == 3, parts[0] == "tasks", parts[2] == "demo-approval" {
                guard let taskID = UUID(uuidString: parts[1]) else { return error(status: 400, message: "invalid task id") }
                guard let demoService = service as? any DemoTaskServiceAPI else { return error(status: 404, message: "demo executor unavailable") }
                try await demoService.submitDemoApproval(taskID: taskID)
                return LoopbackResponse(status: 204)
            }
            if verb == "POST", parts.count == 3, parts[0] == "tasks", parts[2] == "requests" {
                guard let taskID = UUID(uuidString: parts[1]) else { return error(status: 400, message: "invalid task id") }
                let input = try decoder.decode(ToolRequest.self, from: body)
                // Force taskID from URL so a client cannot accidentally target
                // the wrong task by sending a mismatched body.
                let request = ToolRequest(
                    id: input.id,
                    taskID: taskID,
                    name: input.name,
                    sideEffect: input.sideEffect,
                    target: input.target,
                    payload: input.payload,
                    scope: input.scope
                )
                let decision = try await service.submit(request: request)
                return try response(status: 200, value: SubmitResponse(decision: decision))
            }
            if verb == "POST", parts.count == 3, parts[0] == "tasks", parts[2] == "cancel" {
                let id = parts[1]
                guard let taskID = UUID(uuidString: id) else { return error(status: 400, message: "invalid task id") }
                try await service.cancel(taskID: taskID)
                return LoopbackResponse(status: 204)
            }
            if verb == "POST", parts.count == 3, parts[0] == "tasks", parts[2] == "complete" {
                let id = parts[1]
                guard let taskID = UUID(uuidString: id) else { return error(status: 400, message: "invalid task id") }
                try await service.complete(taskID: taskID)
                return LoopbackResponse(status: 204)
            }
            if verb == "POST", parts.count == 3, parts[0] == "requests", parts[2] == "approve" {
                let id = parts[1]
                guard let requestID = UUID(uuidString: id) else { return error(status: 400, message: "invalid request id") }
                let input = try decoder.decode(ApprovalRequest.self, from: body)
                try await service.approve(requestID: requestID, digest: input.digest)
                return LoopbackResponse(status: 204)
            }
            if verb == "POST", parts.count == 3, parts[0] == "requests", parts[2] == "reject" {
                let id = parts[1]
                guard let requestID = UUID(uuidString: id) else { return error(status: 400, message: "invalid request id") }
                try await service.reject(requestID: requestID)
                return LoopbackResponse(status: 204)
            }
            return error(status: 404, message: "route not found")
        } catch is DecodingError {
            return self.error(status: 400, message: "invalid JSON")
        } catch let serviceError as TaskServiceError {
            switch serviceError {
            case .taskNotFound, .requestNotFound:
                return self.error(status: 404, message: "resource not found")
            case .approvalDigestMismatch, .requestNotAwaitingApproval, .illegalTransition, .incompatiblePersistence:
                return self.error(status: 409, message: "request cannot be completed")
            }
        } catch {
            return self.error(status: 500, message: "service error")
        }
    }

    public static func isLoopback(_ peerHost: String) -> Bool {
        let host = peerHost.lowercased()
        return host == "127.0.0.1" || host == "::1" || host == "localhost" || host == "::ffff:127.0.0.1"
    }

    /// Starts a small HTTP/JSON listener bound only to 127.0.0.1.
    public func start() async throws -> UInt16 {
        guard authorizationToken != nil else { throw NSError(domain: "JarvisService", code: 2, userInfo: [NSLocalizedDescriptionKey: "secure token generation failed"]) }
        let listener = try NWListener(using: .tcp, on: .any)
        listener.parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        self.listener = listener
        listener.start(queue: connectionQueue)
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        listener.cancel()
        throw NSError(domain: "JarvisService", code: 1, userInfo: [NSLocalizedDescriptionKey: "loopback listener failed to start"])
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connectionQueue.sync {
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            receiving.removeAll()
        }
    }

    private func handle(connection: NWConnection) {
        guard connections.count < connectionLimit else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        receiving.insert(id)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .cancelled, .failed:
                self.connections.removeValue(forKey: id)
                self.receiving.remove(id)
            case .ready:
                let peer = connection.currentPath?.remoteEndpoint.flatMap { endpoint -> String? in
                    if case let .hostPort(host, _) = endpoint { return "\(host)" }
                    return nil
                } ?? ""
                guard Self.isLoopback(peer) else { connection.cancel(); return }
                self.receive(connection: connection, peerHost: peer)
            default: break
            }
        }
        connection.start(queue: connectionQueue)
        connectionQueue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.receiving.contains(id) else { return }
            connection.cancel()
        }
    }

    private func receive(connection: NWConnection, peerHost: String, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            var accumulated = buffer
            accumulated.append(data)
            guard accumulated.count <= 1_048_576 else { connection.cancel(); return }
            if let end = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: accumulated[..<end.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                let auth = lines.dropFirst().compactMap { line -> String? in
                    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" else { return nil }
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
                guard auth.count == 1, self.isAuthorized(auth[0]) else {
                    connection.send(content: self.httpResponse(LoopbackResponse(status: 403)), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            } else if accumulated.count > 32_768 { connection.cancel(); return }
            if !self.completeHTTPRequest(in: accumulated) {
                if self.headerIsMalformed(in: accumulated) {
                    let response = self.httpResponse(LoopbackResponse(status: 400))
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                self.receive(connection: connection, peerHost: peerHost, buffer: accumulated)
                return
            }
            self.receiving.remove(ObjectIdentifier(connection))
            Task {
                let response = await self.handleHTTP(data: accumulated, peerHost: peerHost)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func completeHTTPRequest(in data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), let separator = text.range(of: "\r\n\r\n") else {
            return false
        }
        let headers = String(text[..<separator.lowerBound])
        let headerLines = headers.split(separator: "\r\n")
        guard headerLines.count <= 100, headers.utf8.count <= 32_768 else { return false }
        guard !headerLines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else { return false }
        let values = headerLines.filter { $0.lowercased().hasPrefix("content-length:") }
        guard values.count <= 1 else { return false }
        let contentLength: Int
        if let line = values.first {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2, let parsed = Int(fields[1].trimmingCharacters(in: .whitespaces)), parsed >= 0, parsed <= 1_048_576 else { return false }
            contentLength = parsed
        } else { contentLength = 0 }
        let headerByteCount = Array(text[..<separator.lowerBound].utf8).count
        return data.count <= 1_048_576 && data.count >= headerByteCount + 4 + contentLength
    }

    private func headerIsMalformed(in data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), let separator = text.range(of: "\r\n\r\n") else { return false }
        let headers = String(text[..<separator.lowerBound])
        let lines = headers.split(separator: "\r\n")
        guard lines.count <= 100, headers.utf8.count <= 32_768 else { return true }
        if lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) { return true }
        let values = lines.filter { $0.lowercased().hasPrefix("content-length:") }
        guard values.count <= 1 else { return true }
        guard let line = values.first else { return false }
        let fields = line.split(separator: ":", maxSplits: 1)
        guard fields.count == 2, let parsed = Int(fields[1].trimmingCharacters(in: .whitespaces)), parsed >= 0, parsed <= 1_048_576 else { return true }
        return false
    }

    private func handleHTTP(data: Data, peerHost: String) async -> Data {
        guard let text = String(data: data, encoding: .utf8), let separator = text.range(of: "\r\n\r\n") else {
            return httpResponse(LoopbackResponse(status: 400))
        }
        let header = String(text[..<separator.lowerBound])
        let body = Data(text[separator.upperBound...].utf8)
        guard body.count <= 1_048_576 else { return httpResponse(LoopbackResponse(status: 400)) }
        let lines = header.components(separatedBy: "\r\n")
        func values(_ name: String) -> [String] {
            lines.dropFirst().compactMap { line -> String? in
                let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { return nil }
                return fields[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let port = listener?.port?.rawValue,
              values("host") == ["127.0.0.1:\(port)"],
              values("origin").isEmpty else { return httpResponse(LoopbackResponse(status: 403)) }
        let contentLengths = values("content-length")
        guard contentLengths.count <= 1,
              (contentLengths.first.flatMap(Int.init) ?? 0) == body.count else { return httpResponse(LoopbackResponse(status: 400)) }
        let authorization = values("authorization")
        guard authorization.count == 1, isAuthorized(authorization[0]) else { return httpResponse(LoopbackResponse(status: 403)) }
        if !body.isEmpty {
            let contentTypes = values("content-type")
            guard contentTypes.count == 1,
                  contentTypes[0].split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { return httpResponse(LoopbackResponse(status: 403)) }
        }
        let firstLine = lines.first ?? ""
        let first = firstLine.split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0", first[1].hasPrefix("/") else { return httpResponse(LoopbackResponse(status: 400)) }
        let response = await handle(method: String(first[0]), path: String(first[1]), body: body, peerHost: peerHost)
        return httpResponse(response)
    }

    private func isAuthorized(_ value: String) -> Bool {
        guard value.hasPrefix("Bearer "), let expectedAuthenticationCode else { return false }
        let token = String(value.dropFirst("Bearer ".count))
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        let candidateCode = HMAC<SHA256>.authenticationCode(for: Self.authenticationMessage, using: SymmetricKey(data: Data(token.utf8)))
        // CryptoKit's authentication-code equality uses constant-time comparison.
        return expectedAuthenticationCode == candidateCode
    }

    private func httpResponse(_ response: LoopbackResponse) -> Data {
        let reason = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"][response.status] ?? "Error"
        let text = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        var result = Data(text.utf8)
        result.append(response.body)
        return result
    }

    private func response<T: Encodable>(status: Int, value: T) throws -> LoopbackResponse {
        LoopbackResponse(status: status, body: try encoder.encode(value))
    }

    private func error(status: Int, message: String) -> LoopbackResponse {
        let body = (try? encoder.encode(APIError(message: message))) ?? Data()
        return LoopbackResponse(status: status, body: body)
    }
}

private struct CreateTaskRequest: Decodable {
    let title: String
}

private struct ApprovalRequest: Decodable {
    let digest: String
}

private struct SubmitResponse: Codable, Sendable {
    let decision: PolicyDecision
}

private struct APIError: Encodable {
    let message: String
}
