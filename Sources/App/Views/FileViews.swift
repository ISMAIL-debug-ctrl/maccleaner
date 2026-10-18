import SwiftUI

/// Folder picker row shared by the file finders. Default: your home folder.
struct FolderPicker: View {
    @Binding var folder: URL
    var body: some View {
        HStack {
            Image(systemName: "folder")
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
            Button("Choose…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.directoryURL = folder
                if p.runModal() == .OK, let u = p.url { folder = u }
            }
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}

struct FileTable: View {
    @Binding var files: [FoundFile]
    var body: some View {
        Table($files) {
            TableColumn("") { $f in Toggle("", isOn: $f.selected).labelsHidden().toggleStyle(.checkbox) }.width(24)
            TableColumn("Name") { $f in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 16, height: 16)
                    Text(f.url.lastPathComponent).lineLimit(1)
                }
            }
            TableColumn("Folder") { $f in
                Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            TableColumn("Size") { $f in Text(Fmt.bytes(f.bytes)).monospacedDigit() }.width(80)
            TableColumn("Last used") { $f in Text(Fmt.date(max(f.accessed ?? .distantPast, f.modified ?? .distantPast))) }.width(100)
            TableColumn("") { $f in
                Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
            }.width(24)
        }
    }
}

/// Bottom bar: "N selected · size  [Move to Trash…]" with a confirmation.
struct TrashBar: View {
    let items: [(url: URL, bytes: Int64)]
    let onDone: (DeleteReport) -> Void
    @State private var confirm = false
    var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        HStack {
            Spacer()
            Text("\(items.count) selected · \(Fmt.bytes(total))").monospacedDigit()
            Button("Move to Trash…") { confirm = true }.buttonStyle(.borderedProminent).disabled(items.isEmpty)
        }
        .padding(12)
        .confirmationDialog("Move \(items.count) items (\(Fmt.bytes(total))) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { onDone(Deleter.deleteSelected(items, safety: Safety())) }
        } message: { Text("You picked these yourself. They stay in the Trash until you empty it.") }
    }
}

struct LargeOldView: View {
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser
    @State private var minMB = 100.0
    @State private var oldOnly = false
    @State private var months = 6
    @State private var files: [FoundFile] = []
    @State private var scanning = false
    @State private var cancel = CancelFlag()
    @State private var result: String?

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .largeOld, text: "Big files and files you haven't opened in a long time. Nothing is selected for you — tick what you don't need.")
            HStack(spacing: 16) {
                FolderPicker(folder: $folder)
                Spacer()
                Picker("Bigger than", selection: $minMB) {
                    ForEach([10.0, 50, 100, 500, 1000, 5000], id: \.self) { Text($0 >= 1000 ? "\(Int($0 / 1000)) GB" : "\(Int($0)) MB").tag($0) }
                }.frame(width: 170)
                Toggle("Not used in", isOn: $oldOnly)
                Stepper("\(months) months", value: $months, in: 1...60).disabled(!oldOnly).fixedSize()
                Button(scanning ? "Stop" : "Scan") { scanning ? cancel.set() : scan() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
            ResultBar(text: result)
            if scanning && files.isEmpty { BusyView(text: "Looking through \(folder.lastPathComponent)…") }
            else { FileTable(files: $files) }
            TrashBar(items: files.filter(\.selected).map { ($0.url, $0.bytes) }) { r in
                result = "Moved " + r.summary + " to the Trash"
                let gone = Set(files.filter(\.selected).map(\.url))
                files.removeAll { gone.contains($0.url) && !FileManager.default.fileExists(atPath: $0.url.path) }
            }
        }
    }

    func scan() {
        scanning = true; files = []; result = nil
        let c = CancelFlag(); cancel = c
        let root = folder, min = Int64(minMB * 1_000_000), days = oldOnly ? months * 30 : nil
        Task.detached {
            let f = LargeOld.scan(root: root, minBytes: min, olderThanDays: days, cancel: { c.isSet })
            await MainActor.run { files = f; scanning = false }
        }
    }
}

struct DuplicatesView: View {
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser
    @State private var similar = false
    @State private var groups: [DuplicateGroup] = []
    @State private var scanning = false
    @State private var scanned = false
    @State private var cancel = CancelFlag()
    @State private var result: String?

