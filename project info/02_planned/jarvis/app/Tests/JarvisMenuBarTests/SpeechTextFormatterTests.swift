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
    func testImagesAndBareLinksDoNotReadURLs() {
        XCTAssertEqual(SpeechTextFormatter.prepare("![示意图](https://example.com/a.png) 看这里 https://example.com/page"), "示意图 看这里")
    }
    @MainActor
    func testEmptySpeechCompletesWithoutStartingPlayback() {
        let speaker = SystemVoiceSpeaker()
        var completion: Bool?
        speaker.speak(" \n ") { completion = $0 }
        XCTAssertEqual(completion, false)
    }
    func testEmptyInputIsEmpty() {
        XCTAssertEqual(SpeechTextFormatter.prepare(" \n \t"), "")
    }
}
