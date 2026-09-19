import SwiftUI

/// Inspects another app's accessibility tree by creating a new task and
/// submitting an `ax_query` tool request in one go. The user supplies a task
/// title, an application bundle identifier, and a max depth; the resulting
/// text tree is recorded in the task timeline. `.read` requests do not need
/// explicit approval, so the task-detail window will show the inspection
/// progressing straight through to `.completed` once the AXUIElement walk
/// returns.
///
/// The bundle identifier must be allowlisted in the Jarvis policy
/// (`PolicyConfig.applicationBundleIDs`); otherwise the request is denied
/// before the executor ever runs.
struct NewAccessibilityQueryView: View {
    @ObservedObject var client: ServiceClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @FocusState private var titleIsFocused: Bool
    @State private var title: String = ""
    @State private var target: String = ""
    @State private var maxDepth: Int = 4
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inspect Accessibility").font(.title2).bold()
            Text("Reads an app's accessibility tree over the macOS Accessibility API and records it in the task timeline.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("For example: Inspect Safari toolbar", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleIsFocused)
                    .onSubmit { submit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Bundle identifier").font(.caption).foregroundStyle(.secondary)
                TextField("com.apple.Safari", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submit() }
            }

            Stepper("Max depth: \(maxDepth)", value: $maxDepth, in: 1...8)

            Label("Requires Accessibility permission (System Settings > Privacy & Security > Accessibility).",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isSubmitting ? "Inspecting…" : "Inspect") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(24)
        .onAppear { titleIsFocused = true }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let submittedTitle = title
        let submittedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedDepth = maxDepth
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                let task = try await client.createTask(title: submittedTitle)
                try await client.submitAccessibilityQuery(
                    taskID: task.id,
                    target: submittedTarget,
                    maxDepth: submittedDepth
                )
                openWindow(id: "task-detail")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
