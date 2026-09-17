import SwiftUI

/// Runs a screenshot capture by creating a new task and submitting a
/// screenshot tool request in one go. The user supplies a task title and
/// an output filename; the resulting PNG lands at
/// `<appSupport>/Jarvis/screenshots/<filename>`. `.read` requests do not
/// need explicit approval, so the task-detail window will show the
/// capture progressing straight through to `.completed` once the
/// ScreenCaptureKit call returns.
struct NewScreenshotView: View {
    @ObservedObject var client: ServiceClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @FocusState private var titleIsFocused: Bool
    @State private var title: String = ""
    @State private var filename: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture Screenshot").font(.title2).bold()
            Text("Creates a task and captures the main display. The resulting PNG is saved under ~/Library/Application Support/Jarvis/screenshots/.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("For example: Snapshot of today’s layout", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleIsFocused)
                    .onSubmit { submit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Output filename").font(.caption).foregroundStyle(.secondary)
                TextField("screenshot.png", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submit() }
            }

            Label("Requires Screen Recording permission (System Settings > Privacy & Security > Screen Recording).",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isSubmitting ? "Capturing…" : "Capture") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(24)
        .onAppear {
            if filename.isEmpty {
                filename = Self.defaultFilename
            }
            titleIsFocused = true
        }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Default filename uses a UTC timestamp so two captures in the same
    /// session don't collide. Format matches the example in the plan:
    /// `screenshot-2026-09-17-1230.png`.
    private static var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return "screenshot-\(formatter.string(from: Date())).png"
    }

    private func submit() {
        let submittedTitle = title
        let submittedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                let task = try await client.createTask(title: submittedTitle)
                try await client.submitScreenshot(taskID: task.id, outputFilename: submittedFilename)
                openWindow(id: "task-detail")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
