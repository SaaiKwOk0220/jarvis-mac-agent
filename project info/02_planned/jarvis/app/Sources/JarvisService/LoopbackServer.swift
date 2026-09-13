import Foundation
import Network
import JarvisDomain

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

    public init(service: any TaskServiceAPI) {
        self.service = service
        encoder = JSONEncoder()
        decoder = JSONDecoder()
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
            if verb == "POST", parts.count == 3, parts[0] == "tasks", parts[2] == "cancel" {
                let id = parts[1]
                guard let taskID = UUID(uuidString: id) else { return error(status: 400, message: "invalid task id") }
                try await service.cancel(taskID: taskID)
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
        let listener = try NWListener(using: .tcp, on: .any)
        listener.parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        self.listener = listener
        let queue = DispatchQueue(label: "jarvis.loopback")
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try await Swift.Task.sleep(nanoseconds: 10_000_000)
        }
        listener.cancel()
        throw NSError(domain: "JarvisService", code: 1, userInfo: [NSLocalizedDescriptionKey: "loopback listener failed to start"])
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, case .ready = state else { return }
            let peer = connection.currentPath?.remoteEndpoint.flatMap { endpoint -> String? in
                if case let .hostPort(host, _) = endpoint { return "\(host)" }
                return nil
            } ?? ""
            guard Self.isLoopback(peer) else { connection.cancel(); return }
            self.receive(connection: connection, peerHost: peer)
        }
        connection.start(queue: DispatchQueue(label: "jarvis.loopback.connection"))
    }

    private func receive(connection: NWConnection, peerHost: String, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            var accumulated = buffer
            accumulated.append(data)
            guard accumulated.count <= 1_048_576 else { connection.cancel(); return }
            if !self.completeHTTPRequest(in: accumulated) {
                if self.headerIsMalformed(in: accumulated) {
                    let response = self.httpResponse(LoopbackResponse(status: 400))
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                self.receive(connection: connection, peerHost: peerHost, buffer: accumulated)
                return
            }
            Swift.Task {
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
        let firstLine = header.components(separatedBy: "\r\n").first ?? ""
        let first = firstLine.split(separator: " ")
        guard first.count >= 2 else { return httpResponse(LoopbackResponse(status: 400)) }
        let response = await handle(method: String(first[0]), path: String(first[1]), body: body, peerHost: peerHost)
        return httpResponse(response)
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

private struct APIError: Encodable {
    let message: String
}
