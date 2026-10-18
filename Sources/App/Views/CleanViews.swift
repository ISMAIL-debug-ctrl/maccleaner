import SwiftUI

extension JunkScanner {
    /// Leftovers of apps that are no longer installed, as a junk category (never pre-selected, go to the Trash).
    static func leftoversCategory() -> JunkCategory {
        let installed = Set(AppInventory.list(includeSize: false).map(\.bundleID))
        let items = AppInventory.orphanLeftovers(installed: installed).map {
            JunkItem(id: "left:" + $0.url.path, name: $0.url.lastPathComponent,
                     detail: $0.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                     bytes: $0.bytes, kind: .file($0.url, root: $0.url.deletingLastPathComponent()), selected: false)
        }
        return JunkCategory(id: "leftovers", title: "Leftovers of deleted apps",
                            subtitle: "Data of apps that are gone. Review before ticking — goes to the Trash.", icon: "shippingbox", items: items)
    }
}

struct SystemJunkView: View {
    @EnvironmentObject var helper: HelperClient
    @State private var confirmSystem = false

    var body: some View {
        VStack(spacing: 0) {
            SimpleCleanView(module: .systemJunk, permanent: false,
                            explain: "Caches, logs and leftovers that apps rebuild by themselves. Browser caches and your files are never touched.", scan: Scans.systemJunk)
            Divider()
            systemPart.padding(12)
        }
        .onAppear { if helper.alive && helper.status.systemJunkScanned == nil { helper.run(.scanSystemJunk) } }
        .confirmationDialog("Clean system caches, crash reports and old logs?", isPresented: $confirmSystem) {
            Button("Clean", role: .destructive) { helper.run(.cleanSystemJunk) }
        } message: { Text("Only root-owned entries in fixed system folders. macOS rebuilds them.") }
    }

    @ViewBuilder var systemPart: some View {
        HStack(alignment: .top) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("System-wide junk (needs the helper)").bold()
                if !helper.alive {
                    Text("Helper not installed — run ./install.sh from the repo to enable this part.").font(.caption).foregroundStyle(.secondary)
                } else if helper.status.systemJunk.isEmpty {
                    Text(helper.busy != nil ? "Scanning…" : "Not scanned yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(helper.status.systemJunk) { j in
                        HStack {
                            Text(j.name).font(.caption)
                            Spacer()
                            Text(j.bytes > 0 ? Fmt.bytes(j.bytes) : "\(j.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }.frame(maxWidth: 360)
                    }
                    if let m = helper.lastMessage { Text(m).font(.caption).foregroundStyle(.green) }
                }
            }
            Spacer()
            if helper.alive {
                Button("Rescan") { helper.run(.scanSystemJunk) }.disabled(helper.busy != nil)
                Button("Clean system junk…") { confirmSystem = true }.disabled(helper.busy != nil || helper.status.systemJunk.isEmpty)
            }
        }
    }
}

struct PhotoJunkView: View {
    @State private var librarySize: Int64?
    var body: some View {
        VStack(spacing: 0) {
            SimpleCleanView(module: .photos, permanent: false,
                            explain: "Caches Photos and its analysis services keep outside your library. Your Photos library itself is never opened or changed.", scan: Scans.photos)
            Divider()
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(librarySize.map { "Your Photos library uses \(Fmt.bytes($0)). To shrink it, empty Photos ▸ Recently Deleted, or turn on iCloud Photos ▸ Optimize Mac Storage." }
                     ?? "To free space inside Photos, empty Photos ▸ Recently Deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Find similar photos") { NotificationCenter.default.post(name: .openModule, object: Module.duplicates) }
            }.padding(12)
        }
        .task { librarySize = await Task.detached { Bins.photosLibrarySize() }.value }
    }
}

// MARK: - Smart Scan

