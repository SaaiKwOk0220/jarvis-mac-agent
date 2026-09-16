import SwiftUI
import JarvisDomain

/// Runs a shell command by creating a new task and submitting a shell tool
/// request in one go. A separate normal macOS window (not the menu-bar
/// menu) is used so TextField/TextEditor can reliably take focus.
struct NewShellTaskView: View {
    @ObservedObject var client: ServiceClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @FocusState private var titleIsFocused: Bool
    @State private var title: String = ""
    @State private var command: String = ""
    @State private var workingDirectory: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Run shell command").font(.title2).bold()
            Text("Creates a task and submits a shell command. The task will sit in awaiting approval until you approve it from the task-detail window.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("For example: Refresh derived data", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleIsFocused)
                    .onSubmit { submit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $command)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Working directory").font(.caption).foregroundStyle(.secondary)
                TextField(Self.defaultWorkingDirectory, text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isSubmitting ? "Running…" : "Run command") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(24)
        .onAppear {
            if workingDirectory.isEmpty {
                workingDirectory = Self.defaultWorkingDirectory
            }
            titleIsFocused = true
        }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static var defaultWorkingDirectory: String {
        let url = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("Jarvis", isDirectory: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return url.path
    }

    private func submit() {
        let submittedTitle = title
        let submittedCommand = command
        let submittedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultWorkingDirectory
            : workingDirectory
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                let task = try await client.createTask(title: submittedTitle)
                try await client.submitShellCommand(
                    taskID: task.id,
                    command: submittedCommand,
                    workingDirectory: submittedDirectory
                )
                openWindow(id: "task-detail")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}