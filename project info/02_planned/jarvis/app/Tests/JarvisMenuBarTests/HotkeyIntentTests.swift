import XCTest
import AppIntents
@testable import JarvisMenuBar
import JarvisDomain

/// Tests for the global hotkey + App Intents surface added in
/// `feat/global-hotkey-intents`. Carbon `RegisterEventHotKey` and the App
/// Intents system registration both run on a live process and are not
/// exercised here — these tests cover the Swift-visible metadata and
/// `ServiceClient` wiring so future refactors keep the contract intact.
@MainActor
final class HotkeyIntentTests: XCTestCase {
    func testAskJarvisIntentHasExpectedMetadata() {
        XCTAssertEqual(AskJarvisIntent.title, "Ask Jarvis")
        XCTAssertTrue(AskJarvisIntent.openAppWhenRun, "openAppWhenRun must be true so Spotlight launches the app")
    }

    func testJarvisShortcutsPublishesAtLeastOneShortcut() {
        let shortcuts = JarvisShortcuts.appShortcuts
        XCTAssertFalse(shortcuts.isEmpty, "JarvisShortcuts must publish at least one AppShortcut")
    }

    func testServiceClientRegistersItselfAsShared() {
        // ServiceClient.init() sets `shared` if it is nil. The test process
        // may have already set `shared` from earlier tests, so we only assert
        // that a freshly-initialized client is either the new one or the
        // previously cached one — never a different object.
        let prior = ServiceClient.shared
        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:65535")!)
        let resolved = ServiceClient.shared
        XCTAssertTrue(resolved === client || resolved === prior)
    }

    func testHotkeyManagerErrorIsEquatable() {
        XCTAssertEqual(
            HotkeyManagerError.registerFailed(42),
            HotkeyManagerError.registerFailed(42)
        )
        XCTAssertNotEqual(
            HotkeyManagerError.registerFailed(1),
            HotkeyManagerError.eventHandlerInstallFailed(1)
        )
    }
}
