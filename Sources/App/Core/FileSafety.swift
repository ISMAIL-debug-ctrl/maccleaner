import Foundation

// Every deletion in the app goes through here.
//
// Two ways something can be deleted:
// 1. Junk (caches, logs, …): only entries strictly *inside* a whitelisted folder from JunkRules.
//    The folder itself is kept; it must be a real folder, not a link.
// 2. Files the user picked by hand (large files, duplicates, apps, leftovers): moved to the Trash.
//    Top-level personal and system folders themselves can never be deleted, whatever is selected.

struct Safety {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    /// Folders that must never be deleted themselves (their contents only through the rules above).
    var protectedFolders: Set<String> {
        let h = home.path
        let inHome = ["", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
                      "Applications", "Library", "Library/Preferences", "Library/Keychains", "Library/Mobile Documents",
                      "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Mail",
                      "Library/Messages", "Library/Photos", "Library/Caches", "Library/Logs", "Library/LaunchAgents",
                      "Library/CloudStorage", ".Trash", ".ssh", ".gnupg"]
        var s = Set(inHome.map { $0.isEmpty ? h : h + "/" + $0 })
        s.formUnion(["/", "/Applications", "/System", "/Library", "/Users", "/Volumes", "/private", "/usr", "/bin",
                     "/sbin", "/opt", "/cores", "/etc", "/var", "/tmp"])
        return s
    }


    /// True when `url` is strictly inside `root`, `root` is a real folder (not a link), and no folder
    /// between them is a link. The item itself may be a link — deleting it removes only the link.
    func isInside(_ url: URL, root: URL) -> Bool {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(r + "/"), !p.contains("/../"), isRealDirectory(r) else { return false }
        var dir = (p as NSString).deletingLastPathComponent
        while dir.count > r.count {
            guard isRealDirectory(dir) else { return false }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return true
    }

    func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether a hand-picked item may be moved to the Trash.
    func mayTrashUserSelection(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        guard !protectedFolders.contains(p), !p.contains("/../") else { return false }
        if p.hasPrefix(home.path + "/") { return true }
        if p.hasPrefix("/Applications/") { return p.hasSuffix(".app") && (2...3).contains(p.split(separator: "/").count) }
        if p.hasPrefix("/Volumes/") { return p.split(separator: "/").count >= 3 }
        return false  // other users' homes, system folders, anything else
    }
}

enum DeleteMode { case trash, permanent }

struct DeleteReport {
    var freed: Int64 = 0
    var count = 0
    var failed: [(URL, String)] = []
    var summary: String {
        var s = "\(count) items, \(Fmt.bytes(freed))"
        if !failed.isEmpty { s += " · \(failed.count) skipped" }
        return s
    }
}

enum Deleter {
    /// Deletes junk entries. Each must pass `Safety.isInside` for its rule root again right before removal.
    static func deleteJunk(_ items: [(url: URL, root: URL, bytes: Int64)], safety: Safety, mode: DeleteMode) -> DeleteReport {
        var r = DeleteReport()
        for it in items {
            guard safety.isInside(it.url, root: it.root) else { r.failed.append((it.url, "outside its folder")); continue }
            do {
                if mode == .trash { try FileManager.default.trashItem(at: it.url, resultingItemURL: nil) }
                else { try FileManager.default.removeItem(at: it.url) }
                r.freed += it.bytes; r.count += 1
            } catch {
                r.failed.append((it.url, error.localizedDescription))
            }
        }
        return r
    }

    /// Moves hand-picked files to the Trash (permanent only for Trash/privacy where that is the point).
    static func deleteSelected(_ items: [(url: URL, bytes: Int64)], safety: Safety, mode: DeleteMode = .trash) -> DeleteReport {
        var r = DeleteReport()
        for it in items {
            guard safety.mayTrashUserSelection(it.url) else { r.failed.append((it.url, "protected location")); continue }
            do {
                if mode == .trash { try FileManager.default.trashItem(at: it.url, resultingItemURL: nil) }
                else { try FileManager.default.removeItem(at: it.url) }
                r.freed += it.bytes; r.count += 1
            } catch {
                r.failed.append((it.url, error.localizedDescription))
            }
        }
        return r
    }
}

enum Sizer {
    /// Allocated size on disk; links are not followed.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                               options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func mem(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }
    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// Full Disk Access is needed for Trash, Mail and Safari. TCC.db is only readable with it.
enum FullDiskAccess {
    static var granted: Bool {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(p, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
