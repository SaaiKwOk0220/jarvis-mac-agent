#if JARVIS_SAFARI_CLICK_EXPERIMENT && (JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT)
import SwiftUI

struct SafariClickRequestView: View {
    @ObservedObject var client: ServiceClient
    @Environment(\.openWindow) private var openWindow
    @State private var role = "AXButton"
    @State private var title = ""
    @State private var submitting = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请求 Safari 点击").font(.title2.bold())
            Text("请先开启点击实验并选择一个任务。输入目标元素的精确 AX 类型和标题；提交后在 15 秒内切回目标 Safari HTTPS 窗口。系统仅接受唯一匹配，随后需要单独审批。")
                .fixedSize(horizontal: false, vertical: true)
            Text(client.selectedTask.map { "当前任务：\($0.title)" } ?? "请先选择任务。")
            TextField("AX 类型，例如 AXButton", text: $role)
            TextField("元素的精确标题", text: $title)
            Text(message).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("查找并请求审批") {
                    guard let task = client.selectedTask else { return }
                    submitting = true
                    message = "请在 15 秒内切回目标 Safari 窗口。"
                    Task {
                        do {
                            _ = try await client.submitExperimentalSafariClick(taskID: task.id, role: role, title: title)
                            message = "已创建审批请求，请检查完整网址与目标。"
                            openWindow(id: "task-detail")
                        } catch { message = "无法捕获唯一目标。请检查模式、权限、Safari 焦点及元素标题。" }
                        submitting = false
                    }
                }.disabled(submitting || client.selectedTask == nil || role.isEmpty || title.isEmpty)
            }
            Spacer()
        }.padding(24)
    }
}
#endif
