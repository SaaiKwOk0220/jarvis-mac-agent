import XCTest
@testable import JarvisMenuBar

final class OllamaDiagnosticTests: XCTestCase {
    func testModelListDistinguishesMissingAndPresent() {
        let data = Data(#"{"models":[{"name":"qwen3:4b-instruct"}]}"#.utf8)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 200, data: data, model: "qwen3:4b-instruct"), .ready)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 200, data: data, model: "other"), .modelMissing)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 500, data: data, model: "other"), .unexpectedResponse)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 200, data: Data(), model: "other"), .unexpectedResponse)
    }
}
