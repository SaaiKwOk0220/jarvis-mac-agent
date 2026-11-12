#if JARVIS_SAFARI_CLICK_EXPERIMENT && JARVIS_SAFARI_EXPERIMENT_BUILD
import SwiftUI
import JarvisService

struct SafariClickModeView: View {
    let service: TaskService
    @State private var enabled = false
    @State private var busy = false
    @State private var cleanupRequired = false
    @State private var message = "实验模式默认关闭。"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Safari 点击实验").font(.title2.bold())
            Text("仅在你开启后允许实验模式。每次点击都需要单独审批；检查与动作不是原子的，动作开始后无法撤销。系统权限短暂撤销又恢复时，无法保证察觉。")
                .fixedSize(horizontal: false, vertical: true)
            Text("开启开关不会自动点击网页。请选择任务并明确输入网页元素类型和标题。")
                .foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary)
            Button(cleanupRequired ? "重试清理" : (enabled ? "关闭实验模式" : "开启实验模式")) {
                if enabled || cleanupRequired {
                    beginCleanup(permissionLost: false)
                } else {
                    do { try service.enableExperimentalClickMode(); enabled = true; message = "实验模式已开启。" }
                    catch { enabled = false; message = "无法开启：请检查实验应用身份和辅助功能权限。" }
                }
            }.disabled(busy)
            Spacer()
        }
        .padding(24)
        .onAppear { refreshStatus() }
        .task {
            while !Task.isCancelled {
                refreshStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshStatus() {
        guard !busy else { return }
        let current = service.isExperimentalClickModeEnabled
        let needsCleanup = service.isExperimentalClickCleanupRequired
        let newlyLost = needsCleanup && !cleanupRequired
        enabled = current
        cleanupRequired = needsCleanup
        if newlyLost { beginCleanup(permissionLost: true) }
    }

    private func beginCleanup(permissionLost: Bool) {
        // Revocation happens synchronously, before the asynchronous cleanup starts.
        let cleanup = service.disableExperimentalClickMode()
        enabled = false
        busy = true
        message = permissionLost ? "辅助功能权限失效，正在撤销并清理实验请求。" : "正在关闭实验模式。"
        Task {
            do {
                let started = try await cleanup.value
                cleanupRequired = false
                if started { message = "授权已撤销；已有动作可能已开始，结果未知，请先检查页面。" }
                else { message = permissionLost ? "辅助功能权限失效，实验模式已关闭。" : "实验模式已关闭。" }
            } catch {
                cleanupRequired = true
                message = "已撤销授权，但清理未完成，请重试清理并检查实验记录。"
            }
            busy = false
        }
    }
}
#endif
