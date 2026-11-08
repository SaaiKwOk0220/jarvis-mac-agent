import Foundation

@MainActor protocol VoiceBackend: AnyObject {
    var isOnDeviceSupported: Bool { get }
    func requestPermission() async -> Bool
    func start(onText: @escaping (String) -> Void, onFailure: @escaping (String) -> Void, onFinish: @escaping () -> Void) throws
    func stop()
}

@MainActor final class VoiceCoordinator: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    private let backend: any VoiceBackend
    private var generation = 0

    init(backend: any VoiceBackend) { self.backend = backend }

    func start() async {
        guard !isRecording && !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        generation += 1
        let current = generation
        errorMessage = nil
        guard backend.isOnDeviceSupported else { errorMessage = "本机不支持离线中文语音识别。"; return }
        guard await backend.requestPermission() else { if current == generation { errorMessage = "需要麦克风和语音识别权限。" }; return }
        guard current == generation else { return }
        guard backend.isOnDeviceSupported else { errorMessage = "本机不支持离线中文语音识别。"; return }
        do {
            transcript = ""
            try backend.start { [weak self] text in
                guard let self, self.generation == current else { return }
                self.transcript = text
            } onFailure: { [weak self] message in
                guard let self, self.generation == current else { return }
                self.stop()
                self.errorMessage = message
            } onFinish: { [weak self] in
                guard let self, self.generation == current else { return }
                self.stop()
            }
            isRecording = true
        } catch {
            backend.stop()
            errorMessage = "无法启动离线语音识别：\(error.localizedDescription)"
        }
    }

    func stop() { generation += 1; backend.stop(); isRecording = false }
}