struct SmartScanView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var helper: HelperClient
    @EnvironmentObject var monitor: Monitor
    @State private var phase = 0     // 0 idle, 1 scanning, 2 results, 3 cleaning
    @State private var junk: [JunkCategory] = []
    @State private var trash: [JunkItem] = []
    @State private var updates: Int?
    @State private var flagged: Int?
    @State private var confirm = false
    @State private var result: String?

    var junkBytes: Int64 { junk.reduce(0) { $0 + $1.selectedBytes } }
    var trashBytes: Int64 { trash.reduce(0) { $0 + $1.bytes } }
    var systemBytes: Int64 { helper.alive ? helper.status.systemJunk.reduce(0) { $0 + $1.bytes } : 0 }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if phase == 0 {
                Image(systemName: "sparkles").font(.system(size: 64)).foregroundStyle(.tint)
                Text("Smart Scan").font(.largeTitle.bold())
                Text("Finds junk, checks memory, apps and launch items in one go.\nNothing is removed until you press Clean.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Scan") { scan() }.controlSize(.large).buttonStyle(.borderedProminent)
            } else if phase == 1 || phase == 3 {
                BusyView(text: phase == 1 ? "Scanning your Mac…" : "Cleaning…").frame(height: 120)
            } else {
                if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.title3) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], spacing: 16) {
                    Tile(title: "Cleanup", value: Fmt.bytes(junkBytes + trashBytes + systemBytes),
                         detail: "Junk \(Fmt.bytes(junkBytes)) · Trash \(Fmt.bytes(trashBytes))" + (helper.alive ? " · System \(Fmt.bytes(systemBytes))" : ""),
                         icon: "trash.circle", module: .systemJunk)
                    Tile(title: "Memory", value: monitor.mem.pressureLabel,
                         detail: "Swap \(Fmt.mem(monitor.mem.swapUsed)) · biggest: \(monitor.apps.first(where: \.isApp).map { "\($0.name) \(Fmt.mem($0.memory))" } ?? "—")",
                         icon: "memorychip", module: .memory, warn: monitor.mem.pressure >= 2 || monitor.mem.swapUsed > 4 << 30)
                    Tile(title: "App updates", value: updates.map { "\($0)" } ?? "…", detail: "Outdated apps found", icon: "arrow.down.app", module: .updater)
                    Tile(title: "Protection", value: flagged.map { "\($0)" } ?? "…", detail: "Launch items worth a look", icon: "shield.lefthalf.filled",
                         module: .protection, warn: (flagged ?? 0) > 0)
                }
                .frame(maxWidth: 760)
                HStack {
                    Button("Scan again") { scan() }
                    Button("Clean \(Fmt.bytes(junkBytes + trashBytes + systemBytes))…") { confirm = true }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(junkBytes + trashBytes + systemBytes == 0)
                }
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .confirmationDialog("Clean \(Fmt.bytes(junkBytes + trashBytes + systemBytes))?", isPresented: $confirm) {
            Button("Clean", role: .destructive) { clean() }
        } message: {
            Text("Removes the pre-selected caches and logs" + (trash.isEmpty ? "" : ", and empties the Trash (permanent)") +
                 (helper.alive ? ", plus system caches" : "") + ". Browser caches and your files are kept. Open System Junk to review each item.")
        }
    }

    func scan() {
        phase = 1; result = nil
        let o = prefs.junkOptions
        if helper.alive { helper.run(.scanSystemJunk) }
        Task.detached {
            let j = JunkScanner.scan(home: FileManager.default.homeDirectoryForCurrentUser, options: o)
            let t = Bins.trashItems()
            let f = LoginItems.list().filter { !$0.flags.isEmpty && $0.signer != "Apple" }.count
            await MainActor.run { junk = j; trash = t; flagged = f; phase = 2 }
            let u = await UpdateChecker.check(AppInventory.list(includeSize: false)).count
            await MainActor.run { updates = u }
        }
    }

    func clean() {
        phase = 3
        let j = junk, t = trash, mode = prefs.junkMode
        if helper.alive && systemBytes > 0 { helper.run(.cleanSystemJunk) }
        Task.detached {
            var r = JunkScanner.clean(j, safety: Safety(), mode: mode)
            let tr = JunkScanner.clean([JunkCategory(id: "t", title: "", subtitle: "", icon: "", items: t)], safety: Safety(), mode: .permanent)
            r.freed += tr.freed; r.count += tr.count; r.failed += tr.failed
            let msg = "Cleaned " + r.summary
            await MainActor.run { scan(); result = msg }
        }
    }
}

struct Tile: View {
    let title: String, value: String, detail: String, icon: String, module: Module
    var warn = false
    var body: some View {
        Button { NotificationCenter.default.post(name: .openModule, object: module) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.headline)
                Text(value).font(.system(size: 28, weight: .semibold)).foregroundStyle(warn ? .orange : .primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("Review ›").font(.caption).foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}
