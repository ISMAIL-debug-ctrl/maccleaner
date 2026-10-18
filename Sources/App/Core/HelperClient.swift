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
        }
    }

    func run(_ action: HelperAction, done: @escaping (HelperResult) -> Void = { _ in }) {
        guard busy == nil else { return }
        if alive {
            let cmd = HelperCommand(action: action)
            pending = (cmd.id, done)
            busy = action
            writeJSON(cmd, to: Paths.command(home: Self.home), mode: 0o600)
        } else if let shell = Self.fallback[action] {
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
