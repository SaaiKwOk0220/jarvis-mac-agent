import SwiftUI

/// A normal macOS window is used for text entry because a menu-bar menu cannot
/// reliably host a focusable text field.
struct NewTaskView: View {
    @ObservedObject var client: ServiceClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @FocusState private var titleIsFocused: Bool
    @State private var title = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a task").font(.title2).bold()
            Text("Give Jarvis a short outcome to track. Workers are added in later stages.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("For example: Test the approval workflow", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleIsFocused)
                .onSubmit { createTask() }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isCreating ? "Creating…" : "Create task") { createTask() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .onAppear { titleIsFocused = true }
    }

    private func createTask() {
        let submittedTitle = title
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                let task = try await client.createTask(title: submittedTitle)
                client.select(task)
                openWindow(id: "task-detail")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
