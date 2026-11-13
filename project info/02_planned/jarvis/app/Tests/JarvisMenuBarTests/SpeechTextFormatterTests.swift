import XCTest
@testable import JarvisMenuBar

final class SpeechTextFormatterTests: XCTestCase {
    func testChineseAndEnglishProseAndLinks() {
        XCTAssertEqual(SpeechTextFormatter.prepare("你好 **世界**，see [documentation](https://example.com/a?q=1)."), "你好 世界，see documentation.")
    }
    func testHeadingsListsAndInlineCode() {
        XCTAssertEqual(SpeechTextFormatter.prepare("# 标题\n- First `item`\n2. 第二项"), "标题\nFirst item\n第二项")
    }
    func testFencedCodePreservesContentWithoutFenceOrLanguage() {
        XCTAssertEqual(SpeechTextFormatter.prepare("Example:\n```swift\nprint(42)\n```"), "Example:\nprint(42)")
    }
    func testImagesAndBareLinksPreserveBareURLs() {
        XCTAssertEqual(SpeechTextFormatter.prepare("![示意图](https://example.com/a.png) 看这里 https://example.com/page"), "示意图 看这里 https://example.com/page")
    }
    @MainActor
    func testEmptySpeechCompletesWithoutStartingPlayback() {
        let speaker = SystemVoiceSpeaker()
        var completion: Bool?
        speaker.speak(" \n ") { completion = $0 }
        XCTAssertEqual(completion, false)
    }
    func testBareURLDoesNotConsumeAdjacentChineseWarning() {
        XCTAssertEqual(SpeechTextFormatter.prepare("访问https://example.com请勿输入密码"), "访问https://example.com请勿输入密码")
    }
    func testFencedCodePreservesURLsAndCommandSyntax() {
        let input = "```sh\ncurl https://example.com/a?x=1\n```"
        XCTAssertEqual(SpeechTextFormatter.prepare(input), "curl https://example.com/a?x=1")
    }
    func testURLOnlyRemainsSpeakable() {
        XCTAssertEqual(SpeechTextFormatter.prepare("https://example.com"), "https://example.com")
    }

    func testInlineCodeAndIdentifiersKeepOperatorsAndUnderscores() {
        XCTAssertEqual(SpeechTextFormatter.prepare("计算 `2 ** 3`，变量 foo__bar"), "计算 2 ** 3，变量 foo__bar")
    }
    func testUnpairedAndArithmeticMarkersRemainIntact() {
        XCTAssertEqual(SpeechTextFormatter.prepare("未闭合 ** 标记；2 ** 3"), "未闭合 ** 标记；2 ** 3")
    }
    func testPairedStrongMarkupStillCleans() {
        XCTAssertEqual(SpeechTextFormatter.prepare("**重要** 与 __重点__"), "重要 与 重点")
    }

    func testEmptyInputIsEmpty() {
        XCTAssertEqual(SpeechTextFormatter.prepare(" \n \t"), "")
    }
}

@MainActor private final class FormatterTestSpeaker: VoiceSpeaker {
    var spoken = ""
    func speak(_ text: String, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) {
        spoken = SpeechTextFormatter.prepare(text)
        onFinish(!spoken.isEmpty)
    }
    func stop() {}
}

@MainActor private final class FormatterTestBackend: VoiceBackend {
    var isOnDeviceSupported: Bool { false }
    func requestSpeechPermission() async -> Bool { false }
    func requestMicrophonePermission() async -> Bool { false }
    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable (Bool) -> Void, onSilence: @escaping @MainActor @Sendable () -> Void) throws {}
    func finish() {}
    func stop() {}
}

@MainActor final class SpeechPlaybackContinuationTests: XCTestCase {
    func testURLOnlyPlaybackCompletionCanResumeConversation() {
        let session = VoiceConversationSession()
        let token = session.begin()
        let speaker = FormatterTestSpeaker()
        let voice = VoiceCoordinator(backend: FormatterTestBackend(), speaker: speaker)
        var resumed = false
        voice.speak("https://example.com") { completed in
            session.playbackFinished(completed: completed, token: token, visible: true, serviceAvailable: true, isRunning: false, draft: "", voiceBusy: false) { resumed = true }
        }
        XCTAssertEqual(speaker.spoken, "https://example.com")
        XCTAssertTrue(resumed)
        XCTAssertTrue(session.isActive)
    }
}
