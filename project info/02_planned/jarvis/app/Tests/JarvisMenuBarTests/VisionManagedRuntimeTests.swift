import XCTest
import AppKit
import JarvisLLM
@testable import JarvisMenuBar

final class VisionManagedRuntimeTests: XCTestCase {
    func testConfigurationDisablesCloudAndUsesExplicitPrivateDirectories() throws {
        let config = try VisionManagedRuntime.Configuration(executable: URL(fileURLWithPath: "/usr/bin/true"),
            modelDirectory: FileManager.default.temporaryDirectory, scratchDirectory: FileManager.default.temporaryDirectory,
            port: 23456)
        XCTAssertEqual(config.environment["OLLAMA_HOST"], "127.0.0.1:23456")
        XCTAssertEqual(config.environment["OLLAMA_NO_CLOUD"], "1")
        XCTAssertEqual(config.environment["OLLAMA_NOPRUNE"], "1")
        XCTAssertNil(config.environment["HTTPS_PROXY"])
        XCTAssertTrue(config.sandboxProfile.contains("deny network-outbound"))
    }
    func testConfigurationRejectsNonExecutableAndInvalidPort() throws {
        let temp = FileManager.default.temporaryDirectory
        XCTAssertThrowsError(try VisionManagedRuntime.Configuration(executable: temp, modelDirectory: temp, scratchDirectory: temp, port: 23456))
        XCTAssertThrowsError(try VisionManagedRuntime.Configuration(executable: URL(fileURLWithPath: "/usr/bin/true"), modelDirectory: temp, scratchDirectory: temp, port: 0))
    }

    @MainActor
    func testMissingModelNeverStartsExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = VisionManagedRuntime(modelDirectory: directory)
        do {
            _ = try await runtime.start(executable: URL(fileURLWithPath: "/usr/bin/true"))
            XCTFail("missing model must not start service")
        } catch VisionManagedRuntime.RuntimeError.modelMissing { }
    }

    @MainActor
    func testPreCancelledStartDoesNotBegin() async throws {
        let runtime = VisionManagedRuntime(modelDirectory: FileManager.default.temporaryDirectory)
        let task = Task { @MainActor in try await runtime.start(executable: URL(fileURLWithPath: "/usr/bin/true")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled request must not start") }
        catch is CancellationError { }
    }

    @MainActor
    func testOwnServiceStartsAndStopsWithoutStoppingSibling() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_TEST_SANDBOX_EXEC"] == "1" else { throw XCTSkip("requires isolated sandbox and loopback permission") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = root.appendingPathComponent("models")
        let manifest = models.appendingPathComponent("manifests/registry.ollama.ai/library/qwen2.5vl/3b")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: manifest)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("fake-ollama")
        let script = """
        #!/bin/sh
        exec /usr/bin/python3 -u -c 'import os,socket,time; h,p=os.environ["OLLAMA_HOST"].split(":"); s=socket.socket(); s.bind((h,int(p))); s.listen(); print("Listening on " + h + ":" + p + " (fixture)", flush=True); time.sleep(30)'
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let sibling = Process(); sibling.executableURL = URL(fileURLWithPath: "/bin/sleep"); sibling.arguments = ["30"]
        try sibling.run()
        defer { if sibling.isRunning { sibling.terminate() }; sibling.waitUntilExit() }
        let runtime = VisionManagedRuntime(modelDirectory: models)
        let endpoint = try await runtime.start(executable: helper)
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertTrue(sibling.isRunning)
        runtime.stop()
        XCTAssertTrue(sibling.isRunning)
    }

    @MainActor
    func testEarlyExitDoesNotReportReady() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_TEST_SANDBOX_EXEC"] == "1" else { throw XCTSkip("requires isolated sandbox and loopback permission") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("manifests/registry.ollama.ai/library/qwen2.5vl/3b")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: manifest)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = VisionManagedRuntime(modelDirectory: root)
        do {
            _ = try await runtime.start(executable: URL(fileURLWithPath: "/usr/bin/true"))
            XCTFail("exited process must not report ready")
        } catch { }
    }

    @MainActor
    func testStoppingProcessRemainsTrackedUntilExit() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_TEST_SANDBOX_EXEC"] == "1" else { throw XCTSkip("requires isolated sandbox and loopback permission") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = root.appendingPathComponent("models/manifests/registry.ollama.ai/library/qwen2.5vl/3b")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: manifest)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("delayed-stop")
        let script = """
        #!/bin/sh
        exec /usr/bin/python3 -u -c 'import os,socket,time,signal; signal.signal(signal.SIGTERM,lambda *_:None); h,p=os.environ["OLLAMA_HOST"].split(":"); s=socket.socket(); s.bind((h,int(p))); s.listen(); print("Listening on " + h + ":" + p + " (fixture)", flush=True); time.sleep(2)'
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runtime = VisionManagedRuntime(modelDirectory: root.appendingPathComponent("models"))
        _ = try await runtime.start(executable: helper)
        runtime.stop()
        do {
            _ = try await runtime.start(executable: helper)
            XCTFail("must not start another process until the first exits")
        } catch VisionManagedRuntime.RuntimeError.alreadyStarted { }
        try await Task.sleep(for: .seconds(3))
    }

    @MainActor
    func testOptInRealLocalVisionModelWithSyntheticImage() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_TEST_REAL_OLLAMA"] == "1" else { throw XCTSkip("requires opted-in local model and sandbox permission") }
        let runtime = VisionManagedRuntime()
        defer { runtime.stop() }
        let endpoint = try await runtime.start(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ollama"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let service = try OllamaVisionService(baseURL: endpoint, model: "qwen2.5vl:3b")
        let answer = try await service.describe(VisionRequest(prompt: "Describe this test image briefly.", image: image))
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
