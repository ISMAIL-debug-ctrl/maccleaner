import Foundation

// Talks to the root helper by writing a fixed action name to our own command.json.
// If the helper isn't installed, the few actions that need admin rights fall back to a one-off
// macOS password prompt running the same fixed command (never anything built from user input).

@MainActor
final class HelperClient: ObservableObject {
    @Published private(set) var status = HelperStatus()
    @Published private(set) var alive = false
    @Published private(set) var busy: HelperAction?
    @Published var lastMessage: String?
    private var pending: (UUID, (HelperResult) -> Void)?
    private var sentAt = Date.distantPast
    private var timer: Timer?

    static let home = FileManager.default.homeDirectoryForCurrentUser

    init() {
        try? FileManager.default.createDirectory(at: Paths.userDir(home: Self.home), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let s = readJSON(HelperStatus.self, from: Paths.status) else {
            if alive { alive = false }
            return
        }
        let a = Date().timeIntervalSince(s.updated) < 15
        if a != alive { alive = a }
        if s != status { status = s }
        if let (id, done) = pending, let last = s.last, last.id == id {
            pending = nil
            busy = nil
            lastMessage = last.message
            done(last)
        } else if let (id, done) = pending, let a = busy, s.running != a, Date().timeIntervalSince(sentAt) > 20 {
            // The helper never picked it up (it was busy with something else): don't stay stuck.
            pending = nil
            busy = nil
            let r = HelperResult(id: id, action: a, ok: false, message: "The helper was busy — try again", finished: Date())
            lastMessage = r.message
            done(r)
        }
    }

    /// The helper is installed (its launchd plist exists), even if its heartbeat is late right now.
    nonisolated static var installed: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(Paths.helperLabel).plist")
    }

    func run(_ action: HelperAction, done: @escaping (HelperResult) -> Void = { _ in }) {
        guard busy == nil else { return }
        if alive {
            send(action, done: done)
        } else if Self.installed {
            // Installed but quiet (restarting, or the Mac just woke): wait for it instead of asking for a password.
            busy = action
            Task {
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    refresh()
                    if alive { busy = nil; send(action, done: done); return }
                }
                busy = nil
                let r = HelperResult(id: UUID(), action: action, ok: false, message: "The helper isn't responding — try again in a moment", finished: Date())
                lastMessage = r.message
                done(r)
            }
        } else if let shell = Self.fallback[action] {
            // No helper at all: ask once for this action (the README explains how to install the helper instead).
            busy = action
            Task.detached {
                let ok = Self.askPassword(shell, prompt: "MacCleaner needs your password to \(action.prompt).")
                let r = HelperResult(id: UUID(), action: action, ok: ok, message: ok ? action.doneText : "Cancelled", finished: Date())
                await MainActor.run { self.busy = nil; self.lastMessage = r.message; done(r) }
            }
        } else {
            lastMessage = "Install the helper first (./install.sh) for this one."
        }
    }

    private func send(_ action: HelperAction, done: @escaping (HelperResult) -> Void) {
        let cmd = HelperCommand(action: action)
        pending = (cmd.id, done)
        busy = action
        sentAt = Date()
        writeJSON(cmd, to: Paths.command(home: Self.home), mode: 0o600)
    }

    /// Fixed commands for the no-helper case. System junk cleaning needs the helper's safe deletion code.
    nonisolated static let fallback: [HelperAction: String] = [
        .purgeRAM: "/usr/sbin/purge",
        .flushDNS: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder",
        .reindexSpotlight: "/usr/bin/mdutil -E /",
        .thinSnapshots: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4",
        .maintenanceScripts: "/usr/sbin/newsyslog; /usr/libexec/locate.updatedb",
        .repairPermissions: "/usr/sbin/diskutil resetUserPermissions / \(getuid())",
    ]

    nonisolated static func askPassword(_ shell: String, prompt: String) -> Bool {
        let script = "do shell script \"\(shell)\" with administrator privileges with prompt \"\(prompt)\""
        return Shell.run("/usr/bin/osascript", ["-e", script], timeout: 3600).code == 0
    }
}

extension HelperAction {
    var title: String {
        switch self {
        case .scanSystemJunk: return "Scan system junk"
        case .cleanSystemJunk: return "Clean system junk"
        case .purgeRAM: return "Free up RAM"
        case .flushDNS: return "Flush DNS cache"
        case .reindexSpotlight: return "Reindex Spotlight"
        case .maintenanceScripts: return "Run maintenance scripts"
        case .thinSnapshots: return "Thin Time Machine snapshots"
        case .repairPermissions: return "Repair home folder permissions"
        }
    }
    var prompt: String { title.lowercased() }
    var doneText: String { "\(title): done" }
}
