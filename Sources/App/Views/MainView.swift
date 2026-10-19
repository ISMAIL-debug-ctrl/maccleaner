import SwiftUI

enum Module: String, CaseIterable, Identifiable {
    case smartScan = "Smart Scan"
    case systemJunk = "System Junk", trash = "Trash Bins", mail = "Mail Attachments", photos = "Photo Junk"
    case largeOld = "Large & Old Files", duplicates = "Duplicates", spaceLens = "Space Lens"
    case uninstaller = "Uninstaller", updater = "Updater"
    case memory = "Memory", optimization = "Optimization", maintenance = "Maintenance"
    case privacy = "Privacy", protection = "Protection"
    case settings = "Settings"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartScan: return "sparkles"
        case .systemJunk: return "trash.circle"
        case .trash: return "trash"
        case .mail: return "paperclip"
        case .photos: return "photo.on.rectangle"
        case .largeOld: return "doc.zipper"
        case .duplicates: return "square.on.square"
        case .spaceLens: return "circle.hexagongrid"
        case .uninstaller: return "xmark.app"
        case .updater: return "arrow.down.app"
        case .memory: return "memorychip"
        case .optimization: return "gauge.with.dots.needle.67percent"
        case .maintenance: return "wrench.and.screwdriver"
        case .privacy: return "hand.raised"
        case .protection: return "shield.lefthalf.filled"
        case .settings: return "gearshape"
        }
    }

    static let groups: [(String, [Module])] = [
        ("", [.smartScan]),
        ("Cleanup", [.systemJunk, .trash, .mail, .photos]),
        ("Files", [.largeOld, .duplicates, .spaceLens]),
        ("Applications", [.uninstaller, .updater]),
        ("Speed", [.memory, .optimization, .maintenance]),
        ("Safety", [.privacy, .protection]),
        ("", [.settings]),
    ]
}

struct MainView: View {
    // `--module "Memory"` opens a module directly (handy for scripts and testing).
    @State private var selection: Module? = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--module"), i + 1 < a.count { return Module(rawValue: a[i + 1]) ?? .smartScan }
        return .smartScan
    }()
    @EnvironmentObject var helper: HelperClient
    @State private var fdaGranted = true

    var body: some View {
        // A plain sidebar + detail layout. NavigationSplitView sized itself to each module's ideal height
        // (up to 2700 pt), so the window content jumped and got cut off when switching sections.
        GeometryReader { g in
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Module.groups, id: \.1.first!.id) { title, mods in
                        Section(title) {
                            ForEach(mods) { m in Label(m.rawValue, systemImage: m.icon).tag(m) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 220)
                Divider()
                VStack(spacing: 0) {
                    if !fdaGranted { FDABanner() }
                    detail(selection ?? .smartScan)
                        .id(selection)   // fresh state per module (Trash, Mail and Privacy share one view type)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: max(0, g.size.width - 221), height: g.size.height)
                .clipped()
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .onAppear {
            fdaGranted = FullDiskAccess.granted
            // Test hook, only when launched with --test-hooks: lets scripts switch sections to check the layout.
            if CommandLine.arguments.contains("--test-hooks") {
                DistributedNotificationCenter.default().addObserver(forName: .init("com.ismailx.maccleaner.test.open"), object: nil, queue: .main) { n in
                    if let name = n.object as? String, let m = Module(rawValue: name) { selection = m }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGranted = FullDiskAccess.granted
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModule)) { n in
            if let m = n.object as? Module { selection = m }
        }
    }

    @ViewBuilder func detail(_ m: Module) -> some View {
        switch m {
        case .smartScan: SmartScanView()
        case .systemJunk: SystemJunkView()
        case .trash: SimpleCleanView(module: .trash, permanent: true,
                                     explain: "Files you already moved to the Trash, on this Mac and connected drives. Emptying is permanent.", scan: Scans.trash)
        case .mail: SimpleCleanView(module: .mail, permanent: false,
                                    explain: "Copies Mail saved when you opened attachments. Attachments in mailboxes are listed but not pre-selected: with POP mail they may be the only copy.", scan: Scans.mail)
        case .photos: PhotoJunkView()
        case .largeOld: LargeOldView()
        case .duplicates: DuplicatesView()
        case .spaceLens: SpaceLensView()
        case .uninstaller: UninstallerView()
        case .updater: UpdaterView()
        case .memory: MemoryView()
        case .optimization: OptimizationView()
        case .maintenance: MaintenanceView()
        case .privacy: SimpleCleanView(module: .privacy, permanent: true,
                                       explain: "Opt-in only: nothing is selected until you tick it. Quit the browser first. Deleting cookies signs you out of websites.", scan: Scans.privacy)
        case .protection: ProtectionView()
        case .settings: SettingsView()
        }
    }
}

/// Scan functions live outside any view so they run off the main thread (view closures inherit the main actor).
enum Scans {
    static func trash(_: JunkOptions) -> [JunkCategory] {
        [JunkCategory(id: "trash", title: "Trash", subtitle: "", icon: "trash", items: Bins.trashItems())]
    }
    static func mail(_: JunkOptions) -> [JunkCategory] {
        [JunkCategory(id: "mail", title: "Mail attachments", subtitle: "", icon: "paperclip", items: Bins.mailItems())]
    }
    static func photos(_: JunkOptions) -> [JunkCategory] {
        [JunkCategory(id: "photos", title: "Photos caches", subtitle: "Rebuilt by macOS when needed", icon: "photo", items: Bins.photoItems())]
    }
    static func privacy(_: JunkOptions) -> [JunkCategory] { Privacy.items() }
    static func systemJunk(_ o: JunkOptions) -> [JunkCategory] {
        var c = JunkScanner.scan(home: FileManager.default.homeDirectoryForCurrentUser, options: o)
        let left = JunkScanner.leftoversCategory()
        if !left.items.isEmpty { c.append(left) }
        return c
    }
}

extension Notification.Name { static let openModule = Notification.Name("openModule") }

struct FDABanner: View {
    var body: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Give MacCleaner **Full Disk Access** so it can see the Trash, Mail and Safari data.")
            Spacer()
            Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
        }
        .padding(10).background(.orange.opacity(0.12))
    }
}

// MARK: - Shared pieces

struct Header: View {
    let module: Module
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: module.icon).font(.system(size: 30)).foregroundStyle(.tint).frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(module.rawValue).font(.title2.bold())
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding([.horizontal, .top], 20).padding(.bottom, 10)
    }
}

