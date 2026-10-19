import SwiftUI

/// The menu bar panel: a small MacCleaner. Each tab lets you act right there.
struct MonitorPanel: View {
    enum Tab: String, CaseIterable { case memory = "Memory", cleanup = "Cleanup", cpu = "CPU", storage = "Storage"
        var icon: String {
            switch self { case .memory: "memorychip"; case .cleanup: "trash.circle"; case .cpu: "cpu"; case .storage: "internaldrive" }
        }
    }
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var updater: Updater
    @AppStorage("panelTab") private var tab: Tab = .memory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("MacCleaner").font(.headline)
                Spacer()
                PressureBadge(m: monitor.mem).font(.caption)
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden()

            Group {
                switch tab {
                case .memory: MemoryTab()
                case .cleanup: CleanupTab()
                case .cpu: CPUTab()
                case .storage: StorageTab(open: open)
                }
            }
            .frame(minHeight: 230, alignment: .top)

            Divider()
            if case .available = updater.state {
                Button("Update available — install") { updater.update() }.font(.caption)
            }
            HStack {
                Button("Open MacCleaner") { open(nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    func open(_ module: Module?) { MainWindow.open(module) }
}

private struct MemoryTab: View {
    @EnvironmentObject var monitor: Monitor
    var body: some View {
        let m = monitor.mem
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("In use \(Fmt.mem(m.used)) of \(Fmt.mem(m.total))").monospacedDigit()
                Spacer()
                Text("Swap \(Fmt.mem(m.swapUsed))").monospacedDigit().foregroundStyle(m.swapUsed > 4 << 30 ? .orange : .secondary)
            }.font(.callout)
            MemoryBar(m: m)
            FreeRAMBox(compact: true)
            Text("Using the most memory").font(.caption).foregroundStyle(.secondary)
            AppUsageList(limit: 5, compact: true)
            if let top = monitor.apps.first(where: RAMFree.isRelaunchCandidate) {
                HStack {
                    Text("\(top.name) has grown to \(Fmt.mem(top.memory))").font(.caption)
                    Spacer()
                    Button("Relaunch") { monitor.relaunch(top) }.controlSize(.small)
                }
            }
        }
    }
}

private struct CleanupTab: View {
    @EnvironmentObject var prefs: Prefs
    @State private var junk: [JunkCategory] = []
    @State private var trash: [JunkItem] = []
    @State private var scanning = false
    @State private var confirm = false
    @State private var result: String?

    var junkBytes: Int64 { junk.reduce(0) { $0 + $1.selectedBytes } }
    var trashBytes: Int64 { trash.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if scanning { HStack { ProgressView().controlSize(.small); Text("Scanning…") } }
            else {
                Row(icon: "archivebox", title: "Caches & logs", value: Fmt.bytes(junkBytes))
                Row(icon: "trash", title: "Trash", value: Fmt.bytes(trashBytes))
                Text("Browser caches and your files are kept. Open System Junk to review each item.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Rescan") { scan() }
                    Spacer()
                    if confirm {
                        Button("Cancel") { confirm = false }
                        Button("Clean \(Fmt.bytes(junkBytes + trashBytes))") { clean() }.buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button("Quick clean…") { confirm = true }.buttonStyle(.borderedProminent).disabled(junkBytes + trashBytes == 0)
                    }
                }
                if confirm { Text("Deletes the caches and logs and empties the Trash (permanent).").font(.caption).foregroundStyle(.orange) }
            }
            if let result { Label(result, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
        }
        .onAppear { if junk.isEmpty && !scanning { scan() } }
    }

    func scan() {
        scanning = true
        let o = prefs.junkOptions
        Task.detached {
            let j = JunkScanner.scan(home: FileManager.default.homeDirectoryForCurrentUser, options: o)
            let t = Bins.trashItems()
            await MainActor.run { junk = j; trash = t; scanning = false }
        }
    }

    func clean() {
        confirm = false; scanning = true
        let j = junk, t = trash, mode = prefs.junkMode
        Task.detached {
            var r = JunkScanner.clean(j, safety: Safety(), mode: mode)
            let tr = JunkScanner.clean([JunkCategory(id: "t", title: "", subtitle: "", icon: "", items: t)], safety: Safety(), mode: .permanent)
            r.freed += tr.freed; r.count += tr.count
            let msg = "Cleaned " + r.summary
            await MainActor.run { result = msg; scan() }
        }
    }
}

private struct CPUTab: View {
    @EnvironmentObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CPU").bold()
                Spacer()
                Text(String(format: "%.0f%%", monitor.cpu * 100)).monospacedDigit().foregroundStyle(monitor.cpu > 0.8 ? .orange : .primary)
            }
            ProgressView(value: min(1, monitor.cpu)).tint(monitor.cpu > 0.8 ? .orange : .accentColor)
            Text("Busiest apps").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(monitor.apps.sorted { $0.cpu > $1.cpu }.prefix(6))) { a in
                HStack(spacing: 8) {
                    AppIcon(pid: a.pid)
                    Text(a.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", a.cpu)).monospacedDigit().frame(width: 50, alignment: .trailing)
                    if a.isApp {
                        Button { monitor.quit(a) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Quit \(a.name)")
                    } else { Color.clear.frame(width: 16, height: 1) }
                }
            }
            Text("100% = one core fully busy.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct StorageTab: View {
    @EnvironmentObject var monitor: Monitor
    let open: (Module?) -> Void
    var body: some View {
        let d = monitor.disk
        let used = Double(d.total - d.available) / Double(max(d.total, 1))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Macintosh HD").bold()
                Spacer()
                Text("\(Fmt.bytes(d.available)) free of \(Fmt.bytes(d.total))").monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: used).tint(d.available < 20_000_000_000 ? .orange : .accentColor)
            VStack(spacing: 6) {
                Shortcut(icon: Module.spaceLens.icon, title: "See what takes space (Space Lens)") { open(.spaceLens) }
                Shortcut(icon: Module.largeOld.icon, title: "Find large & old files") { open(.largeOld) }
                Shortcut(icon: Module.duplicates.icon, title: "Find duplicates") { open(.duplicates) }
                Shortcut(icon: Module.uninstaller.icon, title: "Uninstall apps") { open(.uninstaller) }
            }
        }
    }
}

private struct Row: View {
    let icon: String, title: String, value: String
    var body: some View {
        HStack { Image(systemName: icon).frame(width: 18); Text(title); Spacer(); Text(value).monospacedDigit().bold() }
    }
}

private struct Shortcut: View {
    let icon: String, title: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Image(systemName: icon).frame(width: 18); Text(title); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

struct Stat: View {
    let title: String, value: String
    var warn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit().bold().foregroundStyle(warn ? .orange : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
