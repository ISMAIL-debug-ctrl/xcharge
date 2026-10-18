import Foundation
import SystemConfiguration

// MARK: - Safe file handling (root never trusts or writes user-controlled paths)

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
          st.st_size > 0, st.st_size <= 64 * 1024 else { return nil }
    let size = Int(st.st_size)
    var data = Data(count: size)
    let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, size) }
    guard n == size else { return nil }
    return try? JSONDecoder.xc.decode(type, from: data)
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
        // Not ours (symlink, file, or planted by someone else): move it aside, never write through it.
        rename(path, path + ".untrusted-\(Int(Date().timeIntervalSince1970))")
    }
    mkdir(path, 0o755)
    chown(path, 0, 0)
    chmod(path, 0o755)
}

/// v1.0–1.2 used a world-writable /Users/Shared/XCharge. Remove it without following any links.
func removeLegacySharedDir() {
    let fd = open(Paths.legacySharedDir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return }
    for name in ["status.json", "settings.json", "command.json", "update.log"] { unlinkat(fd, name, 0) }
    close(fd)
    rmdir(Paths.legacySharedDir)  // only if empty; rmdir never follows a symlink
}
