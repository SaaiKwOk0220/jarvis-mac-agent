@preconcurrency import ApplicationServices

enum AccessibilityPermissionRequest {
    @discardableResult
    static func request(prompt: ([String: Bool]) -> Bool = { options in
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }) -> Bool { prompt([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]) }
    static func isTrusted() -> Bool { AXIsProcessTrusted() }
}
