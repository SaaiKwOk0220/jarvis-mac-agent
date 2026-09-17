import SwiftUI

/// Runs a fetch URL tool request by creating a new task and submitting the
/// URL in one go. `.read` requests do not need explicit approval, so the
/// task-detail window will show the fetch progressing straight through to
/// `.completed` once the URL has been resolved.
struct NewFetchURLView: View {
    @ObservedObject var client: ServiceClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @FocusState private var titleIsFocused: Bool
    @State private var title: String = ""
    @State private var url: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fetch URL").font(.title2).bold()
            Text("Creates a task and fetches the URL via HTTPS. Only sites in the policy allowlist will be allowed through.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("For example: Check upstream docs", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleIsFocused)
                    .onSubmit { submit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("URL (https://…)").font(.caption).foregroundStyle(.secondary)
                TextField("https://example.com/page", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submit() }
            }

            Label("Sites not in the policy allowlist will be denied without prompt.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isSubmitting ? "Fetching…" : "Fetch") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(24)
        .onAppear { titleIsFocused = true }
    }

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let submittedTitle = title
        let submittedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                let task = try await client.createTask(title: submittedTitle)
                try await client.submitFetchURL(taskID: task.id, urlString: submittedURL)
                openWindow(id: "task-detail")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}