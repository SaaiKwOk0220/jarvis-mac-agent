import XCTest
@testable import JarvisMenuBar

final class SingleInstanceTests: XCTestCase {
    func testStorageFailureMessagesAreRecoverable() {
        let message = StartupFailure.message(for: POSIXError(.EACCES))
        XCTAssertTrue(message.contains("数据未删除"))
        XCTAssertTrue(message.contains("权限"))
        XCTAssertNotEqual(message, StartupFailure.message(for: SingleInstanceLock.LockError.alreadyRunning))
    }
    func testOtherProcessCannotAcquireHeldLock() throws {
        let path = NSTemporaryDirectory() + "jarvis-process-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lock = try SingleInstanceLock(path: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1], 'r+');\ntry: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(0)\nsys.exit(1)", path]
        try process.run()
        process.waitUntilExit()
        withExtendedLifetime(lock) { XCTAssertEqual(process.terminationStatus, 0) }
    }
    func testSymlinkLockIsRejected() throws {
        let base = NSTemporaryDirectory() + "jarvis-link-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createSymbolicLink(atPath: base, withDestinationPath: "/dev/null")
        XCTAssertThrowsError(try SingleInstanceLock(path: base)) { error in
            XCTAssertEqual(error as? SingleInstanceLock.LockError, .storageUnavailable)
            XCTAssertTrue(StartupFailure.message(for: error).contains("数据未删除"))
        }
    }
    func testSecondInstanceCannotAcquireLockUntilFirstReleases() throws {
        let path = NSTemporaryDirectory() + "jarvis-lock-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var first: SingleInstanceLock? = try SingleInstanceLock(path: path)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try SingleInstanceLock(path: path)) { error in
            XCTAssertEqual(error as? SingleInstanceLock.LockError, .alreadyRunning)
        }
        first = nil
        XCTAssertNoThrow(try SingleInstanceLock(path: path))
    }
}
