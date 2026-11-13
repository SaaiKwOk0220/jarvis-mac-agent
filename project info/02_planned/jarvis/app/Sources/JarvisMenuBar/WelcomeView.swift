import SwiftUI
@preconcurrency import ApplicationServices

/// First-launch onboarding window. Renders four worker cards (Terminal /
/// WebFetch / Screenshot / AX) summarizing what each menu-bar entry does
/// and where its key configuration lives, then dismisses itself and
/// persists a `UserDefaults` flag so it only shows once per install.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Jarvis").font(.title).bold()
                Text("Mac-first personal agent foundation. Pick a worker from the menu bar to start a task; each task gets its own approval window.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()

            Text("Four worker types").font(.headline)

            VStack(spacing: 10) {
                workerCard(
                    icon: "terminal",
                    title: "Run pwd (approval required)",
                    body: "Only pwd is currently supported; each invocation requires explicit approval."
                )
                workerCard(
                    icon: "globe",
                    title: "Fetch URL",
                    body: "HTTPS GET via URLSession. Auto-allowed if the site is in PolicyConfig.sites; otherwise the request is denied without a prompt."
                )
                workerCard(
                    icon: "camera",
                    title: "Capture screenshot",
                    body: "ScreenCaptureKit (macOS 14+). Requires Screen Recording permission under System Settings > Privacy & Security."
                )
                workerCard(
                    icon: "accessibility",
                    title: "Inspect accessibility",
                    body: "AXUIElement tree walker. Requires Accessibility permission, and the target bundle ID must be in PolicyConfig.applicationBundleIDs."
                )
            }

            Button("请求辅助功能权限") {
                AccessibilityPermissionRequest.request()
            }
            Text("请在系统设置 → 隐私与安全性 → 辅助功能中允许当前 Jarvis 应用；授权后返回并重新提交请求。")
                .font(.caption).foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Text("Allowed apps and sites are configured in PolicyConfig.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
                Button("Get started") { getStarted() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One worker description rendered as a bordered card. Mirrors the
    /// `New<Task>View` style of using `.title2` headings and a small icon.
    private func workerCard(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3))
        )
    }

    private func getStarted() {
        UserDefaults.standard.set(true, forKey: Self.welcomedDefaultsKey)
        dismiss()
    }

    /// UserDefaults key for the "welcomed" flag. Centralized so the flag
    /// contract lives in one place even though SwiftUI views are not
    /// exercised by the unit-test target.
    static let welcomedDefaultsKey = "jarvis.welcomed"
}

enum AccessibilityPermissionRequest {
    @discardableResult
    static func request(prompt: ([String: Bool]) -> Bool = { options in
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }) -> Bool {
        prompt([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true])
    }
    static func isTrusted() -> Bool { AXIsProcessTrusted() }
}
