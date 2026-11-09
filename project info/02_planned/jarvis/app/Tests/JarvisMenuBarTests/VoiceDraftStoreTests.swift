import XCTest
import JarvisPersistence
@testable import JarvisMenuBar

final class VoiceDraftStoreTests: XCTestCase {
    func testDraftSurvivesStoreRecreationAndExplicitDelete() throws {
        let db = try JarvisPersistence.Database(path: ":memory:")
        let store = try VoiceDraftStore(database: db)
        let id = try store.save("未完成的问题")
        let reopened = try VoiceDraftStore(database: db)
        XCTAssertEqual(try reopened.list().map(\.text), ["未完成的问题"])
        try reopened.delete(id)
        XCTAssertTrue(try reopened.list().isEmpty)
    }
}
