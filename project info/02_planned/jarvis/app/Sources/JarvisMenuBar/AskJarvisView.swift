import SwiftUI
import AVFoundation
import JarvisDomain
import JarvisLLM

/// One line in the Ask Jarvis progress log.
struct AgentLogEntry: Identifiable, Equatable {
    /// What kind of loop step the line reports; drives its colour and prefix.
    enum Kind: Equatable {
        case info
        case assistant
        case toolCall
        case result
        case denied
        case approval
        case error
    }

    let id: UUID
    let kind: Kind
    let text: String

    init(kind: Kind, text: String) {
        self.id = UUID()
        self.kind = kind
        self.text = text
    }

    /// Renders one loop event as a log line, so the view layer only has to
    /// append what the loop reports.
    init(event: AgentLoopEvent) {
        switch event {
        case .assistantText(let text):
            self.init(kind: .assistant, text: "Assistant: \(text)")
        case .toolCallRequested(let call) where call.name == "safari_read":
            self.init(kind: .info, text: "Switch to the intended Safari window within 15 seconds to preview the exact URL before approval.")
        case .toolCallRequested(let call) where call.name == "browser_open":
            let parts = call.arguments["url"].flatMap { URLComponents(string: $0) }
            let origin = parts.flatMap { component -> String? in
                guard component.scheme == "https", let host = component.host else { return nil }
                return "https://\(host)" + (component.port.map { ":\($0)" } ?? "")
            } ?? "[REDACTED]"
            self.init(kind: .toolCall, text: "Tool call: browser_open(\(origin))")
        case .toolCallRequested(let call):
            let arguments = call.arguments
                .sorted { $0.key < $1.key }
                .map { "\"\($0.key)\": \"\($0.value)\"" }
                .joined(separator: ", ")
            self.init(kind: .toolCall, text: "Tool call: \(call.name)({\(arguments)})")
        case .toolCallSucceeded(let name, _) where name == "safari_read":
            self.init(kind: .result, text: "Safari page text will be provided to the model on continuation and may remain in conversation history; content is not shown here.")
        case .toolCallSucceeded(let name, let observation):
            self.init(kind: .result, text: "Result (\(name)): \(Self.abbreviated(observation))")
        case .toolCallDenied(let name, let reason):
            self.init(kind: .denied, text: "Denied (\(name)): \(reason)")
        case .awaitingApproval(_, let description):
            self.init(kind: .approval, text: "Needs approval: \(description)")
        }
    }

    /// Keeps one chatty tool result from flooding the window.
    private static func abbreviated(_ text: String, limit: Int = 400) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "… (truncated)"
    }
}

/// Main-actor log of one Ask Jarvis run. Events arrive on whatever executor the
/// loop runs on, so they are funnelled through this object rather than written
/// into view state directly.
@MainActor
final class AgentRunLog: ObservableObject {
    @Published private(set) var entries: [AgentLogEntry] = []

    func reset() { entries = [] }
    func append(_ entry: AgentLogEntry) { entries.append(entry) }

    /// Assistant text is already emitted as an event; outcomes add status only.
    func recordOutcome(_ result: AgentLoopResult) {
        switch result {
        case .completed:
            append(AgentLogEntry(kind: .info, text: "Run complete."))
        case .awaitingApproval(_, let description):
            append(AgentLogEntry(kind: .approval, text: "Paused for your approval: \(description). Open the task in the Jarvis menu to approve or reject it."))
        case .failed(let reason):
            append(AgentLogEntry(kind: .error, text: "Tool failed: \(reason)"))
        case .cancelled:
            append(AgentLogEntry(kind: .info, text: "Run cancelled."))
        case .approvalTimedOut:
            append(AgentLogEntry(kind: .error, text: "Approval timed out."))
        case .exceededIterations:
            append(AgentLogEntry(kind: .error, text: "Stopped after reaching the iteration limit. Try a narrower goal."))
        }
    }
}

enum VoiceWorkspaceLayout {
    static func usesWideLayout(width: CGFloat) -> Bool { width.isFinite && width >= 950 }
}

enum VoiceInterfaceStatus {
    static func label(recording: Bool, running: Bool, speaking: Bool) -> String {
        if recording { return "聆听中" }; if running { return "任务进行中" }; if speaking { return "朗读中" }; return "待命"
    }
}

