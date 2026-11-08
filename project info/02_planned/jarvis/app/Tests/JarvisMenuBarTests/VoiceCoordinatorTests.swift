import XCTest
@testable import JarvisMenuBar

@MainActor private final class FakeVoiceBackend: VoiceBackend {
    var isOnDeviceSupported = true
    var permissionGranted = true
    var started = false
    var stopped = false
    var handler: ((String) -> Void)?
    var failureHandler: ((String) -> Void)?
    var finishHandler: (() -> Void)?
    var deferPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    func requestPermission() async -> Bool {
        if deferPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return permissionGranted
    }
    func start(onText: @escaping (String) -> Void, onFailure: @escaping (String) -> Void, onFinish: @escaping () -> Void) throws { started = true; handler = onText; failureHandler = onFailure; finishHandler = onFinish }
    func stop() { stopped = true }
}

@MainActor final class VoiceCoordinatorTests: XCTestCase {
    func testUnsupportedDeviceNeverRequestsOrStarts() async {
        let backend = FakeVoiceBackend(); backend.isOnDeviceSupported = false
        let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        XCTAssertFalse(backend.started)
        XCTAssertNotNil(voice.errorMessage)
    }

    func testPermissionDeniedDoesNotStart() async {
        let backend = FakeVoiceBackend(); backend.permissionGranted = false
        let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        XCTAssertFalse(backend.started)
        XCTAssertNotNil(voice.errorMessage)
    }

    func testTranscriptRequiresManualSendAndStopReleases() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        XCTAssertTrue(voice.isRecording)
        backend.handler?("你好")
        XCTAssertEqual(voice.transcript, "你好")
        voice.stop()
        XCTAssertFalse(voice.isRecording)
        XCTAssertTrue(backend.stopped)
        backend.handler?("迟到结果")
        XCTAssertEqual(voice.transcript, "你好")
    }

    func testRecognizerFailureStopsAndShowsError() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        backend.failureHandler?("识别失败")
        XCTAssertTrue(backend.stopped)
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(voice.errorMessage, "识别失败")
    }

    func testFinalResultStopsRecording() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        backend.handler?("你好")
        backend.finishHandler?()
        XCTAssertEqual(voice.transcript, "你好")
        XCTAssertTrue(backend.stopped)
        XCTAssertFalse(voice.isRecording)
    }

    func testClosingDuringPermissionDoesNotStartRecording() async {
        let backend = FakeVoiceBackend(); backend.deferPermission = true
        let voice = VoiceCoordinator(backend: backend)
        let task = Task { await voice.start() }
        await Task.yield()
        XCTAssertNotNil(backend.permissionContinuation)
        voice.stop()
        backend.permissionContinuation?.resume(returning: true)
        await task.value
        XCTAssertFalse(backend.started)
        XCTAssertFalse(voice.isRecording)
    }
}
