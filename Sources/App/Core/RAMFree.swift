import AppKit

// Free RAM: only the things that actually give memory back.
// 1. purge (helper)            → drops the inactive file cache
// 2. stop background hogs      → macOS analysis/indexing services; launchd restarts them later, smaller
// 3. relaunch grown apps       → a long-running browser/Electron app/Finder gives everything back and reopens
// 4. quit apps you pick        → the only fix when pressure is red and swap keeps growing

struct MemSnapshot: Equatable {
    var used: UInt64, compressed: UInt64, cached: UInt64, swap: UInt64, pressure: Int
    init(_ m: MemoryStats) { used = m.used; compressed = m.compressed; cached = m.cached; swap = m.swapUsed; pressure = m.pressure }

    /// Honest before → after line. Only reports what changed; never invents a "freed" total.
    static func report(_ a: MemSnapshot, _ b: MemSnapshot) -> String {
        func d(_ x: UInt64, _ y: UInt64) -> String {
            let diff = Int64(y) - Int64(x)
            return diff == 0 ? "±0" : (diff < 0 ? "−" : "+") + Fmt.mem(UInt64(abs(diff)))
        }
        let label = { (p: Int) in p >= 4 ? "Critical" : p >= 2 ? "Warning" : "Normal" }
        return "In use \(Fmt.mem(a.used)) → \(Fmt.mem(b.used)) (\(d(a.used, b.used))) · Compressed \(d(a.compressed, b.compressed)) · Swap \(d(a.swap, b.swap)) · Pressure \(label(a.pressure)) → \(label(b.pressure))"
    }
}

enum RAMFree {
    /// User-owned macOS services that are safe to stop: launchd starts them again when needed,
    /// usually much smaller. Never apps, never anything that holds your work.
    static let backgroundHogs: Set<String> = ["mediaanalysisd", "photoanalysisd", "mdworker_shared", "suggestd",
                                              "photolibraryd", "intelligenceplatformd", "knowledgeconstructiond",
                                              "corespotlightd", "mds_stores"]

    struct Stopped { var name: String; var bytes: UInt64 }

    /// Sends SIGTERM to your own background-service processes above `minBytes`.
    static func stopBackgroundHogs(minBytes: UInt64 = 80_000_000) -> [Stopped] {
        var out: [Stopped] = []
        let me = getuid()
        for p in ProcessList.all() where p.uid == me && backgroundHogs.contains(p.name) && p.footprint >= minBytes {
            if kill(p.pid, SIGTERM) == 0 { out.append(Stopped(name: p.name, bytes: p.footprint)) }
        }
        return out
    }

    /// Apps worth relaunching: they leak or grow over time and give everything back on restart.
    static func isRelaunchCandidate(_ a: AppUsage) -> Bool {
        guard a.isApp, let id = a.bundleID else { return false }
        if id == "com.apple.finder" { return a.memory > 400_000_000 }
        if browserIDs.contains(id) || isElectron(pid: a.pid) { return a.memory > 800_000_000 }
        return a.memory > 2_000_000_000
    }

    static let browserIDs: Set<String> = ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser",
                                          "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox", "com.apple.Safari"]

    static func isElectron(pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    static func tip(for a: AppUsage) -> String? {
        guard let id = a.bundleID else { return nil }
        switch id {
        case "com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac", "com.vivaldi.Vivaldi":
            return "Find the heavy tab: in \(a.name) press Shift+Esc (Task Manager) and sort by Memory. Turn on Settings ▸ Performance ▸ Memory Saver so idle tabs sleep."
        case "company.thebrowser.Browser": return "Arc: archive old tabs; Settings ▸ Performance lets idle tabs sleep."
        case "com.apple.Safari": return "Safari: close tabs you don't need; Window ▸ Merge All Windows makes it easier to see them."
        case "org.mozilla.firefox": return "Firefox: open about:processes to see which tab uses the most."
        case "com.apple.finder": return "Finder grows over time; a relaunch gives it back in a second."
        default: return isElectron(pid: a.pid) ? "\(a.name) is an Electron app (a full browser inside). A relaunch usually frees a lot." : nil
        }
    }

    enum RelaunchResult { case done, stillOpen, failed }

    /// Quits normally (the app saves or asks), waits, then opens it again in the background.
    /// Browsers reopen their tabs if "Continue where you left off" / session restore is on.
    static func relaunch(pid: pid_t) async -> RelaunchResult {
        guard let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL else { return .failed }
        let isFinder = app.bundleIdentifier == "com.apple.finder"
        guard app.terminate() else { return .failed }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if app.isTerminated { break }
        }
        guard app.isTerminated else { return .stillOpen }   // waiting on a "save changes?" dialog: leave it to the user
        if isFinder { try? await Task.sleep(nanoseconds: 800_000_000) }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg); return .done }
        catch { return .failed }
    }
}

/// Every process with its footprint (the same number as Activity Monitor's Memory column).
enum ProcessList {
    struct Proc { var pid: pid_t; var name: String; var uid: uid_t; var footprint: UInt64 }

    static func all() -> [Proc] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [Proc] = []
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            let name = withUnsafePointer(to: bsd.pbi_comm) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            out.append(Proc(pid: pid, name: name, uid: bsd.pbi_uid, footprint: ok == 0 ? ri.ri_phys_footprint : 0))
        }
        return out
    }
}
