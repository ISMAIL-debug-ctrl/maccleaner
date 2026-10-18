import Foundation

// The helper's actions and its command loop. Everything here is fixed: no paths, arguments or
// shell strings ever come from the user side, only a HelperAction name.

let helperVersion = "1.0"

func log(_ s: String) {
    FileHandle.standardError.write("[\(Date())] \(s)\n".data(using: .utf8)!)
}

/// Runs a fixed system tool with a clean environment. Returns (exit code, combined output).
@discardableResult
func run(_ tool: String, _ args: [String], timeout: TimeInterval = 3600) -> (Int32, String) {
    guard FileManager.default.isExecutableFile(atPath: tool) else { return (-1, "\(tool) not found") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    p.currentDirectoryURL = URL(fileURLWithPath: "/")
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    let deadline = DispatchTime.now() + timeout
    DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func human(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

// MARK: - System junk (fixed folders only)

struct SystemTarget {
    let name: String
    let path: String
    let maxDepth: Int
    /// Which entries may go. Only root-owned entries in world-writable /Library/Caches; users clean their own.
    let accept: (String, stat) -> Bool
}

let rotatedLog = try! NSRegularExpression(pattern: #"\.(gz|bz2|xz|zst|\d+)$"#)

let systemTargets: [SystemTarget] = [
    SystemTarget(name: "System caches", path: "/Library/Caches", maxDepth: 1) { _, st in st.st_uid == 0 },
    SystemTarget(name: "System crash reports", path: "/Library/Logs/DiagnosticReports", maxDepth: 2) { _, st in
        st.st_mode & S_IFMT == S_IFREG
    },
    SystemTarget(name: "Old system logs", path: "/private/var/log", maxDepth: 2) { name, st in
        st.st_mode & S_IFMT == S_IFREG && rotatedLog.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    },
]

/// Walks a target down to maxDepth, yielding (dirfd, name) for each accepted entry.
func forEachAccepted(_ t: SystemTarget, _ body: (Int32, String, dev_t) -> Void) {
    guard let (fd, dev) = openSystemDir(t.path) else { return }
    defer { close(fd) }
    func walk(_ dirfd: Int32, depth: Int) {
        for name in entries(of: dirfd) {
            guard let st = lstatAt(dirfd, name), st.st_dev == dev else { continue }
            if t.accept(name, st) {
                body(dirfd, name, dev)
            } else if depth + 1 < t.maxDepth, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == 0 {
                let sub = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard sub >= 0 else { continue }
                walk(sub, depth: depth + 1)
                close(sub)
            }
        }
    }
    walk(fd, depth: 0)
}

func localSnapshotCount() -> Int {
    let (_, out) = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 60)
    return out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
}

func scanSystemJunk() -> [SystemJunkItem] {
    var items = systemTargets.map { t -> SystemJunkItem in
        var bytes: Int64 = 0, count = 0
        forEachAccepted(t) { fd, name, dev in bytes += measureAt(fd, name, dev: dev); count += 1 }
        return SystemJunkItem(name: t.name, path: t.path, bytes: bytes, count: count)
    }
    items.append(SystemJunkItem(name: "Time Machine local snapshots", path: "/", bytes: 0, count: localSnapshotCount()))
    return items
}

func cleanSystemJunk() -> String {
    var freed: Int64 = 0, removed = 0
    for t in systemTargets {
        forEachAccepted(t) { fd, name, dev in
            let b = removeAt(fd, name, dev: dev)
            if b > 0 { freed += b; removed += 1 }
        }
    }
    return "Removed \(removed) items, \(human(freed)) freed"
}

// MARK: - Actions

func perform(_ action: HelperAction, status: inout HelperStatus) -> (Bool, String) {
    switch action {
    case .scanSystemJunk:
        status.systemJunk = scanSystemJunk()
        status.systemJunkScanned = Date()
        return (true, "Scanned")
    case .cleanSystemJunk:
        let msg = cleanSystemJunk()
        status.systemJunk = scanSystemJunk()
        status.systemJunkScanned = Date()
        return (true, msg)
    case .purgeRAM:
        let (c, o) = run("/usr/sbin/purge", [], timeout: 120)
        return (c == 0, c == 0 ? "Inactive file cache released" : o)
    case .flushDNS:
        let (c, o) = run("/usr/bin/dscacheutil", ["-flushcache"], timeout: 30)
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"], timeout: 30)
        return (c == 0, c == 0 ? "DNS cache flushed" : o)
    case .reindexSpotlight:
        let (c, o) = run("/usr/bin/mdutil", ["-E", "/"], timeout: 120)
        return (c == 0, c == 0 ? "Spotlight is rebuilding its index (can take a while)" : o)
    case .maintenanceScripts:
        if FileManager.default.isExecutableFile(atPath: "/usr/sbin/periodic") {
            let (c, o) = run("/usr/sbin/periodic", ["daily", "weekly", "monthly"])
            return (c == 0, c == 0 ? "Maintenance scripts finished" : o)
        }
        // macOS 15+ has no periodic: run what it used to run.
        let (c, o) = run("/usr/sbin/newsyslog", [], timeout: 300)
        run("/usr/libexec/locate.updatedb", [], timeout: 1800)
        return (c == 0, c == 0 ? "Logs rotated, locate database rebuilt" : o)
    case .thinSnapshots:
        let before = localSnapshotCount()
        let (c, o) = run("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "999999999999", "4"], timeout: 1800)
        let after = localSnapshotCount()
        return (c == 0, c == 0 ? "Local snapshots: \(before) → \(after)" : o)
    case .repairPermissions:
        // The uid comes from the system (console user), not from the command file.
        guard let user = consoleUser() else { return (false, "No user logged in") }
        let (c, o) = run("/usr/sbin/diskutil", ["resetUserPermissions", "/", String(user.uid)])
        return (c == 0, c == 0 ? "Home folder permissions reset" : o.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Loop

final class Helper {
    var status = HelperStatus(version: helperVersion)
    var lastCommandID: UUID?
    var lastRun: [HelperAction: Date] = [:]
    var inputPrint = ""
    let queue = DispatchQueue(label: "helper.work")
    let lock = NSLock()

    func save() {
        lock.lock(); defer { lock.unlock() }
        status.updated = Date()
        writeJSON(status, to: Paths.status)
    }

    func poll() {
        guard let user = consoleUser() else { return }
        let url = Paths.command(home: user.home)
        let print = "\(user.uid)|" + fingerprint(url)
        guard print != inputPrint else { return }
        inputPrint = print
        guard let cmd = readUserJSON(HelperCommand.self, at: url, owner: user.uid),
              cmd.id != lastCommandID, abs(cmd.created.timeIntervalSinceNow) < 60 else { return }
        lastCommandID = cmd.id
        lock.lock()
        let busy = status.running != nil
        lock.unlock()
        if busy { return }
        if let t = lastRun[cmd.action], Date().timeIntervalSince(t) < cmd.action.cooldown {
            finish(cmd, ok: false, message: "Just ran — try again in a moment")
            return
        }
        lastRun[cmd.action] = Date()
        lock.lock(); status.running = cmd.action; lock.unlock()
        save()
        log("run \(cmd.action.rawValue)")
        queue.async {
            var s = self.snapshot()
            let (ok, msg) = perform(cmd.action, status: &s)
            self.lock.lock()
            self.status.systemJunk = s.systemJunk
            self.status.systemJunkScanned = s.systemJunkScanned
            self.status.running = nil
            self.lock.unlock()
            self.finish(cmd, ok: ok, message: msg)
            log("done \(cmd.action.rawValue): \(msg)")
        }
    }

    func snapshot() -> HelperStatus { lock.lock(); defer { lock.unlock() }; return status }

    func finish(_ cmd: HelperCommand, ok: Bool, message: String) {
        lock.lock()
        status.last = HelperResult(id: cmd.id, action: cmd.action, ok: ok, message: String(message.prefix(500)), finished: Date())
        lock.unlock()
        save()
    }
}
