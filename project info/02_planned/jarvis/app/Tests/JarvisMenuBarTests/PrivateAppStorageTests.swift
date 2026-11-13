import XCTest
import Darwin
import SQLite3
@testable import JarvisMenuBar

final class PrivateAppStorageTests: XCTestCase {
    private func temporaryParent() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func mode(_ path: URL) throws -> mode_t {
        var value = stat()
        guard lstat(path.path, &value) == 0 else { throw POSIXError(.ENOENT) }
        return value.st_mode & 0o777
    }
    func testExperimentNamespacesRemainPrivateAndRejectUnknownPaths() throws {
        let parent = try temporaryParent()
        for name in ["Jarvis", "Jarvis-VAD-Experiment", "Jarvis-Safari-Experiment", "Jarvis-Browser-Experiment", "Jarvis-Combined-Experiment"] {
            let directory = try PrivateAppStorage.prepare(parent: parent, directoryName: name)
            XCTAssertEqual(directory.lastPathComponent, name)
            XCTAssertEqual(try mode(directory), 0o700)
            XCTAssertEqual(try mode(directory.appendingPathComponent("jarvis.sqlite")), 0o600)
        }
        XCTAssertThrowsError(try PrivateAppStorage.prepare(parent: parent, directoryName: "../other"))
    }
    func testNewAndExistingStorageIsPrivateAndKeepsContents() throws {
        let parent = try temporaryParent()
        let directory = try PrivateAppStorage.prepare(parent: parent)
        let file = directory.appendingPathComponent("jarvis.sqlite")
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(file), 0o600)
        try Data("existing".utf8).write(to: file)
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        _ = try PrivateAppStorage.prepare(parent: parent)
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file), Data("existing".utf8))
    }
    func testUmaskVariantsStillProducePrivateStorage() throws {
        let previous = umask(0o077)
        defer { _ = umask(previous) }
        for mask: mode_t in [0o000, 0o022, 0o077] {
            _ = umask(mask)
            let parent = try temporaryParent()
            let directory = try PrivateAppStorage.prepare(parent: parent)
            XCTAssertEqual(try mode(directory), 0o700)
            XCTAssertEqual(try mode(directory.appendingPathComponent("jarvis.sqlite")), 0o600)
        }
    }
    func testSQLiteSidecarsArePrivateWhenPresent() throws {
        let parent = try temporaryParent()
        let directory = try PrivateAppStorage.prepare(parent: parent)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("jarvis.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; CREATE TABLE private_test(value TEXT); INSERT INTO private_test VALUES ('private');", nil, nil, nil), SQLITE_OK)
        for name in ["jarvis.sqlite-wal", "jarvis.sqlite-shm"] {
            let sidecar = directory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "Expected SQLite sidecar \(name)")
            XCTAssertEqual(try mode(sidecar), 0o600)
        }
    }
    func testSymlinkSidecarIsRejected() throws {
        let parent = try temporaryParent()
        let directory = try PrivateAppStorage.prepare(parent: parent)
        let target = parent.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("jarvis.sqlite-wal"), withDestinationURL: target)
        XCTAssertThrowsError(try PrivateAppStorage.prepare(parent: parent))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }
    private func addACL(_ path: URL, rule: String = "everyone allow read") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", rule, path.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    func testACLOnDirectoryDatabaseAndSidecarsIsRejected() throws {
        for name in ["directory", "jarvis.sqlite", "jarvis.sqlite-wal", "jarvis.sqlite-shm"] {
            let parent = try temporaryParent()
            let directory = try PrivateAppStorage.prepare(parent: parent)
            let target = name == "directory" ? directory : directory.appendingPathComponent(name)
            if name != "directory" && name != "jarvis.sqlite" { try Data().write(to: target) }
            try addACL(target)
            XCTAssertThrowsError(try PrivateAppStorage.prepare(parent: parent)) { error in
                XCTAssertTrue(error.localizedDescription.contains("ACL"))
            }
        }
    }
    func testInheritedACLOnNewDirectoryIsRejected() throws {
        let parent = try temporaryParent()
        try addACL(parent, rule: "everyone allow readattr,readsecurity,file_inherit,directory_inherit")
        XCTAssertThrowsError(try PrivateAppStorage.prepare(parent: parent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ACL"))
        }
    }

    func testInheritedACLOnDatabaseAndSidecarsIsRejectedWithoutChangingACL() throws {
        for name in ["jarvis.sqlite", "jarvis.sqlite-wal", "jarvis.sqlite-shm"] {
            let parent = try temporaryParent()
            let directory = try PrivateAppStorage.prepareDirectory(parent: parent)
            try addACL(directory, rule: "everyone allow readattr,readsecurity,file_inherit,directory_inherit")
            let file = directory.appendingPathComponent(name)
            try Data("keep".utf8).write(to: file)
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { close(fd) }
            XCTAssertThrowsError(try PrivateAppStorage.requireEmptyACL(fd)) { error in
                XCTAssertTrue(error.localizedDescription.contains("ACL"))
            }
            XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        }
    }

    func testSymlinkDirectoryIsRejectedWithoutChangingTarget() throws {
        let parent = try temporaryParent()
        let target = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let before = try mode(target)
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("Jarvis"), withDestinationURL: target)
        XCTAssertThrowsError(try PrivateAppStorage.prepare(parent: parent))
        XCTAssertEqual(try mode(target), before)
    }
    func testSymlinkDatabaseIsRejectedWithoutChangingTarget() throws {
        let parent = try temporaryParent()
        let directory = try PrivateAppStorage.prepareDirectory(parent: parent)
        let target = parent.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("jarvis.sqlite"), withDestinationURL: target)
        XCTAssertThrowsError(try PrivateAppStorage.prepare(parent: parent))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }
}
