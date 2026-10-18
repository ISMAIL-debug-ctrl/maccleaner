import SwiftUI

// MARK: - Memory (the honest version)

struct MemoryBar: View {
    let m: MemoryStats
    var body: some View {
        let total = Double(max(m.total, 1))
        let parts: [(String, UInt64, Color)] = [("Apps", m.app, .blue), ("Wired", m.wired, .orange),
                                                ("Compressed", m.compressed, .purple), ("Cached files", m.cached, .green.opacity(0.6))]
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { _, v, c in
                        Rectangle().fill(c).frame(width: max(0, g.size.width * Double(v) / total))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 14)
            HStack(spacing: 12) {
                ForEach(parts, id: \.0) { n, v, c in
                    HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text("\(n) \(Fmt.mem(v))").font(.caption) }
                }
            }
        }
    }
}

struct PressureBadge: View {
    let m: MemoryStats
    var heavySwap: Bool { m.swapUsed > 4 << 30 }
    var color: Color { m.pressure >= 4 ? .red : (m.pressure >= 2 || heavySwap) ? .orange : .green }
    var body: some View {
        Label("Pressure: \(m.pressureLabel)" + (m.pressure < 2 && heavySwap ? " · heavy swap" : ""), systemImage: "circle.fill")
            .foregroundStyle(color).font(.headline)
    }
}

struct MemoryView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var helper: HelperClient
    @State private var before: MemoryStats?
    @State private var purgeNote: String?

    var advice: String {
        let m = monitor.mem
        let swapGB = Double(m.swapUsed) / 1_073_741_824
        if m.pressure >= 4 {
            return "Your Mac is short on memory right now and is moving app data to disk (swap \(String(format: "%.1f", swapGB)) GB). That is the slowness you feel. Quitting one or two of the apps below is the only thing that really helps."
        } else if m.pressure >= 2 || swapGB > 2 {
            return "Memory is tight: macOS is compressing and swapping (\(String(format: "%.1f", swapGB)) GB on disk). Close apps you aren't using — browsers with many tabs and Electron apps (Notion, Slack, Discord…) are usually the biggest."
        }
        return "All good. A high \"used\" number is normal: macOS keeps spare memory busy as a file cache and hands it back instantly when an app needs it."
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .memory, text: "What's really using your RAM, and what actually helps.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        PressureBadge(m: monitor.mem)
                        Spacer()
                        Text("Used \(Fmt.mem(monitor.mem.used)) of \(Fmt.mem(monitor.mem.total)) · Swap \(Fmt.mem(monitor.mem.swapUsed)) of \(Fmt.mem(monitor.mem.swapTotal))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    MemoryBar(m: monitor.mem)
                    Text(advice).fixedSize(horizontal: false, vertical: true)

                    GroupBox("Biggest memory users") {
                        VStack(alignment: .leading, spacing: 8) {
                            AppUsageList(limit: 12)
                            Text("Each app is counted with all its helper processes (a browser's tabs, an Electron app's renderers), including the part macOS compressed or moved to swap — so these can add up to more than the RAM in use right now.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(4)
                    }

                    GroupBox("Free up RAM") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Runs macOS's own `purge`: it empties the file cache (the green part). It does **not** shrink apps, and macOS refills the cache soon. Use it before a heavy render or export; quitting a big app frees far more.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button(helper.busy == .purgeRAM ? "Working…" : "Free up RAM") { purge() }.disabled(helper.busy != nil)
                                if let purgeNote { Text(purgeNote).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }

                    GroupBox("How to read this") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• **Pressure** is the number that matters. Green: fine. Yellow: macOS is compressing. Red: it's swapping to disk and things slow down.")
                            Text("• **Swap** is app memory parked on the SSD. A few GB that stays put is OK; if it keeps growing, you need fewer apps open (or more RAM).")
                            Text("• **Cached files** are free memory in disguise. \"Cleaners\" that show big \"freed GB\" numbers are mostly emptying this.")
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                .padding(20)
            }
        }
    }

    func purge() {
        before = monitor.mem
        helper.run(.purgeRAM) { r in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                monitor.refresh()
                guard let b = before, r.ok else { purgeNote = r.message; return }
                let a = monitor.mem
                let released = Int64(b.cached) - Int64(a.cached)
                purgeNote = "File cache released: \(Fmt.mem(UInt64(max(0, released)))). Pressure \(b.pressureLabel) → \(a.pressureLabel). App memory unchanged."
            }
        }
    }
}

