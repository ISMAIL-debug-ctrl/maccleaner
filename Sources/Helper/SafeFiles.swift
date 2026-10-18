import Foundation
import SystemConfiguration

// MARK: - Safe file handling for root
//
// Rules:
// 1. Root never trusts or writes user-controlled paths. Input is only read with readUserJSON.
// 2. Deletion is descriptor based: every step uses openat/fstatat/unlinkat relative to a directory we
//    already hold open with O_NOFOLLOW. A symlink is removed as a link, never followed, so swapping a
//    folder for a link mid-way can't redirect root anywhere else.
// 3. Deletion never crosses into another volume (st_dev must match the starting folder).

/// The logged-in GUI user, or nil at the login window.
func consoleUser() -> (uid: uid_t, home: URL)? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          name != "loginwindow", uid != 0, let pw = getpwuid(uid) else { return nil }
    return (uid, URL(fileURLWithPath: String(cString: pw.pointee.pw_dir)))
}

/// Reads a small JSON file owned by `owner`. Refuses symlinks, FIFOs/devices, other owners and big files.
func readUserJSON<T: Decodable>(_ type: T.Type, at url: URL, owner: uid_t) -> T? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == owner,
          st.st_size > 0, st.st_size <= 16 * 1024 else { return nil }
    let size = Int(st.st_size)
    var data = Data(count: size)
    let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, size) }
    guard n == size else { return nil }
    return try? JSONDecoder.mc.decode(type, from: data)
}

/// Cheap change detector (inode + mtime + size) that does not follow symlinks.
func fingerprint(_ url: URL) -> String {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return "-" }
    return "\(st.st_ino):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_size)"
}

/// Makes sure our state dir is a real root-owned 0755 directory before writing into it.
func prepareRootDir() {
    let path = Paths.rootDir.path
    var st = stat()
    if lstat(path, &st) == 0, st.st_mode & S_IFMT != S_IFDIR || st.st_uid != 0 {
        rename(path, path + ".untrusted-\(Int(Date().timeIntervalSince1970))")
    }
    mkdir(path, 0o755)
    chown(path, 0, 0)
    chmod(path, 0o755)
}

/// Opens a fixed system folder for cleaning. It must be a real directory (not a link) owned by root.
func openSystemDir(_ path: String) -> (fd: Int32, dev: dev_t)? {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_uid == 0 else { close(fd); return nil }
    return (fd, st.st_dev)
}

/// Names inside an open directory (excluding . and ..), read through a duplicate descriptor.
func entries(of dirfd: Int32) -> [String] {
    let dupfd = dup(dirfd)
    guard dupfd >= 0, let dir = fdopendir(dupfd) else { if dupfd >= 0 { close(dupfd) }; return [] }
    defer { closedir(dir) }
    rewinddir(dir)
    var names: [String] = []
    while let e = readdir(dir) {
        let name = withUnsafePointer(to: e.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

func lstatAt(_ dirfd: Int32, _ name: String) -> stat? {
    var st = stat()
    return fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil
}

/// Allocated bytes of an entry and everything under it (no links followed, same volume only).
func measureAt(_ dirfd: Int32, _ name: String, dev: dev_t, depth: Int = 0) -> Int64 {
    guard depth < 64, let st = lstatAt(dirfd, name), st.st_dev == dev else { return 0 }
    var total = Int64(st.st_blocks) * 512
    if st.st_mode & S_IFMT == S_IFDIR {
        let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return total }
        defer { close(fd) }
        for child in entries(of: fd) { total += measureAt(fd, child, dev: dev, depth: depth + 1) }
    }
    return total
}

/// Deletes an entry and everything under it. Returns bytes freed. Never follows links, never leaves the volume.
@discardableResult
func removeAt(_ dirfd: Int32, _ name: String, dev: dev_t, depth: Int = 0) -> Int64 {
    guard depth < 64, let st = lstatAt(dirfd, name), st.st_dev == dev else { return 0 }
    let own = Int64(st.st_blocks) * 512
    if st.st_mode & S_IFMT == S_IFDIR {
        let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        // The folder we opened must be the one we looked at (guards against a swap in between).
        var now = stat()
        guard fstat(fd, &now) == 0, now.st_ino == st.st_ino, now.st_dev == st.st_dev else { close(fd); return 0 }
        var freed: Int64 = 0
        for child in entries(of: fd) { freed += removeAt(fd, child, dev: dev, depth: depth + 1) }
        close(fd)
        return unlinkat(dirfd, name, AT_REMOVEDIR) == 0 ? freed + own : freed
    }
    return unlinkat(dirfd, name, 0) == 0 ? own : 0
}
