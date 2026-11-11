import Darwin
import Foundation

/// Holds an advisory process lock until the app exits; never removes its lock file.
final class SingleInstanceLock {
    enum LockError: Error { case alreadyRunning, storageUnavailable }
    private let descriptor: Int32

    static func defaultPath() throws -> String {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = try PrivateAppStorage.prepareDirectory(parent: support, directoryName: AppStorageScope.currentDirectory).appendingPathComponent("instance-lock", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw LockError.storageUnavailable }
        return directory.appendingPathComponent("instance.lock").path
    }

    init(path: String? = nil) throws {
        let lockPath = try path ?? Self.defaultPath()
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LockError.storageUnavailable }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(lockPath, &named) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG, opened.st_uid == getuid(),
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
            close(fd)
            throw LockError.storageUnavailable
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            close(fd)
            throw busy ? LockError.alreadyRunning : LockError.storageUnavailable
        }
        var current = stat()
        guard lstat(lockPath, &current) == 0, current.st_dev == opened.st_dev,
              current.st_ino == opened.st_ino else { close(fd); throw LockError.storageUnavailable }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

/// Presents distinct, actionable startup errors without exposing filesystem details.
enum StartupFailure {
    static func message(for error: Error) -> String {
        if let lock = error as? SingleInstanceLock.LockError, lock == .alreadyRunning {
            return "Jarvis 已在运行，请切换到已有实例。"
        }
        if let storage = error as? PrivateAppStorage.StorageError { return storage.localizedDescription }
        return "无法安全打开 Jarvis 数据或锁文件。数据未删除；请检查数据目录的权限、符号链接和磁盘状态后重试。"
    }
}