/// Category → items list with checkboxes. Used by every cleanup-style module.
struct CategoryList: View {
    @Binding var cats: [JunkCategory]
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            ForEach($cats) { $cat in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(cat.id) },
                                                    set: { if $0 { expanded.insert(cat.id) } else { expanded.remove(cat.id) } })) {
                    ForEach($cat.items) { $item in
                        HStack {
                            if case .info = item.kind {
                                Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 18)
                            } else {
                                Toggle("", isOn: $item.selected).labelsHidden().toggleStyle(.checkbox)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                            Spacer()
                            Text(item.bytes > 0 ? Fmt.bytes(item.bytes) : "—").monospacedDigit().foregroundStyle(.secondary)
                            if case .file(let u, _) = item.kind {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless).help("Show in Finder")
                            }
                        }
                    }
                } label: {
                    HStack {
                        let selectable = cat.items.filter { if case .info = $0.kind { return false }; return true }
                        Toggle("", isOn: Binding(
                            get: { !selectable.isEmpty && selectable.allSatisfy(\.selected) },
                            set: { v in for i in cat.items.indices { if case .info = cat.items[i].kind { continue }; cat.items[i].selected = v } }))
                            .labelsHidden().toggleStyle(.checkbox).disabled(selectable.isEmpty)
                        Image(systemName: cat.icon).frame(width: 20)
                        VStack(alignment: .leading) {
                            Text(cat.title).bold()
                            Text(cat.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.bytes(cat.selectedBytes)).monospacedDigit().bold()
                        Text("of \(Fmt.bytes(cat.totalBytes))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct BusyView: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) { ProgressView(); Text(text).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResultBar: View {
    let text: String?
    var body: some View {
        if let text {
            HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(text); Spacer() }
                .padding(.horizontal, 20).padding(.vertical, 6)
        }
    }
}

/// Scan → preview → confirm → clean, for modules that are just "a list of things to remove".
struct SimpleCleanView: View {
    let module: Module
    let permanent: Bool
    let explain: String
    let scan: @Sendable (JunkOptions) -> [JunkCategory]
    @EnvironmentObject var prefs: Prefs
    @State private var cats: [JunkCategory] = []
    @State private var scanning = false
    @State private var scanned = false
    @State private var confirm = false
    @State private var result: String?

    var selected: Int64 { cats.reduce(0) { $0 + $1.selectedBytes } }
    var count: Int { cats.flatMap(\.items).filter(\.selected).count }

    var body: some View {
        VStack(spacing: 0) {
            Header(module: module, text: explain)
            ResultBar(text: result)
            if scanning { BusyView(text: "Scanning…") }
            else if !scanned {
                VStack { Spacer(); Button("Scan") { run() }.controlSize(.large).buttonStyle(.borderedProminent); Spacer() }
            } else if cats.allSatisfy({ $0.items.isEmpty }) {
                VStack { Spacer(); Label("Nothing to clean here", systemImage: "checkmark.seal").font(.title3); Spacer() }
            } else {
                CategoryList(cats: $cats)
            }
            Divider()
            HStack {
                Button("Rescan") { run() }.disabled(scanning)
                Spacer()
                Text("\(count) selected · \(Fmt.bytes(selected))").monospacedDigit()
                Button(permanent ? "Delete…" : "Clean…") { confirm = true }
                    .buttonStyle(.borderedProminent).disabled(count == 0 || scanning)
            }
            .padding(12)
        }
        .confirmationDialog("\(permanent ? "Permanently delete" : "Clean") \(count) items (\(Fmt.bytes(selected)))?",
                            isPresented: $confirm) {
            Button(permanent ? "Delete" : "Clean", role: .destructive) { clean() }
        } message: {
            Text(permanent ? "This can't be undone." : (prefs.junkToTrash ? "Items go to the Trash." : "These are copies and caches; they are deleted, not moved to the Trash."))
        }
        .onAppear { if !scanned { run() } }
    }

    func run() {
        scanning = true
        let o = prefs.junkOptions, s = scan
        Task.detached {
            let c = s(o)
            await MainActor.run { cats = c; scanning = false; scanned = true }
        }
    }

    func clean() {
        let c = cats, mode: DeleteMode = permanent ? .permanent : prefs.junkMode
        scanning = true
        Task.detached {
            let r = JunkScanner.clean(c, safety: Safety(), mode: mode)
            await MainActor.run { result = "Cleaned " + r.summary; run() }
        }
    }
}
