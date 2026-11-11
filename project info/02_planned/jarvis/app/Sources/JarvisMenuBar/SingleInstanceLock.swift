import Darwin
import Foundation

/// Holds an advisory process lock until the app exits; never removes its lock file.
final class SingleInstanceLock {
    enum LockError: Error { case unavailable }
    private let descriptor: Int32

    static func defaultPath() throws -> String {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent(ExactBrowserExperiment.directoryName, isDirectory: true).appendingPathComponent("instance-lock", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw LockError.unavailable }
        return directory.appendingPathComponent("instance.lock").path
    }

    init(path: String? = nil) throws {
        let lockPath = try path ?? Self.defaultPath()
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LockError.unavailable }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(lockPath, &named) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG, opened.st_uid == getuid(),
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LockError.unavailable
        }
        var current = stat()
        guard lstat(lockPath, &current) == 0, current.st_dev == opened.st_dev,
              current.st_ino == opened.st_ino else { close(fd); throw LockError.unavailable }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