    var selected: [(url: URL, bytes: Int64)] { groups.flatMap(\.files).filter(\.selected).map { ($0.url, $0.bytes) } }

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .duplicates, text: similar
                   ? "Photos that look almost the same (bursts, edits, re-saves). Nothing is pre-selected: pick the ones to drop."
                   : "Byte-for-byte identical files. The oldest copy in each group is kept; the others are pre-selected.")
            HStack {
                FolderPicker(folder: $folder)
                Spacer()
                Picker("", selection: $similar) { Text("Exact duplicates").tag(false); Text("Similar photos").tag(true) }
                    .pickerStyle(.segmented).frame(width: 260)
                Button(scanning ? "Stop" : "Scan") { scanning ? cancel.set() : scan() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
            ResultBar(text: result)
            if scanning { BusyView(text: "Comparing files…") }
            else if scanned && groups.isEmpty { VStack { Spacer(); Label("No duplicates found", systemImage: "checkmark.seal"); Spacer() } }
            else {
                List {
                    ForEach($groups) { $g in
                        Section("\(g.files.count) copies · \(Fmt.bytes(g.files.first?.bytes ?? 0)) each") {
                            ForEach($g.files) { $f in
                                HStack {
                                    Toggle("", isOn: $f.selected).labelsHidden().toggleStyle(.checkbox)
                                    if similar, let img = NSImage(contentsOf: f.url) {
                                        Image(nsImage: img).resizable().scaledToFill().frame(width: 40, height: 40).clipped().cornerRadius(4)
                                    }
                                    Text(f.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.date(f.modified)).foregroundStyle(.secondary)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
            TrashBar(items: selected) { r in result = "Moved " + r.summary + " to the Trash"; scan() }
        }
        .onChange(of: similar) { _, _ in groups = []; scanned = false }
    }

    func scan() {
        scanning = true; groups = []
        let c = CancelFlag(); cancel = c
        let root = folder, sim = similar
        Task.detached {
            let g = sim ? Duplicates.similarPhotos(root: root, cancel: { c.isSet }) : Duplicates.scan(root: root, cancel: { c.isSet })
            await MainActor.run { groups = g; scanning = false; scanned = true }
        }
    }
}

// MARK: - Space Lens (squarified treemap)

struct SpaceLensView: View {
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser
    @State private var root: SizeNode?
    @State private var current: SizeNode?
    @State private var scanning = false
    @State private var progress = ""
    @State private var cancel = CancelFlag()
    @State private var hover: SizeNode?

    var body: some View {
        VStack(spacing: 0) {
            Header(module: .spaceLens, text: "A map of what takes space. Bigger box = bigger folder. Click a folder to go in.")
            HStack {
                FolderPicker(folder: $folder)
                if let c = current, c !== root {
                    Button { current = c.parent } label: { Label("Up", systemImage: "arrow.up") }
                }
                Spacer()
                if let h = hover ?? current { Text("\(h.name) — \(Fmt.bytes(h.bytes))").monospacedDigit().lineLimit(1) }
                Button(scanning ? "Stop" : "Scan") { scanning ? cancel.set() : scan() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
            if scanning { BusyView(text: "Measuring \(progress)…") }
            else if let c = current {
                GeometryReader { geo in
                    let rects = Treemap.layout(c.children.filter { $0.bytes > 0 }, in: CGRect(origin: .zero, size: geo.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(rects, id: \.0.id) { node, r in
                            Cell(node: node, rect: r, hovered: hover === node)
                                .onHover { hover = $0 ? node : (hover === node ? nil : hover) }
                                .onTapGesture { if node.isDir && !node.children.isEmpty { current = node; hover = nil } }
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                                }
                        }
                    }
                }
                .padding(12)
            } else {
                VStack { Spacer(); Button("Scan") { scan() }.controlSize(.large).buttonStyle(.borderedProminent); Spacer() }
            }
        }
    }

    func scan() {
        scanning = true; root = nil; current = nil
        let c = CancelFlag(); cancel = c
        let f = folder
        Task.detached {
            let n = SpaceLens.build(f, cancel: { c.isSet }) { u in
                let name = u.lastPathComponent
                Task { @MainActor in progress = name }
            }
            await MainActor.run { root = n; current = n; scanning = false }
        }
    }

    struct Cell: View {
        let node: SizeNode, rect: CGRect, hovered: Bool
        var color: Color {
            let h = Double(abs(node.name.hashValue % 360)) / 360
            return node.isDir ? Color(hue: h, saturation: 0.45, brightness: 0.75) : Color.gray.opacity(0.5)
        }
        var body: some View {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(hovered ? 1 : 0.8))
                .overlay(alignment: .topLeading) {
                    if rect.width > 60 && rect.height > 30 {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(node.name).font(.caption.bold()).lineLimit(1)
                            Text(Fmt.bytes(node.bytes)).font(.caption2)
                        }.padding(4).foregroundStyle(.white)
                    }
                }
                .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
                .offset(x: rect.minX + 1, y: rect.minY + 1)
        }
    }
}
