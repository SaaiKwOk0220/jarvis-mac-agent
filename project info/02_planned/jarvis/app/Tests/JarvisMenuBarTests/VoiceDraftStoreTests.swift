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
    func testDraftSurvivesDatabaseCloseAndReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let database = try JarvisPersistence.Database(path: path)
            let store = try VoiceDraftStore(database: database)
            _ = try store.save("需要恢复")
        }
        let database = try JarvisPersistence.Database(path: path)
        let reopened = try VoiceDraftStore(database: database)
        XCTAssertEqual(try reopened.list().map(\.text), ["需要恢复"])
    }

    func testFailedDeleteRetainsDraft() throws {
        let database = try JarvisPersistence.Database(path: ":memory:")
        let store = try VoiceDraftStore(database: database)
        let id = try store.save("保留我")
        try database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_delete BEFORE DELETE ON voice_drafts BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        }
        XCTAssertThrowsError(try store.delete(id))
        XCTAssertEqual(try store.list().map(\.text), ["保留我"])
    }

    func testFailedSaveDoesNotCreateDraft() throws {
        let database = try JarvisPersistence.Database(path: ":memory:")
        let store = try VoiceDraftStore(database: database)
        try database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_insert BEFORE INSERT ON voice_drafts BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        }
        XCTAssertThrowsError(try store.save("未保存"))
        XCTAssertTrue(try store.list().isEmpty)
    }
    func testReplacingDraftRollsBackWhenOldDeleteFails() throws {
        let database = try JarvisPersistence.Database(path: ":memory:")
        let store = try VoiceDraftStore(database: database)
        let id = try store.save("旧内容")
        try database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_delete BEFORE DELETE ON voice_drafts BEGIN SELECT RAISE(ABORT, 'blocked'); END")
        }
        XCTAssertThrowsError(try store.replace(id, with: "新内容"))
        XCTAssertEqual(try store.list().map(\.text), ["旧内容"])
    }
}
