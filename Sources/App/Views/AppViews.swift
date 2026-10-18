import SwiftUI

struct UninstallerView: View {
    @State private var apps: [InstalledApp] = []
    @State private var loading = false
    @State private var search = ""
    @State private var chosen: InstalledApp?
    @State private var leftovers: [Leftover] = []
    @State private var confirm = false
    @State private var result: String?
    @State private var sort = 0   // 0 size, 1 name, 2 last used

    var shown: [InstalledApp] {
        let f = apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case 1: return f.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case 2: return f.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        default: return f.sorted { $0.size > $1.size }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .uninstaller, text: "Remove an app together with its caches, settings and support files. Everything goes to the Trash, so you can undo.")
            ResultBar(text: result)
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
                        Picker("", selection: $sort) { Text("Size").tag(0); Text("Name").tag(1); Text("Least used").tag(2) }.frame(width: 120)
                    }.padding(8)
                    if loading { BusyView(text: "Reading apps…") }
                    else {
                        List(shown, selection: Binding(get: { chosen?.id }, set: { id in select(apps.first { $0.id == id }) })) { app in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 24, height: 24)
                                VStack(alignment: .leading) {
                                    Text(app.name)
                                    Text("v\(app.version) · used \(Fmt.date(app.lastUsed))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Fmt.bytes(app.size)).monospacedDigit().foregroundStyle(.secondary)
                            }.tag(app.id)
                        }
                    }
                }.frame(minWidth: 320)
                detail.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if apps.isEmpty { await load() } }
    }

    @ViewBuilder var detail: some View {
        if let app = chosen {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.title3.bold())
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if app.isApple {
                    Label("Apple apps are part of macOS and can't be removed.", systemImage: "lock").foregroundStyle(.secondary)
                } else {
                    Text("Will move to the Trash:").font(.headline)
                    List {
                        HStack { Image(systemName: "app"); Text(app.url.path).lineLimit(1).truncationMode(.middle); Spacer(); Text(Fmt.bytes(app.size)).monospacedDigit() }
                        ForEach($leftovers) { $l in
                            HStack {
                                Toggle("", isOn: $l.selected).labelsHidden().toggleStyle(.checkbox)
                                Text(l.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.bytes(l.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("Reset app (keep it, remove its data)") { confirm = true; resetOnly = true }
                            .disabled(leftovers.filter(\.selected).isEmpty)
                        Spacer()
                        Button("Uninstall…") { resetOnly = false; confirm = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
            .confirmationDialog(resetOnly ? "Remove \(app.name)'s data?" : "Uninstall \(app.name)?", isPresented: $confirm) {
                Button(resetOnly ? "Remove data" : "Uninstall", role: .destructive) { uninstall(app) }
            } message: { Text("Quit the app first. Everything goes to the Trash.") }
        } else {
            VStack { Spacer(); Text("Pick an app").foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
        }
    }

    @State private var resetOnly = false

    func load() async {
        loading = true
        apps = await Task.detached { AppInventory.list() }.value
        loading = false
    }

    func select(_ app: InstalledApp?) {
        chosen = app; leftovers = []
        guard let app else { return }
        Task {
            leftovers = await Task.detached { AppInventory.leftovers(bundleID: app.bundleID, name: app.name) }.value
        }
    }

    func uninstall(_ app: InstalledApp) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
            running.terminate()
        }
        var items = leftovers.filter(\.selected).map { ($0.url, $0.bytes) }
        let safety = Safety()
        if !resetOnly {
            // Apps installed by an admin may need a password; NSWorkspace.recycle asks for it.
            if safety.mayTrashUserSelection(app.url) {
                NSWorkspace.shared.recycle([app.url]) { _, err in
                    Task { @MainActor in
                        if let err { result = "Couldn't move \(app.name): \(err.localizedDescription)" }
                        else { apps.removeAll { $0.id == app.id }; chosen = nil }
                    }
                }
            }
        }
        items = items.filter { safety.mayTrashUserSelection($0.0) }
        let r = Deleter.deleteSelected(items, safety: safety)
        result = (resetOnly ? "Removed \(app.name)'s data: " : "Uninstalled \(app.name): ") + r.summary
        if resetOnly { select(app) }
    }
}

struct UpdaterView: View {
    @State private var updates: [AppUpdate] = []
    @State private var checking = false
    @State private var checked = false

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .updater, text: "Apps with a newer version available, from the App Store, the app's own update feed (Sparkle) or Homebrew. MacCleaner only tells you; the app's own updater installs it.")
            if checking { BusyView(text: "Checking update feeds…") }
            else if checked && updates.isEmpty { VStack { Spacer(); Label("Everything is up to date", systemImage: "checkmark.seal"); Spacer() } }
            else {
                List(updates) { u in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: u.app.url.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading) {
                            Text(u.app.name).bold()
                            Text("\(u.app.version) → \(u.latest) · \(u.source)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(u.link != nil ? "Open App Store" : "Open app") {
                            if let l = u.link { NSWorkspace.shared.open(l) } else { NSWorkspace.shared.open(u.app.url) }
                        }
                    }
                }
            }
            Divider()
            HStack { Spacer(); Button("Check now") { Task { await check() } }.disabled(checking) }.padding(12)
        }
        .task { if !checked { await check() } }
    }

    func check() async {
        checking = true
        let apps = await Task.detached { AppInventory.list(includeSize: false) }.value
        updates = await UpdateChecker.check(apps)
        checking = false; checked = true
    }
}