/// "Ask Jarvis" window: type a goal, and the agent loop plans against Ollama
/// and runs each tool call through `TaskService`.
///
/// The loop has no privileged path — every call it makes goes through the same
/// policy gate and approval queue as a hand-submitted task, so a tool the
/// policy wants a human to approve pauses the run and waits in the task-detail
/// window instead of executing.
struct AskJarvisView: View {
    @ObservedObject var client: ServiceClient
    /// The live service, or `nil` when the app failed to start one. The view
    /// needs the real instance rather than the HTTP client so it can hand it
    /// to `TaskServiceToolRunner`.
    let service: (any TaskServiceAPI)?
    var voiceDraftStore: VoiceDraftStore?
    /// Optional snapshot of the user's memory. When non-nil, the agent loop
    /// reads the current memory context as a second system prompt at the
    /// start of every run; when nil, the loop runs without that context.
    let memoryContextProvider: (@Sendable () async -> String)?

    init(client: ServiceClient, service: (any TaskServiceAPI)?, voiceDraftStore: VoiceDraftStore?, memoryContextProvider: (@Sendable () async -> String)?) {
        self.client = client
        self.service = service
        self.voiceDraftStore = voiceDraftStore
        self.memoryContextProvider = memoryContextProvider
    }

    @StateObject private var log = AgentRunLog()
    @StateObject private var voice = VoiceCoordinator(backend: OnDeviceSpeechBackend(), speaker: SystemVoiceSpeaker())
    @StateObject private var autoSubmit = VoiceAutoSubmitGate()
    @StateObject private var conversation = VoiceConversationSession()
    @StateObject private var runLifecycle = VoiceRunLifecycle()
    @State private var lastAnswer = ""
    @State private var goal = ""
    @State private var savedVoiceDrafts: [VoiceDraft] = []
    @State private var activeVoiceDraftID: String?
    @State private var restoredVoiceDraftID: String?
    @State private var containsVoiceInput = false
    @State private var draftStoreError: String?
    @State private var voiceDraftPrefix = VoiceDraftPrefix(draft: "")
    @State private var isRunning = false
    @State private var runningTaskID: UUID?
    @State private var run: Task<Void, Never>?
    @State private var activeRunToken: Int?
    @State private var activeSubmittedGoal: String?
    @State private var isVisible = false
    @State private var voiceWillAutoSubmit = false
    @State private var followLatest = false
    @State private var showVoiceDiagnostics = false
    @State private var modelDiagnostic: OllamaDiagnostic?
    @State private var checkingModel = false
    @State private var voiceDiagnostic: VoiceDiagnosticSnapshot?
    @State private var voiceDiagnosticReason: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var haloExpanded = false
    @AppStorage(VoiceEndpointSettings.pauseKey) private var pauseSeconds = VoiceEndpointSettings.defaultPause
    @AppStorage(VoiceEndpointSettings.maxRecordingKey) private var maxRecordingSeconds = VoiceEndpointSettings.defaultMaximum
    @AppStorage("jarvis.voice.optionalVAD") private var optionalVADEnabled = false
    #if JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT
    @State private var accessibilityRequestResult: Bool?
    @State private var accessibilityTrusted = AccessibilityPermissionRequest.isTrusted()
    #endif
    @AppStorage(VoicePlaybackSettings.voiceKey) private var selectedVoiceID = ""
    @AppStorage(VoicePlaybackSettings.rateKey) private var voiceRate = 0.5

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    if VoiceWorkspaceLayout.usesWideLayout(width: geometry.size.width) {
                        HStack(alignment: .top, spacing: 16) {
                            conversationPanel
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(16)
                                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                            dashboardCore
                                .frame(width: min(geometry.size.width * 0.30, 360))
                            VStack(alignment: .leading, spacing: 20) {
                                Text("控制与设置").font(.headline)
                                composerDetails
                                settingsPanel
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                        }.padding(20)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            voiceCore
                            conversationPanel
                            composerDetails
                            settingsPanel
                        }.padding(16)
                    }
                }
            }
            Divider()
            VStack(spacing: 8) { composer; controlsBar }.padding(.horizontal, 24).padding(.vertical, 12)
                .background(Color.black.opacity(0.45))
        }
        .background(LinearGradient(colors: [Color(red: 0.025, green: 0.055, blue: 0.09), Color(red: 0.015, green: 0.025, blue: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
        .onAppear { isVisible = true; refreshVoiceDrafts() }
        .onChange(of: voice.errorMessage) { _, message in
            if message != nil { conversation.stop(); autoSubmit.cancel() }
        }
        .task(id: showVoiceDiagnostics) {
            voice.setDiagnosticsEnabled(showVoiceDiagnostics)
            guard showVoiceDiagnostics else { voiceDiagnostic = nil; voiceDiagnosticReason = nil; return }
            while !Task.isCancelled {
                voiceDiagnostic = voice.diagnosticSnapshot()
                voiceDiagnosticReason = voice.diagnosticReason
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { isVisible = false; runLifecycle.invalidate(); stopConversation(); voice.clearDiagnostics(); voiceDiagnostic = nil; voiceDiagnosticReason = nil; showVoiceDiagnostics = false }
    }

    private var dashboardCore: some View {
        VStack(spacing: 16) {
            Text("JARVIS").font(.system(size: 26, weight: .ultraLight, design: .rounded)).tracking(7)
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    for index in 0..<64 {
                        let angle = Double(index) * .pi * 2 / 64
                        let radius = 104.0 + Double((index * 17) % 19)
                        let point = CGPoint(x: center.x + cos(angle) * radius,
                                            y: center.y + sin(angle) * radius)
                        let diameter = index.isMultiple(of: 5) ? 3.0 : 1.5
                        context.fill(Path(ellipseIn: CGRect(x: point.x, y: point.y, width: diameter, height: diameter)),
                                     with: .color(.cyan.opacity(index.isMultiple(of: 3) ? 0.8 : 0.4)))
                    }
                }
                .frame(width: 260, height: 260)
                .rotationEffect(.degrees(haloExpanded ? 180 : 0))
                Circle().stroke(.cyan.opacity(0.15), lineWidth: 1).frame(width: 230, height: 230)
                Circle().trim(from: 0.03, to: 0.87)
                    .stroke(.cyan.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 200, height: 200).rotationEffect(.degrees(haloExpanded ? 180 : 0))
                Circle().trim(from: 0.12, to: 0.94)
                    .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .frame(width: 166, height: 166).rotationEffect(.degrees(haloExpanded ? -180 : 0))
                Circle().fill(RadialGradient(colors: [.cyan.opacity(0.30), .cyan.opacity(0.02)], center: .center, startRadius: 5, endRadius: 80))
                    .frame(width: 150, height: 150)
                Image(systemName: voice.isRecording ? "waveform" : (voice.isSpeaking ? "speaker.wave.2.fill" : "sparkles"))
                    .font(.system(size: 32, weight: .light)).foregroundStyle(.cyan)
            }
            .accessibilityHidden(true)
            .onAppear {
                if !reduceMotion {
                    withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) { haloExpanded = true }
                }
            }
            Label(VoiceInterfaceStatus.label(recording: voice.isRecording, running: isRunning, speaking: voice.isSpeaking),
                  systemImage: voice.isRecording ? "waveform" : "circle.fill")
                .font(.headline).foregroundStyle(voice.isRecording ? .red : .cyan)
            Text(statusText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var voiceCore: some View {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().stroke(.cyan.opacity(0.13), lineWidth: 1).frame(width: 68, height: 68)
                    Circle().trim(from: 0.04, to: 0.78)
                        .stroke(.cyan.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 60, height: 60).rotationEffect(.degrees(haloExpanded ? 180 : 0))
                    Circle().trim(from: 0.1, to: 0.92)
                        .stroke(.cyan.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 48, height: 48).rotationEffect(.degrees(haloExpanded ? -180 : 0))
                    Circle().fill(RadialGradient(colors: [.cyan.opacity(0.35), .cyan.opacity(0.03)], center: .center, startRadius: 2, endRadius: 44))
                        .frame(width: 40, height: 40)
                    Image(systemName: voice.isRecording ? "waveform" : (voice.isSpeaking ? "speaker.wave.2.fill" : "sparkles"))
                        .font(.system(size: 18, weight: .light)).foregroundStyle(.cyan)
                }
                .accessibilityHidden(true)
                .onAppear {
                    if !reduceMotion {
                        withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) { haloExpanded = true }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("JARVIS").font(.system(size: 23, weight: .ultraLight, design: .rounded)).tracking(7)
                    Label(VoiceInterfaceStatus.label(recording: voice.isRecording, running: isRunning, speaking: voice.isSpeaking),
                          systemImage: voice.isRecording ? "waveform" : "circle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(voice.isRecording ? .red : .cyan)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(LinearGradient(colors: [Color.cyan.opacity(0.09), Color.cyan.opacity(0.015)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.cyan.opacity(0.22)))

    }

    private var conversationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if JARVIS_EXACT_BROWSER_EXPERIMENT || JARVIS_COMBINED_EXPERIMENT
            Text(ExactBrowserExperiment.current ? "实验模式：打开完整网址前需要逐次审批；浏览器可能重定向或发送网络请求。" : "完整网址实验未启用。")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            #if JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT
            HStack {
                Button("请求辅助功能权限") {
                    accessibilityRequestResult = AccessibilityPermissionRequest.request()
                    accessibilityTrusted = AccessibilityPermissionRequest.isTrusted()
                }
                    .accessibilityIdentifier("safari-accessibility-permission-request")
                Text("授权后返回并重新提交请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("应用标识：\(Bundle.main.bundleIdentifier ?? "无")")
                Text("应用路径：\(Bundle.main.bundleURL.path)").textSelection(.enabled)
                Text("请求返回：\(accessibilityRequestResult.map { $0 ? "已信任" : "未信任" } ?? "未请求")；当前信任：\(accessibilityTrusted ? "是" : "否")")
                Button("刷新信任状态") { accessibilityTrusted = AccessibilityPermissionRequest.isTrusted() }
            }.font(.caption).accessibilityIdentifier("safari-accessibility-diagnostics")
            #endif
            Text("开启语音对话后，回答朗读结束会自动重新开启麦克风。可随时点击“结束语音对话”停止。")
                .font(.caption).foregroundStyle(.secondary)

            DisclosureGroup("能做什么与权限") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("语音对话需要麦克风和语音识别权限。开启连续对话后，朗读结束会重新聆听；可随时结束对话。")
                    Text("截图需要屏幕录制权限；读取应用界面需要辅助功能权限，目前仅支持 Finder、Safari 和终端。")
                    Text("网页及应用操作受权限和审批限制；请在任务中查看操作详情。")
                    Text("本地命令目前仅支持 pwd，并须经你批准。")
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .font(.caption.weight(.medium))
            progressLog
        }
    }

    private var composer: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("你的消息").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { goal }, set: { value in
                    if value != goal { autoSubmit.cancel() }
                    var origin = VoiceInputOrigin(containsVoice: containsVoiceInput, restoredID: restoredVoiceDraftID)
                    origin.applyEdit(value)
                    containsVoiceInput = origin.containsVoice
                    restoredVoiceDraftID = origin.restoredID
                    goal = value
                }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("消息输入")
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .disabled(isRunning || voice.isRecording || voice.isStarting || voice.isFinishing)
                Text("语音任务以明文保存在本机；成功后清除本次记录。失败或恢复的原记录可能保留，需手动删除。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(voice.isRecording ? "停止录音" : (voice.isFinishing ? "取消转写" : "开始说话 ⌘⇧V")) {
                        if voice.isRecording { voice.finishRecording() }
                        else if voice.isFinishing { voice.stop(); voice.discardTranscript(); goal = voiceDraftPrefix.originalDraft }
                        else { beginVoice() }
                    }.keyboardShortcut("v", modifiers: [.command, .shift])
                     .disabled(isRunning || voice.isStarting || voice.needsConfirmation)
                    if voice.isRecording { Text("● 正在聆听；停顿后结束") .foregroundStyle(.red) }
                    if voice.isStarting { Text("正在准备离线识别…") }
                    if voice.isFinishing { Text("正在完成转写…") }
                }
                if let error = voice.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
                if let pending = autoSubmit.pendingText {
                    VStack(alignment: .leading) {
                        Text("即将运行：\(pending)").lineLimit(2).truncationMode(.tail)
                            .accessibilityLabel("即将运行的完整转写：\(pending)")
                        Text("完整文字可在上方输入框查看。")
                            .font(.caption)
                        HStack {
                            Text("\(autoSubmit.secondsRemaining) 秒后自动运行；编辑文字也会取消。")
                            Button("取消自动运行") { autoSubmit.cancel() }
                        }
                    }.font(.caption).foregroundStyle(.orange)
                }
                if voice.needsConfirmation {
                    HStack {
                        Text("最终转写未确认，请检查文字后确认。")
                        Button("确认转写") { voice.confirmTranscript() }
                    }.foregroundStyle(.orange).font(.caption)
                }
            }

    }

    private var composerDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
                Text(voice.isRecording ? "麦克风：开启" : "麦克风：关闭")
                    .font(.caption).foregroundStyle(voice.isRecording ? .red : .secondary)
                Text((voice.isRecording || voice.isStarting || voice.isFinishing
                      ? voiceWillAutoSubmit
                      : VoiceDraftPrefix.allowsAutomaticSubmission(draft: goal, serviceAvailable: service != nil))
                     ? "说话停顿并识别完成后会自动运行；也可手动停止。"
                     : "已有草稿将保留，转写后请手动运行。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("提交的语音任务以明文保存在本机，成功后清除其记录，恢复的原记录需手动删除；未提交转写关闭窗口会丢失。删除不保证安全擦除。")
                    .font(.caption)
                ForEach(savedVoiceDrafts, id: \.id) { draft in
                    HStack {
                        Text(draft.text).lineLimit(2).textSelection(.enabled)
                        Button("恢复") { if goal.isEmpty { goal = draft.text; restoredVoiceDraftID = draft.id } }.disabled(!goal.isEmpty || isRunning)
                        Button("删除") { deleteVoiceDraft(draft.id); if restoredVoiceDraftID == draft.id { restoredVoiceDraftID = nil } }.disabled(isRunning)
                    }
                }
                if let draftStoreError { Text(draftStoreError).foregroundStyle(.red) }
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("诊断与技术信息") {
            Toggle("显示语音诊断（仅此窗口）", isOn: $showVoiceDiagnostics).font(.caption)
            if showVoiceDiagnostics && VADBuildAccess.currentAllowed && optionalVADEnabled {
                Text("实验性语音检测不提供能量诊断；切换将在下次录音时生效。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if showVoiceDiagnostics {
                Text("格式：\(voiceDiagnostic?.formatSupported.map { $0 ? "支持" : "不支持" } ?? "未知") · 超过阈值：\(voiceDiagnostic?.aboveThreshold.map { $0 ? "是" : "否" } ?? "未知") · 静音：\(voiceDiagnostic?.silenceSeconds ?? 0, specifier: "%.1f") 秒 · 结束：\(voiceDiagnosticReason ?? "尚未结束")").font(.caption)
            }
            }
            DisclosureGroup("本地模型服务") {
                VStack(alignment: .leading, spacing: 8) {
                    Button(checkingModel ? "正在检查…" : "检查默认 Ollama 和模型") {
                        checkingModel = true
                        Task { modelDiagnostic = await OllamaDiagnostic.check(); checkingModel = false }
                    }.disabled(checkingModel)
                    if let modelDiagnostic { Text(modelDiagnostic.message).font(.caption).textSelection(.enabled) }
                    Text("检查默认地址 127.0.0.1:11434 和模型 qwen3:4b-instruct，不会自动安装或启动服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("语音设置") {
                if VADBuildAccess.currentAllowed {
                Toggle("实验性语音停顿检测", isOn: $optionalVADEnabled)
                    .disabled(voice.isRecording || voice.isStarting || voice.isFinishing)
                Text(optionalVADEnabled
                     ? "下次录音将使用本机语音检测。空草稿且服务可用时，可靠停顿并完成转写后会倒计时自动发送，可取消；检测异常时请检查转写并手动发送。"
                     : "当前使用现有停顿检测方式；实验性检测默认关闭。")
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("说完后的停顿")
                    Slider(value: Binding(get: { VoiceEndpointSettings.safePause(pauseSeconds) }, set: { pauseSeconds = VoiceEndpointSettings.safePause($0) }), in: VoiceEndpointSettings.pauseRange, step: 0.5).accessibilityLabel("说完后的停顿秒数")
                    Text(String(format: "%.1f 秒", VoiceEndpointSettings.safePause(pauseSeconds))).monospacedDigit()
                }
                HStack {
                    Text("单次录音上限")
                    Slider(value: Binding(get: { VoiceEndpointSettings.safeMaximum(maxRecordingSeconds) }, set: { maxRecordingSeconds = VoiceEndpointSettings.safeMaximum($0) }), in: VoiceEndpointSettings.maximumRange, step: 10).accessibilityLabel("单次录音上限秒数")
                    Text("\(Int(VoiceEndpointSettings.safeMaximum(maxRecordingSeconds))) 秒").monospacedDigit()
                }
                Text("设置将在下次录音时生效。 ").font(.caption).foregroundStyle(.secondary)
                Picker("中文音色", selection: $selectedVoiceID) {
                    Text("系统默认中文音色").tag("")
                    if !selectedVoiceID.isEmpty && !availableChineseVoices.contains(where: { $0.identifier == selectedVoiceID }) {
                        Text("原音色不可用，将使用默认音色").tag(selectedVoiceID)
                    }
                    ForEach(availableChineseVoices, id: \.identifier) { item in
                        Text("\(item.name)（\(item.language) · \(VoicePlaybackSettings.qualityLabel(item.quality))）").tag(item.identifier)
                    }
                }
                HStack {
                    Text("语速")
                    Slider(value: $voiceRate, in: 0.35...0.6, step: 0.01)
                    Text(String(format: "%.2f", voiceRate)).monospacedDigit()
                }
                Button("试听音色") {
                    voice.previewVoice(conversationActive: conversation.isActive, isRunning: isRunning)
                }
                .disabled(conversation.isActive || isRunning || voice.isSpeaking || voice.isRecording || voice.isStarting || voice.isFinishing)
                Text("仅显示当前系统可用音色；不会下载音色或更改系统默认设置。音质与自然程度取决于系统提供的声音。")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
    }

    private var controlsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if isRunning {
                    Button("取消任务") { cancel() }
                        .layoutPriority(1)
                        .accessibilityHint("停止当前任务")
                }
                if conversation.isActive {
                    Button("结束语音对话") { stopConversation() }
                        .layoutPriority(1)
                        .accessibilityHint("停止连续对话和麦克风")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("朗读回答") { voice.speak(lastAnswer) }
                        .disabled(lastAnswer.isEmpty || voice.isRecording || voice.isStarting || voice.isFinishing)
                    Button("停止朗读") { stopConversation() }.disabled(!voice.isSpeaking)
                    Button(isRunning ? "运行中…" : "发送") { start(fromVoice: conversation.manualRunToken != nil) }
                        .keyboardShortcut(.defaultAction).disabled(!canRun)
                }
                HStack {
                    Menu("更多操作") {
                        Button("朗读回答") { voice.speak(lastAnswer) }
                            .disabled(lastAnswer.isEmpty || voice.isRecording || voice.isStarting || voice.isFinishing)
                        Button("停止朗读") { stopConversation() }.disabled(!voice.isSpeaking)
                        }
                    Spacer()
                    Button(isRunning ? "运行中…" : "发送") { start(fromVoice: conversation.manualRunToken != nil) }
                        .keyboardShortcut(.defaultAction).disabled(!canRun)
                }
            }
        }
    }

    private var availableChineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("zh") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder private var progressLog: some View {
        Divider()
        Text("对话").font(.title3.weight(.medium))
        Toggle("自动跟随最新消息", isOn: $followLatest).toggleStyle(.checkbox).font(.caption)
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if log.entries.isEmpty {
                    Text(isRunning ? "任务进行中…" : "说句话，或输入一条消息开始。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(log.entries.filter { $0.kind == .assistant || $0.kind == .approval || $0.kind == .error || ($0.kind == .info && ($0.text.hasPrefix("你：") || $0.text.hasPrefix("Switch to the intended Safari"))) }) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: entry.kind == .assistant ? "sparkles" : "circle.fill")
                            .font(.caption2).foregroundStyle(color(for: entry.kind))
                            .accessibilityHidden(true)
                        Text(entry.text.hasPrefix("Assistant: ") ? String(entry.text.dropFirst(11)) : entry.text)
                            .font(.callout)
                            .foregroundStyle(color(for: entry.kind))
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .id(entry.id)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(entry.kind == .assistant ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(minHeight: 120, idealHeight: 160)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        .onChange(of: log.entries.count) { _, _ in
            if followLatest, let last = log.entries.last(where: { $0.kind == .assistant || $0.kind == .approval || $0.kind == .error || ($0.kind == .info && ($0.text.hasPrefix("你：") || $0.text.hasPrefix("Switch to the intended Safari"))) }) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
        Button("跳至最新消息") { if let last = log.entries.last(where: { $0.kind == .assistant || $0.kind == .approval || $0.kind == .error || ($0.kind == .info && ($0.text.hasPrefix("你：") || $0.text.hasPrefix("Switch to the intended Safari"))) }) { proxy.scrollTo(last.id, anchor: .bottom) } }.font(.caption)
        DisclosureGroup("任务详情") {
            ForEach(log.entries) { entry in
                Text(entry.text).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.font(.caption)
        }
    }

    private var canRun: Bool {
        VoiceDraftPrefix.canRun(draft: goal, serviceAvailable: service != nil, isRunning: isRunning,
                                voiceBusy: voice.isRecording || voice.isStarting || voice.isFinishing || voice.needsConfirmation)
    }

    private var statusText: String {
        if voice.isStarting { return "正在准备离线识别。" }
        if voice.isSpeaking { return "正在朗读；按 ⌘⇧V 可打断并说话。" }
        if isRunning { return "正在思考或等待审批…" }
        if voice.isRecording { return "正在聆听；停顿后结束，也可手动停止。" }
        if voice.isFinishing { return "正在等待最终转写。" }
        if voice.needsConfirmation { return "请检查并确认转写后再运行。" }
        guard let runningTaskID else {
            return VoiceDraftPrefix.idleStatus(draft: goal, serviceAvailable: service != nil, isRunning: isRunning)
        }
        return "Task \(runningTaskID.uuidString.prefix(8))"
    }

    /// Existing drafts are never automatically submitted with new speech.
    private func beginVoice(continuing token: Int? = nil) {
        autoSubmit.cancel()
        guard !isRunning && !voice.isStarting && !voice.needsConfirmation else { return }
        let sessionToken: Int
        if let token {
            guard conversation.isCurrent(token) else { return }
            sessionToken = token
        } else if conversation.isActive {
            sessionToken = conversation.generation
        } else {
            sessionToken = conversation.begin()
            log.append(AgentLogEntry(kind: .info, text: "已开启新语音对话；不会沿用此前会话的对话上下文。"))
        }
        Task { @MainActor in
            guard conversation.isCurrent(sessionToken), isVisible, !isRunning, !voice.isStarting, !voice.isRecording,
                  !voice.isFinishing, !voice.needsConfirmation else { return }
            let prefix = VoiceDraftPrefix(draft: goal)
            voiceDraftPrefix = prefix
            let canAutoSubmit = VoiceDraftPrefix.allowsAutomaticSubmission(draft: goal, serviceAvailable: service != nil)
            voiceWillAutoSubmit = canAutoSubmit
            let update: @MainActor @Sendable (String) -> Void = { text in
                if let updated = prefix.render(transcript: text) { goal = updated; containsVoiceInput = true }
            }
            let submit: @MainActor @Sendable (String) -> Void = { text in
                guard conversation.isCurrent(sessionToken), isVisible, !isRunning, service != nil else { return }
                goal = text
                autoSubmit.schedule(text) { pending in
                    guard conversation.isCurrent(sessionToken), isVisible, !isRunning, canRun, goal == pending else { return }
                    start(fromVoice: true)
                }
            }
            if canAutoSubmit { await voice.start(onTranscript: update, autoSubmit: submit) }
            else { await voice.start(onTranscript: update) }
        }
    }

    private func start(fromVoice: Bool = false) {
        guard canRun, let service else { return }
        autoSubmit.cancel()
        let submittedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedGoal.isEmpty else { return }
        if fromVoice || containsVoiceInput || restoredVoiceDraftID != nil {
            guard let voiceDraftStore else { draftStoreError = "无法保存语音草稿，请检查本地存储。"; return }
            do {
                // Save the exact submitted text without deleting the restored original.
                // Keep the restored original until the user explicitly deletes it.
                let savedID = try voiceDraftStore.save(submittedGoal)
                activeVoiceDraftID = savedID
                restoredVoiceDraftID = nil
                refreshVoiceDrafts()
            }
            catch { draftStoreError = "无法保存语音草稿，请检查本地存储。"; return }
        }
        voice.stop()
        voice.stopSpeaking()
        lastAnswer = ""
        let token = fromVoice && conversation.isActive ? conversation.generation : nil
        let history = token == nil ? [] : conversation.history
        if token == nil { log.reset() }
        log.append(AgentLogEntry(kind: .info, text: "你：\(submittedGoal)"))
        goal = ""
        containsVoiceInput = false
        let runToken = runLifecycle.begin()
        activeRunToken = runToken
        activeSubmittedGoal = submittedGoal
        runningTaskID = nil
        isRunning = true
        run = Task {
            await execute(goal: submittedGoal, history: history, token: token, runToken: runToken, service: service)
        }
    }

    private func refreshVoiceDrafts() {
        do { savedVoiceDrafts = try voiceDraftStore?.list() ?? [] }
        catch { draftStoreError = "无法读取本地语音草稿。" }
    }

    private func deleteVoiceDraft(_ id: String) {
        do { try voiceDraftStore?.delete(id); refreshVoiceDrafts() }
        catch { draftStoreError = "无法删除本地语音草稿。" }
    }

    private func stopConversation() {
        conversation.stop()
        autoSubmit.cancel()
        voice.stop()
        voice.stopSpeaking()
        if isRunning { cancel() }
    }

    private func cancel() {
        conversation.stop()
        autoSubmit.cancel()
        if isVisible, goal.isEmpty, let submitted = activeSubmittedGoal { goal = submitted }
        runLifecycle.invalidate()
        activeVoiceDraftID = nil
        if isVisible { log.append(AgentLogEntry(kind: .info, text: "已请求取消任务。")) }
        run?.cancel()
        if let runningTaskID {
            Task { try? await client.cancel(taskID: runningTaskID) }
        }
    }

    /// Creates the task, drives one loop run against it, and writes the
    /// outcome into the log. Every exit path clears the running flags.
    private func execute(goal submitted: String, history: [LLMMessage], token: Int?, runToken: Int, service: any TaskServiceAPI) async {
        var spokenAnswer: String?
        do {
            try Task.checkCancellation()
            let task = try await CancellableTaskCreation.run(create: {
                try await service.createTask(title: submitted)
            }, cancel: { task in
                try? await service.cancel(taskID: task.id)
            })
            if Task.isCancelled || !runLifecycle.isCurrent(runToken) {
                await Task.detached { try? await service.cancel(taskID: task.id) }.value
                throw CancellationError()
            }
            runningTaskID = task.id
            log.append(AgentLogEntry(kind: .info, text: "Task \(task.id.uuidString.prefix(8)) created"))
            let safariReadEnabled = await service.isSafariReadAvailable()
            let runner = TaskServiceToolRunner(service: service, taskID: task.id, enableSafariRead: safariReadEnabled, exactBrowserEnabled: ExactBrowserExperiment.current)
            let waiter = TaskServiceApprovalWaiter(service: service)
            let prompt = AgentLoop.defaultSystemPrompt + (token == nil ? "" : "\nFor voice conversation, answer naturally and concisely in the user's language. Preserve necessary safety, approval and error details; do not invent actions.")
            let session = AgentSession(provider: OllamaProvider(), runner: runner, approvalWaiter: waiter,
                                       taskID: task.id, systemPrompt: prompt, memoryContextProvider: memoryContextProvider)
            let result = try await runSession(session, goal: submitted, history: history, runToken: runToken)
            try Task.checkCancellation()
            guard runLifecycle.isCurrent(runToken), isVisible else { throw CancellationError() }
            spokenAnswer = await finish(result, taskID: task.id, runToken: runToken, service: service)
            _ = try? await client.refresh()
        } catch {
            if runLifecycle.isCurrent(runToken), isVisible {
                log.append(AgentLogEntry(kind: Task.isCancelled ? .info : .error,
                                         text: Task.isCancelled ? "Run cancelled." : "Run failed: \(error.localizedDescription)"))
            }
        }
        let cancelled = Task.isCancelled
        let completedDraftID = activeRunToken == runToken ? activeVoiceDraftID : nil
        if activeRunToken == runToken {
            activeVoiceDraftID = nil
            isRunning = false
            runningTaskID = nil
            run = nil
            activeRunToken = nil
            activeSubmittedGoal = nil
        }
        guard let answer = spokenAnswer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cancelled else {
            if token == nil, runLifecycle.mayRestore(token: runToken, visible: isVisible, currentDraft: goal) { goal = submitted }
            if let token, conversation.isCurrent(token) { conversation.stop() }
            return
        }
        if let id = completedDraftID { deleteVoiceDraft(id) }
        guard let token, conversation.isCurrent(token), isVisible else { return }
        conversation.record(user: submitted, answer: answer, token: token)
        voice.speak(answer) { completed in
            conversation.playbackFinished(completed: completed, token: token, visible: isVisible,
                serviceAvailable: service != nil, isRunning: isRunning, draft: goal,
                voiceBusy: voice.isRecording || voice.isStarting || voice.isFinishing || voice.needsConfirmation || autoSubmit.pendingText != nil) {
                    beginVoice(continuing: token)
                }
        }
    }

    /// Streams the session's events into the log in order. The stream is finished
    /// exactly once whichever way the run ends, so the collector always
    /// completes and the log is settled before the outcome is appended.
    private func runSession(_ session: AgentSession, goal: String, history: [LLMMessage], runToken: Int) async throws -> AgentLoopResult {
        let (stream, continuation) = AsyncStream<AgentLoopEvent>.makeStream()
        let collector = Task { @MainActor in
            for await event in stream {
                if runLifecycle.isCurrent(runToken), isVisible { log.append(AgentLogEntry(event: event)) }
            }
        }
        do {
            let result = try await session.run(goal: goal, history: history) { event in
                continuation.yield(event)
            }
            continuation.finish()
            await collector.value
            return result
        } catch {
            continuation.finish()
            await collector.value
            throw error
        }
    }

    /// Records how the run terminated. A completed run also closes the task;
    /// any other outcome leaves the task open so the user can decide what to
    /// do with it from the task-detail window.
    private func finish(_ result: AgentLoopResult, taskID: UUID, runToken: Int, service: any TaskServiceAPI) async -> String? {
        guard case .completed(let text) = result else { log.recordOutcome(result); return nil }
        do {
            try await service.complete(taskID: taskID)
            guard runLifecycle.isCurrent(runToken), isVisible, !Task.isCancelled else { return nil }
            lastAnswer = text
            log.recordOutcome(result)
            return text
        } catch {
            if runLifecycle.isCurrent(runToken), isVisible {
                log.append(AgentLogEntry(kind: .error, text: "无法完成任务：\(error.localizedDescription)"))
            }
            return nil
        }
    }

    private func color(for kind: AgentLogEntry.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .assistant: return .primary
        case .toolCall: return .blue
        case .result: return .green
        case .denied, .approval: return .orange
        case .error: return .red
        }
    }
}
