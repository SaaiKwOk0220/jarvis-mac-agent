import Foundation
import Darwin

/// Opt-in helper for a trusted local executable; it does not authenticate local peers.
@MainActor
final class VisionManagedRuntime {
    enum RuntimeError: Error {
        case invalidConfiguration, modelMissing, alreadyStarted, unavailable, cancelled
    }

    struct Configuration {
        let executable: URL
        let environment: [String: String]
        let sandboxProfile = "(version 1)(allow default)(deny network-outbound (require-not (remote ip \"localhost:*\")))"

        init(executable: URL, modelDirectory: URL, scratchDirectory: URL, port: Int) throws {
            let executable = executable.standardizedFileURL.resolvingSymlinksInPath()
            let models = modelDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let scratch = scratchDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let manager = FileManager.default
            guard (1...65535).contains(port),
                  let attributes = try? manager.attributesOfItem(atPath: executable.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  manager.isExecutableFile(atPath: executable.path),
                  let modelAttributes = try? manager.attributesOfItem(atPath: models.path),
                  modelAttributes[.type] as? FileAttributeType == .typeDirectory,
                  let scratchAttributes = try? manager.attributesOfItem(atPath: scratch.path),
                  scratchAttributes[.type] as? FileAttributeType == .typeDirectory else { throw RuntimeError.invalidConfiguration }
            self.executable = executable
            environment = ["HOME": manager.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": scratch.path,
                "OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_MODELS": models.path,
                "OLLAMA_NO_CLOUD": "1", "OLLAMA_NOPRUNE": "1", "OLLAMA_NOHISTORY": "1"]
        }
    }

    static var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis/vision-ollama/models", isDirectory: true)
    }

    private var process: Process?
    private var pipe: Pipe?
    private var generation = UUID()
    private var buffer = ""
    private var ready = false
    private let models: URL

    init(modelDirectory: URL = VisionManagedRuntime.modelDirectory) {
        self.models = modelDirectory
    }

    deinit {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let child = process, child.isRunning { child.terminate() }
    }

    /// Starts only the explicitly trusted executable, using the Jarvis-owned model store.
    /// The random port is not a security identity; local peer processes remain trusted.
    func start(executable: URL) async throws -> URL {
        try Task.checkCancellation()
        guard process == nil else { throw RuntimeError.alreadyStarted }
        let manifest = models.appendingPathComponent("manifests/registry.ollama.ai/library/qwen2.5vl/3b")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw RuntimeError.modelMissing }
        let (descriptor, port) = try Self.reservePort()
        var reservation = descriptor
        defer { if reservation >= 0 { close(reservation) } }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-ollama-\(UUID().uuidString)", isDirectory: true)
        let current = UUID()
        var started = false
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let config = try Configuration(executable: executable, modelDirectory: models, scratchDirectory: scratch, port: port)
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            child.arguments = ["-p", config.sandboxProfile, config.executable.path, "serve"]
            child.environment = config.environment
            child.standardOutput = output; child.standardError = output
            generation = current; buffer = ""; ready = false
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.consume(data, token: current, port: port) }
            }
            child.terminationHandler = { [weak self] exited in
                try? FileManager.default.removeItem(at: scratch)
                Task { @MainActor in self?.processExited(exited) }
            }
            // The reservation cannot be inherited by Ollama; there is a short,
            // documented bind race. A competing listener is not trusted.
            try Task.checkCancellation()
            close(reservation); reservation = -1
            do { try child.run() } catch {
                output.fileHandleForReading.readabilityHandler = nil
                throw RuntimeError.unavailable
            }
            started = true; process = child; pipe = output
            for _ in 0..<150 {
                try Task.checkCancellation()
                guard generation == current else { throw RuntimeError.cancelled }
                guard child.isRunning else { throw RuntimeError.unavailable }
                if ready { return URL(string: "http://127.0.0.1:\(port)")! }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RuntimeError.unavailable
        } catch {
            if generation == current { stop() }
            if !started { try? FileManager.default.removeItem(at: scratch) }
            throw error
        }
    }

    func stop() {
        generation = UUID(); ready = false; buffer = ""
        pipe?.fileHandleForReading.readabilityHandler = nil; pipe = nil
        if let child = process {
            if child.isRunning { child.terminate() }
            else { process = nil }
        }
    }

    private func consume(_ data: Data, token: UUID, port: Int) {
        guard generation == token, !ready else { return }
        buffer += String(decoding: data, as: UTF8.self)
        if buffer.count > 16_384 { buffer = String(buffer.suffix(16_384)) }
        if buffer.contains("Listening on 127.0.0.1:\(port) ") { ready = true; buffer = "" }
    }

    private func processExited(_ child: Process) {
        guard process === child else { return }
        pipe?.fileHandleForReading.readabilityHandler = nil; pipe = nil
        process = nil; ready = false
    }

    private static func reservePort() throws -> (Int32, Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeError.unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(descriptor); throw RuntimeError.unavailable }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard result == 0 else { close(descriptor); throw RuntimeError.unavailable }
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }
}
