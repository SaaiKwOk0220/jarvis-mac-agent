import AppIntents

/// App Intent that surfaces Jarvis from Spotlight, Siri, or the macOS Shortcuts
/// app. Triggers the same floating-panel action as the Cmd+Shift+J global
/// hotkey, so both entry points see the same `TaskListView` and the same
/// underlying service data.
///
/// `openAppWhenRun` is `true` so the user sees the panel; App Shortcuts on
/// macOS can otherwise invoke the intent in the background.
struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Jarvis"
    static let description = IntentDescription("Opens Jarvis to view tasks and create new ones.")
    static let openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Open Jarvis")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        HotkeyAction.perform()
        return .result()
    }
}

/// App Shortcuts provider that publishes the "Ask Jarvis" phrase to Spotlight
/// and Siri. Every phrase must include `\.applicationName` as a disambiguator
/// or the phrase fails at runtime (per Apple's App Intents guide).
struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskJarvisIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Show \(.applicationName) tasks",
                "Open \(.applicationName)"
            ],
            shortTitle: "Ask Jarvis",
            systemImageName: "bolt.horizontal.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .tangerine
}
