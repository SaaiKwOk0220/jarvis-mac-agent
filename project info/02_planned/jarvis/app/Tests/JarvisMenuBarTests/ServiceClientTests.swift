import XCTest
@testable import JarvisMenuBar
import JarvisDomain

@MainActor
final class ServiceClientTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodesTaskList() throws {
        let id = UUID()
        let body = try JSONEncoder().encode([Task(id: id, title: "demo")])
        let tasks = try ServiceClient.decodeTaskList(body, decoder: decoder)
        XCTAssertEqual(tasks.first?.id, id)
        XCTAssertEqual(tasks.first?.title, "demo")
    }

    func testDecodesApprovalRequest() throws {
        let request = ApprovalRequest(id: UUID(), taskID: UUID(), reason: "send email", target: "mail", payload: "hello", digest: "abc")
        let body = try JSONEncoder().encode(request)
        XCTAssertEqual(try ServiceClient.decodeApprovalRequest(body, decoder: decoder), request)
    }

    func testDecodesAPIError() throws {
        let body = Data(#"{"message":"request cannot be completed"}"#.utf8)
        XCTAssertEqual(try ServiceClient.decodeAPIError(body, decoder: decoder).message, "request cannot be completed")
    }

    func testUnavailableErrorIsStable() {
        XCTAssertEqual(ServiceClientError.unavailable.localizedDescription, "Jarvis service is unavailable")
    }

    func testRejectsMalformedTaskList() {
        XCTAssertThrowsError(try ServiceClient.decodeTaskList(Data("{}".utf8), decoder: decoder)) {
            XCTAssertEqual($0 as? ServiceClientError, .decoding)
        }
    }
}
