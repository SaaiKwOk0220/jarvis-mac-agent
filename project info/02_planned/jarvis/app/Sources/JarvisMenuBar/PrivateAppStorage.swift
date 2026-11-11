import Foundation
import Darwin

/// Prepares private storage without following leaf symlinks.
/// Same-user concurrent path replacement between this check and SQLite opening the
/// path is outside this protection's threat model.
enum PrivateAppStorage {
    enum StorageError: LocalizedError {
        case unsafeACL
        var errorDescription: String? {
            "Jarvis 数据目录或数据库具有额外访问控制权限。请检查文件共享和权限设置，移除不需要的 ACL 后重试；现有数据未删除。"
        }
    }
    static func requireEmptyACL(_ fd: Int32) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // On macOS ENOENT for a valid descriptor means no extended ACL.
            if errno == ENOENT { return }
            throw POSIXError(.EACCES)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        if result == 0 { throw StorageError.unsafeACL }
        throw POSIXError(.EACCES)
    }
    static func prepareDirectory(parent: URL) throws -> URL {
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw POSIXError(.EACCES) }
        defer { close(parentFD) }
        if mkdirat(parentFD, "Jarvis", 0o700) != 0 && errno != EEXIST { throw POSIXError(.EACCES) }
        let directoryFD = openat(parentFD, "Jarvis", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw POSIXError(.EACCES) }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else { throw POSIXError(.EACCES) }
        try requireEmptyACL(directoryFD)
        guard fchmod(directoryFD, 0o700) == 0 else { throw POSIXError(.EACCES) }
        return parent.appendingPathComponent("Jarvis", isDirectory: true)
    }

    static func prepare(parent: URL) throws -> URL {
        let directory = try prepareDirectory(parent: parent)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw POSIXError(.EACCES) }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid() else { throw POSIXError(.EACCES) }
        let fileFD = openat(directoryFD, "jarvis.sqlite", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fileFD) }
        guard fstat(fileFD, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else { throw POSIXError(.EACCES) }
        try requireEmptyACL(fileFD)
        guard fchmod(fileFD, 0o600) == 0 else { throw POSIXError(.EACCES) }
        for name in ["jarvis.sqlite-wal", "jarvis.sqlite-shm"] {
            let sidecar = openat(directoryFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            if sidecar < 0 {
                guard errno == ENOENT else { throw POSIXError(.EACCES) }
                continue
            }
            defer { close(sidecar) }
            guard fstat(sidecar, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw POSIXError(.EACCES) }
            try requireEmptyACL(sidecar)
            guard fchmod(sidecar, 0o600) == 0 else { throw POSIXError(.EACCES) }
        }
        return directory
    }
}