/// Top apps by memory, with Quit buttons. Shared by the Memory view and the menu bar.
struct AppUsageList: View {
    @EnvironmentObject var monitor: Monitor
    var limit: Int
    var compact = false
    var body: some View {
        let rows = Array(monitor.apps.filter { $0.memory > 50_000_000 }.prefix(limit))
        let maxMem = Double(rows.first?.memory ?? 1)
        VStack(spacing: compact ? 4 : 6) {
            ForEach(rows) { a in
                HStack(spacing: 8) {
                    if let app = NSRunningApplication(processIdentifier: a.pid), let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "gearshape").frame(width: 18, height: 18).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(a.name).lineLimit(1)
                            if a.processes > 1 && !compact { Text("\(a.processes) processes").font(.caption2).foregroundStyle(.secondary) }
                        }
                        GeometryReader { g in
                            Capsule().fill(.blue.opacity(0.5)).frame(width: g.size.width * Double(a.memory) / maxMem)
                        }.frame(height: 3)
                    }
                    Text(Fmt.mem(a.memory)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    if !compact { Text(String(format: "%.0f%% CPU", a.cpu)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing) }
                    if a.isApp {
                        Button { monitor.quit(a) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Quit \(a.name)")
                            .contextMenu { Button("Force Quit") { monitor.quit(a, force: true) } }
                    } else {
                        Image(systemName: "xmark.circle").opacity(0).frame(width: 16)
                    }
                }
            }
        }
    }
}

// MARK: - Optimization

