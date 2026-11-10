import Foundation
import GRDB
import JarvisPersistence

struct VoiceDraft: Equatable {
    let id: String
    let text: String
}

final class VoiceDraftStore {
    private let database: JarvisPersistence.Database
    init(database: JarvisPersistence.Database) throws {
        self.database = database
        try database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS voice_drafts (id TEXT PRIMARY KEY, text TEXT NOT NULL)")
        }
    }
    func save(_ text: String) throws -> String {
        let id = UUID().uuidString
        try database.write { db in
            try db.execute(sql: "INSERT INTO voice_drafts(id, text) VALUES (?, ?)", arguments: [id, text])
        }
        return id
    }
    func replace(_ oldID: String, with text: String) throws -> String {
        let id = UUID().uuidString
        try database.write { db in
            try db.execute(sql: "INSERT INTO voice_drafts(id, text) VALUES (?, ?)", arguments: [id, text])
            try db.execute(sql: "DELETE FROM voice_drafts WHERE id = ?", arguments: [oldID])
        }
        return id
    }
    func list() throws -> [VoiceDraft] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, text FROM voice_drafts ORDER BY rowid").map {
                VoiceDraft(id: $0["id"], text: $0["text"])
            }
        }
    }
    func delete(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM voice_drafts WHERE id = ?", arguments: [id])
        }
    }
}
