import AppKit
import Foundation
import SwiftUI
import XCTest
import JarvisDomain
@testable import JarvisMenuBar

private final class BlockAllPreviewNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@MainActor private final class PreviewVoiceBackend: VoiceBackend {
    var isOnDeviceSupported: Bool { false }
    func requestSpeechPermission() async -> Bool { false }
    func requestMicrophonePermission() async -> Bool { false }
    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable (Bool) -> Void, onSilence: @escaping @MainActor @Sendable () -> Void) throws { throw CancellationError() }
    func finish() {}
    func stop() {}
}

private actor PreviewTaskService: TaskServiceAPI {
    func createTask(title: String) async throws -> JarvisTask { throw TaskServiceCapabilityError.unavailable }
    func getTask(id: UUID) async throws -> JarvisTask? { throw TaskServiceCapabilityError.unavailable }
    func listTasks() async throws -> [JarvisTask] { throw TaskServiceCapabilityError.unavailable }
    func submit(request: ToolRequest) async throws -> PolicyDecision { throw TaskServiceCapabilityError.unavailable }
    func approve(requestID: UUID, digest: String) async throws { throw TaskServiceCapabilityError.unavailable }
    func reject(requestID: UUID) async throws { throw TaskServiceCapabilityError.unavailable }
    func cancel(taskID: UUID) async throws { throw TaskServiceCapabilityError.unavailable }
    func complete(taskID: UUID) async throws { throw TaskServiceCapabilityError.unavailable }
    func listPendingApprovalRequests(taskID: UUID) async throws -> [PendingApprovalRequest] { throw TaskServiceCapabilityError.unavailable }
    func listTimelineEvents(taskID: UUID) async throws -> [TimelineEvent] { throw TaskServiceCapabilityError.unavailable }
}

@MainActor
final class AskVisualPreviewTests: XCTestCase {
    func testRenderRealAskViewAtMultipleSizes() throws {
        #if JARVIS_COMBINED_EXPERIMENT || JARVIS_SAFARI_EXPERIMENT_BUILD
        throw XCTSkip("Experimental build checks accessibility state; preview uses the nonexperimental test target only.")
        #else
        guard Bundle.main.bundleURL.pathExtension != "app" else { throw XCTSkip("An app host may request notification permissions.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockAllPreviewNetwork.self]
        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:1")!, session: URLSession(configuration: configuration))
        let suite = "jarvis-preview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = AskJarvisView(client: client, service: PreviewTaskService(), voiceDraftStore: nil, memoryContextProvider: nil,
                                 voiceFactory: { VoiceCoordinator(backend: PreviewVoiceBackend()) })
            .defaultAppStorage(defaults)
            .disabled(true)
        for (name, width, height) in [("wide", 1440.0, 900.0), ("compact", 700.0, 800.0)] {
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-ask-preview-\(name)-\(UUID().uuidString).png")
            try VisualPreviewHarness.render(view, width: width, height: height, to: file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            print("JARVIS_PREVIEW_IMAGE: \(file.path)")
        }
        #endif
    }
}