struct OptimizationView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var items: [LaunchItem] = []
    @State private var disabled: Set<String> = []
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .optimization, text: "Things that start by themselves and apps that use the most CPU right now. Turning off an agent is reversible.")
            Picker("", selection: $tab) { Text("Launch agents").tag(0); Text("Heavy consumers").tag(1); Text("Login items").tag(2) }
                .pickerStyle(.segmented).frame(width: 420).padding(.bottom, 8)
            switch tab {
            case 0:
                List {
                    ForEach([LaunchItem.Scope.user, .allAgents, .daemons], id: \.self) { scope in
                        Section(scope.rawValue + (scope == .user ? "" : " (view only — need admin to change)")) {
                            ForEach(items.filter { $0.scope == scope }) { it in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(it.label)
                                        Text((it.program ?? "—") + " · " + it.signer).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    if scope == .user && it.plist.lastPathComponent != LoginItem.label + ".plist" {
                                        let off = disabled.contains(it.label)
                                        Toggle(off ? "Off" : "On", isOn: Binding(get: { !off }, set: { on in
                                            _ = on ? LoginItems.enable(it) : LoginItems.disable(it); reload()
                                        })).toggleStyle(.switch)
                                    }
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([it.plist]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            case 1:
                ScrollView {
                    let cpu = monitor.apps.sorted { $0.cpu > $1.cpu }.prefix(10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("By CPU").font(.headline)
                        ForEach(Array(cpu)) { a in
                            HStack { Text(a.name); Spacer(); Text(String(format: "%.0f%%", a.cpu)).monospacedDigit()
                                Text(Fmt.mem(a.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                                if a.isApp { Button("Quit") { monitor.quit(a) } }
                            }
                        }
                        Divider().padding(.vertical, 8)
                        Text("By memory").font(.headline)
                        AppUsageList(limit: 10)
                    }.padding(20)
                }
            default:
                VStack(spacing: 12) {
                    Spacer()
                    Text("macOS keeps the list of Login Items and background items to itself. Manage them in System Settings.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Open Login Items settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    Spacer()
                }.padding(40)
            }
        }
        .onAppear { reload() }
    }

    func reload() {
        Task {
            let (i, d) = await Task.detached { (LoginItems.list(), LoginItems.disabledLabels()) }.value
            items = i; disabled = d
        }
    }
}

// MARK: - Maintenance

struct MaintenanceView: View {
    @EnvironmentObject var helper: HelperClient
    @State private var confirm: HelperAction?
    @State private var lsResult: String?

    let tasks: [(HelperAction, String)] = [
        (.purgeRAM, "Empties the file cache. Quick; useful before a heavy app."),
        (.flushDNS, "Fixes sites that won't load after a network or DNS change."),
        (.thinSnapshots, "Deletes Time Machine's local snapshots to free disk space (backups on your drive are not touched)."),
        (.maintenanceScripts, "Rotates system logs and rebuilds the locate database — what macOS's periodic scripts used to do."),
        (.reindexSpotlight, "Rebuilds the Spotlight index. Fixes broken search. Your Mac will be busy indexing for a while."),
        (.repairPermissions, "Resets permissions in your home folder. Fixes 'you don't have permission' errors on your own files. Can take a few minutes."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .maintenance, text: helper.alive ? "Helper installed — these run without a password." : "Each task asks for your password (or install the helper once with ./install.sh).")
            List {
                ForEach(tasks, id: \.0) { a, text in
                    HStack {
                        VStack(alignment: .leading) { Text(a.title).bold(); Text(text).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if helper.busy == a { ProgressView().controlSize(.small) }
                        Button("Run") { confirm = a }.disabled(helper.busy != nil)
                    }.padding(.vertical, 4)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("Rebuild Launch Services").bold()
                        Text("Fixes duplicate entries in 'Open With' and wrong default apps. No password needed.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let lsResult { Text(lsResult).font(.caption).foregroundStyle(.green) }
                    Button("Run") {
                        Task.detached {
                            let r = Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                                              ["-kill", "-r", "-domain", "local", "-domain", "user"], timeout: 600)
                            await MainActor.run { lsResult = r.code == 0 ? "Done" : "Failed" }
                        }
                    }
                }.padding(.vertical, 4)
            }
            if let m = helper.lastMessage {
                HStack { Image(systemName: "info.circle"); Text(m); Spacer() }.padding(12)
            }
        }
        .confirmationDialog(confirm.map { "\($0.title)?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Run") { if let a = confirm { helper.run(a) }; confirm = nil }
        }
    }
}

// MARK: - Protection

struct ProtectionView: View {
    @State private var items: [LaunchItem] = []
    @State private var exts: [Protection.Extension] = []
    @State private var loading = true
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .protection, text: "Not an antivirus. It lists what starts by itself and what runs inside your browsers, and flags patterns adware uses: unsigned programs, hidden or temp folders, scripts, things added this week.")
            if loading { BusyView(text: "Checking launch items and extensions…") }
            else {
                List {
                    Section("Launch items" + (showAll ? "" : " — flagged only")) {
                        Toggle("Show all, including signed and Apple ones", isOn: $showAll)
                        let shown = items.filter { showAll || (!$0.flags.isEmpty && $0.signer != "Apple") }
                        if shown.isEmpty { Label("Nothing suspicious", systemImage: "checkmark.shield").foregroundStyle(.green) }
                        ForEach(shown) { it in
                            HStack(alignment: .top) {
                                Image(systemName: it.flags.isEmpty ? "checkmark.shield" : "exclamationmark.shield").foregroundStyle(it.flags.isEmpty ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(it.label).bold()
                                    Text(it.program ?? "—").font(.caption).lineLimit(1).truncationMode(.middle)
                                    Text("Signed by: \(it.signer) · \(it.scope.rawValue)" + (it.flags.isEmpty ? "" : " · " + it.flags.joined(separator: ", ")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([it.plist]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            }
                        }
                    }
                    Section("Browser extensions (\(exts.count))") {
                        ForEach(exts) { e in
                            HStack {
                                Image(systemName: e.risky ? "exclamationmark.triangle" : "puzzlepiece.extension").foregroundStyle(e.risky ? .orange : .secondary)
                                VStack(alignment: .leading) {
                                    Text(e.name).bold()
                                    Text("\(e.browser) · v\(e.version)" + (e.risky ? " · can read/change data on websites" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if e.browser != "Safari" {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([e.folder]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        Text("Remove extensions from inside the browser (Extensions page) so it also cleans its own settings.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            let (i, e) = await Task.detached { (LoginItems.list(), Protection.extensions()) }.value
            items = i; exts = e; loading = false
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var helper: HelperClient

    var body: some View {
        Form {
            Section("Cleaning") {
                Toggle("Keep browser caches (faster sites, no re-downloads)", isOn: $prefs.keepBrowserCaches)
                Toggle("Skip caches of apps that are open", isOn: $prefs.skipRunningApps)
                Toggle("Move junk to the Trash instead of deleting it", isOn: $prefs.junkToTrash)
            }
            Section("Menu bar") {
                Toggle("Show RAM % in the menu bar", isOn: $prefs.showPercentInMenuBar)
                Toggle("Open at login (menu bar only)", isOn: $prefs.launchAtLogin)
            }
            Section("Helper") {
                LabeledContent("Root helper", value: helper.alive ? "Running (v\(helper.status.version))" : "Not installed")
                Text("Needed for system caches and password-free maintenance. Install with ./install.sh from the repo folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                LabeledContent("Version", value: updater.version)
                HStack {
                    switch updater.state {
                    case .available(let n): Text("\(n) new change\(n == 1 ? "" : "s") available")
                    case .upToDate: Text("Up to date")
                    case .checking: Text("Checking…")
                    case .updating: Text("Updating…")
                    case .failed(let s): Text(s)
                    case .idle: Text("")
                    }
                    Spacer()
                    if case .available = updater.state { Button("Update now") { updater.update() }.buttonStyle(.borderedProminent) }
                    Button("Check") { updater.check() }.disabled(updater.state == .checking || updater.state == .updating)
                }
                if updater.repo == nil { Text("Built outside a git clone — updates are off.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("About") {
                Text("MacCleaner is free and open source (PolyForm Noncommercial). It never sends your data anywhere; the only network calls are update checks (GitHub) and the app update lookups you start.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("github.com/ISMAIL-debug-ctrl/maccleaner", destination: URL(string: "https://github.com/ISMAIL-debug-ctrl/maccleaner")!)
            }
        }
        .formStyle(.grouped)
    }
}
