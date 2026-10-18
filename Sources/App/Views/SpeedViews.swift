import SwiftUI

// MARK: - Memory (the honest version)

struct MemoryBar: View {
    let m: MemoryStats
    var captions = false
    var body: some View {
        let total = Double(max(m.total, 1))
        let parts: [(String, UInt64, Color, String)] = [
            ("Apps", m.app, .blue, "what open apps hold in RAM"),
            ("Wired", m.wired, .orange, "macOS itself — can't be freed"),
            ("Compressed", m.compressed, .purple, "app memory squeezed to avoid swap"),
            ("Cached files", m.cached, .green.opacity(0.6), "macOS frees this by itself when needed"),
        ]
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { _, v, c, _ in
                        Rectangle().fill(c).frame(width: max(0, g.size.width * Double(v) / total))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 14)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(parts, id: \.0) { n, v, c, cap in
                    HStack(alignment: .top, spacing: 5) {
                        Circle().fill(c).frame(width: 8, height: 8).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(n) \(Fmt.mem(v))").font(.caption).fixedSize()
                            if captions { Text(cap).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
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

/// The big "Free RAM" action with its honest before → after result.
struct FreeRAMBox: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var prefs: Prefs
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { monitor.freeRAM() } label: {
                    Label(monitor.freeing ? "Freeing…" : "Free RAM", systemImage: "wind").frame(minWidth: compact ? 0 : 120)
                }
                .buttonStyle(.borderedProminent).controlSize(compact ? .regular : .large).disabled(monitor.freeing)
                if !compact {
                    Toggle("Also stop background services (Photos/Spotlight analysis — they restart later)", isOn: $prefs.stopBackgroundHogs)
                        .toggleStyle(.checkbox).font(.callout)
                }
            }
            if let r = monitor.lastFree {
                Text(r).font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MemoryView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var prefs: Prefs
    @State private var picked: Set<pid_t> = []

    var advice: String {
        let m = monitor.mem
        let swapGB = String(format: "%.1f", Double(m.swapUsed) / 1_073_741_824)
        if m.pressure >= 4 { return "Your Mac is out of memory and swapping \(swapGB) GB to disk — that's the slowness. Free RAM helps a little; quitting or relaunching the biggest app below helps a lot." }
        if m.pressure >= 2 || m.swapUsed > 4 << 30 { return "Memory is tight: \(swapGB) GB is parked in swap. Relaunch or quit one of the big apps below to get it back." }
        return "All good. Wired memory and the file cache make a 16 GB Mac sit around 50–70% in use — that's the baseline, not a problem."
    }

    var apps: [AppUsage] { monitor.apps.filter(\.isApp) }
    var candidates: [AppUsage] { monitor.apps.filter(RAMFree.isRelaunchCandidate).prefix(4).map { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .memory, text: "Free RAM, relaunch apps that have grown, and quit what you don't need.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        PressureBadge(m: monitor.mem)
                        Spacer()
                        Text("In use \(Fmt.mem(monitor.mem.used)) of \(Fmt.mem(monitor.mem.total)) · Swap \(Fmt.mem(monitor.mem.swapUsed))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    MemoryBar(m: monitor.mem, captions: true)
                    Text(advice).fixedSize(horizontal: false, vertical: true)

                    GroupBox { FreeRAMBox().padding(4).frame(maxWidth: .infinity, alignment: .leading) } label: {
                        Text("Free RAM").bold()
                    }

                    if !candidates.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(candidates) { a in
                                    HStack(alignment: .top) {
                                        AppIcon(pid: a.pid)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(a.name) — \(Fmt.mem(a.memory))").bold()
                                            if let tip = RAMFree.tip(for: a) { Text(tip).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                        }
                                        Spacer()
                                        Button("Relaunch") { monitor.relaunch(a) }
                                    }
                                }
                                Text("Relaunch quits the app normally (it saves or asks first) and opens it again. Browsers bring your tabs back if \"Continue where you left off\" is on; tabs then load only when you click them.")
                                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.padding(4)
                        } label: { Text("Relaunch apps that have grown").bold() }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(apps) { a in
                                HStack {
                                    Toggle("", isOn: Binding(get: { picked.contains(a.pid) }, set: { if $0 { picked.insert(a.pid) } else { picked.remove(a.pid) } }))
                                        .labelsHidden().toggleStyle(.checkbox)
                                    AppIcon(pid: a.pid)
                                    Text(a.name).lineLimit(1)
                                    if a.processes > 1 { Text("\(a.processes) processes").font(.caption2).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(Fmt.mem(a.memory)).monospacedDigit()
                                }
                            }
                            HStack {
                                Text("Memory = what the app and all its helper processes hold, the same number Activity Monitor shows. Part of it can be compressed or in swap, so one app can hold more than is in RAM right now.")
                                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Force Quit") { quit(force: true) }.disabled(picked.isEmpty)
                                Button("Quit selected") { quit(force: false) }.buttonStyle(.borderedProminent).disabled(picked.isEmpty)
                            }.padding(.top, 6)
                        }.padding(4)
                    } label: { Text("Open apps").bold() }
                }
                .padding(20)
            }
        }
    }

    func quit(force: Bool) {
        for a in apps where picked.contains(a.pid) { monitor.quit(a, force: force) }
        picked = []
    }
}

struct AppIcon: View {
    let pid: pid_t
    var size: CGFloat = 18
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape").frame(width: size, height: size).foregroundStyle(.secondary)
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
                    AppIcon(pid: a.pid)
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
                                    if scope == .user && it.plist.lastPathComponent != "com.ismailx.maccleaner.app.plist" {
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
                Toggle("Open at login (menu bar only)", isOn: $prefs.launchAtLogin)
                Toggle("Free RAM automatically when memory pressure turns yellow (purge + background services, max every 30 min; never quits apps)", isOn: $prefs.autoFreeRAM)
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
