import SwiftUI
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
        case .toolCallRequested(let call):
            let arguments = call.arguments
                .sorted { $0.key < $1.key }
                .map { "\"\($0.key)\": \"\($0.value)\"" }
                .joined(separator: ", ")
            self.init(kind: .toolCall, text: "Tool call: \(call.name)({\(arguments)})")
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

    @StateObject private var log = AgentRunLog()
    @State private var goal = ""
    @State private var isRunning = false
    @State private var runningTaskID: UUID?
    @State private var run: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask Jarvis").font(.title2).bold()
            Text("Describe a goal. Jarvis plans tool calls and runs them through the same policy gate and approval flow as any other task.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Goal").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $goal)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .disabled(isRunning)
            }

            progressLog

            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { cancel() }
                    .disabled(!isRunning)
                Button(isRunning ? "Running…" : "Run") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
        }
        .padding(24)
    }

    @ViewBuilder private var progressLog: some View {
        Divider()
        Text("Progress").font(.headline)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if log.entries.isEmpty {
                    Text(isRunning ? "Waiting for the model…" : "No run yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(log.entries) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(color(for: entry.kind))
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: entry.kind))
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(minHeight: 180)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private var canRun: Bool {
        service != nil && !isRunning && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusText: String {
        guard let runningTaskID else {
            return service == nil ? "Jarvis service is unavailable." : "Ready."
        }
        return "Task \(runningTaskID.uuidString.prefix(8))"
    }

    private func start() {
        guard let service else { return }
        let submittedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedGoal.isEmpty else { return }
        log.reset()
        runningTaskID = nil
        isRunning = true
        run = Task {
            await execute(goal: submittedGoal, service: service)
        }
    }

    private func cancel() {
        run?.cancel()
        if let runningTaskID {
            Task { try? await client.cancel(taskID: runningTaskID) }
        }
    }

    /// Creates the task, drives one loop run against it, and writes the
    /// outcome into the log. Every exit path clears the running flags.
    private func execute(goal: String, service: any TaskServiceAPI) async {
        defer {
            isRunning = false
            runningTaskID = nil
            run = nil
        }
        do {
            let task = try await service.createTask(title: goal)
            runningTaskID = task.id
            log.append(AgentLogEntry(kind: .info, text: "Task \(task.id.uuidString.prefix(8)) created"))

            let runner = TaskServiceToolRunner(service: service, taskID: task.id)
            let loop = AgentLoop(provider: OllamaProvider(), runner: runner)
            let result = try await runLoop(loop, goal: goal)
            await finish(result, taskID: task.id, service: service)
            _ = try? await client.refresh()
        } catch {
            log.append(AgentLogEntry(
                kind: Task.isCancelled ? .info : .error,
                text: Task.isCancelled ? "Run cancelled." : "Run failed: \(error.localizedDescription)"
            ))
        }
    }

    /// Streams the loop's events into the log in order. The stream is finished
    /// exactly once whichever way the run ends, so the collector always
    /// completes and the log is settled before the outcome is appended.
    private func runLoop(_ loop: AgentLoop, goal: String) async throws -> AgentLoopResult {
        let (stream, continuation) = AsyncStream<AgentLoopEvent>.makeStream()
        let collector = Task { @MainActor in
            for await event in stream {
                log.append(AgentLogEntry(event: event))
            }
        }
        do {
            let result = try await loop.run(goal: goal) { event in
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
    /// a paused run deliberately leaves it in `awaitingApproval` so the
    /// hand-off to the task-detail window is the only way forward.
    private func finish(_ result: AgentLoopResult, taskID: UUID, service: any TaskServiceAPI) async {
        switch result {
        case .completed(let finalText):
            if !finalText.isEmpty {
                log.append(AgentLogEntry(kind: .assistant, text: "Assistant: \(finalText)"))
            }
            log.append(AgentLogEntry(kind: .info, text: "Run complete."))
            try? await service.complete(taskID: taskID)
        case .awaitingApproval(_, let description):
            log.append(AgentLogEntry(
                kind: .approval,
                text: "Paused for your approval: \(description). Open the task in the Jarvis menu to approve or reject it."
            ))
        case .exceededIterations(let lastText):
            if let lastText, !lastText.isEmpty {
                log.append(AgentLogEntry(kind: .assistant, text: "Assistant: \(lastText)"))
            }
            log.append(AgentLogEntry(
                kind: .error,
                text: "Stopped after reaching the iteration limit. Try a narrower goal."
            ))
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
