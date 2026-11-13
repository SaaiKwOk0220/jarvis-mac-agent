import SwiftUI
import JarvisDomain

struct TaskHistoryVisibility {
    private(set) var isExpanded = false
    mutating func toggle() { isExpanded.toggle() }
    func shows(_ status: TaskStatus) -> Bool {
        if isExpanded { return true }
        switch status {
        case .completed, .failed, .cancelled: return false
        case .draft, .planning, .running, .awaitingApproval, .blocked: return true
        }
    }
}

struct TaskListPresentation {
    let tasks: [JarvisTask]
    let history: TaskHistoryVisibility
    let hasError: Bool
    var visibleTasks: [JarvisTask] { tasks.filter { history.shows($0.status) } }
    var showsStaleWarning: Bool { hasError && !tasks.isEmpty }
    var emptyMessage: String { hasError && tasks.isEmpty ? "无法获取任务" : (history.isExpanded ? "暂无任务" : "暂无进行中的任务") }
}

struct TaskListView: View {
    @State private var history = TaskHistoryVisibility()
    @State private var moreExpanded = false
    @ObservedObject var client: ServiceClient
    private let previewTasks: [JarvisTask]?
    private var displayedTasks: [JarvisTask] { previewTasks ?? client.tasks }
    private var presentation: TaskListPresentation { .init(tasks: displayedTasks, history: history, hasError: client.serviceError != nil) }
    @Environment(\.openWindow) private var openWindow

    init(client: ServiceClient, previewTasks: [JarvisTask]? = nil, previewHistoryExpanded: Bool = false, previewMoreExpanded: Bool = false) {
        self.client = client
        self.previewTasks = previewTasks
        var initial = TaskHistoryVisibility()
        if previewHistoryExpanded { initial.toggle() }
        _history = State(initialValue: initial)
        _moreExpanded = State(initialValue: previewMoreExpanded)
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("JARVIS", systemImage: "waveform.circle")
                    .font(.headline).tracking(2)
                Spacer()
                Button { Task { try? await client.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("刷新任务")
            }
            Text(client.serviceError == nil ? "本地服务：查看任务状态" : "本地服务暂不可用")
                .font(.caption).foregroundStyle(.secondary)
            Divider().overlay(.cyan.opacity(0.3))
            Button { openWindow(id: "ask-jarvis") } label: {
                Label("打开 Jarvis 控制台", systemImage: "waveform.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
            Button { openWindow(id: "welcome") } label: {
                Label("权限与使用说明", systemImage: "checkmark.shield")
            }.buttonStyle(.plain)
            DisclosureGroup("更多功能", isExpanded: $moreExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    #if JARVIS_SAFARI_CLICK_EXPERIMENT && (JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT)
                    Button("Safari 点击实验…") { openWindow(id: "safari-click-mode") }
                    Button("请求 Safari 点击…") { openWindow(id: "safari-click-request") }
                    #endif
                    Button("记忆…") { openWindow(id: "memory") }
                    Button("图片理解实验…") { openWindow(id: "vision-image") }
                    Button("新建任务…") { openWindow(id: "new-task") }
                    Button("运行命令…") { openWindow(id: "shell-task") }
                    Button("获取网页…") { openWindow(id: "fetch-url") }
                    Button("截图…") { openWindow(id: "screenshot") }
                    Button("检查辅助功能…") { openWindow(id: "ax-query") }
                }.buttonStyle(.plain).padding(.vertical, 6)
            }
            Divider().overlay(.cyan.opacity(0.2))
            HStack {
                Text("任务").font(.subheadline.weight(.medium))
                Spacer()
                Button(history.isExpanded ? "隐藏历史" : "查看历史") { history.toggle() }
                    .buttonStyle(.plain).font(.caption)
            }
            if let error = client.serviceError {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                if presentation.showsStaleWarning { Text("以下任务可能不是最新状态。").font(.caption).foregroundStyle(.secondary) }
            }
            if presentation.visibleTasks.isEmpty {
                Text(presentation.emptyMessage)
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(presentation.visibleTasks) { task in
                            Button {
                                client.select(task)
                                openWindow(id: "task-detail")
                            } label: {
                                HStack {
                                    Circle().fill(color(for: task.status)).frame(width: 8, height: 8)
                                    VStack(alignment: .leading) {
                                        Text(task.title).lineLimit(2)
                                        Text(task.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 220)
            }
            Divider().overlay(.cyan.opacity(0.2))
            Button("退出 Jarvis") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 320)
        .background(LinearGradient(colors: [Color(red: 0.025, green: 0.07, blue: 0.11), Color(red: 0.01, green: 0.025, blue: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
        }
        .frame(maxHeight: 520)
        .task {
            guard previewTasks == nil else { return }
            _ = try? await client.refresh()
            // First-launch onboarding: pop the welcome window once per
            // install. The "welcomed" flag is set inside WelcomeView when
            // the user taps "Get started", so we only ever open it when
            // the flag is absent.
            #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
            if !UserDefaults.standard.bool(forKey: WelcomeView.welcomedDefaultsKey) {
                openWindow(id: "welcome")
            }
            #endif
        }
    }

    private func color(for status: TaskStatus) -> Color {
        switch status { case .completed: return .green; case .failed, .blocked: return .red; case .awaitingApproval: return .orange; case .cancelled: return .gray; default: return .blue }
    }

}
