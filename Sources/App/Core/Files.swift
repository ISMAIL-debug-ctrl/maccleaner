import Foundation
import CryptoKit
import ImageIO

// Large & Old files, Duplicates / similar photos, Space Lens. All read-only scans:
// nothing here deletes; the user picks files and they go to the Trash through Deleter.deleteSelected.

struct FoundFile: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var bytes: Int64
    var modified: Date?
    var accessed: Date?
    var selected = false
}

/// Skipped while walking: system-managed, app bundles and package internals.
enum Walk {
    static let skipNames: Set<String> = [".Trash", "Library", ".git", "node_modules", ".npm", ".cache", ".Spotlight-V100",
                                         ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems"]

    /// Regular files under `root`. Packages (.app, .photoslibrary, .fcpbundle, …) are not entered.
    static func files(under root: URL, includeHidden: Bool = false, cancel: () -> Bool = { false }, _ body: (URL, URLResourceValues) -> Void) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey,
                                         .contentModificationDateKey, .contentAccessDateKey, .isSymbolicLinkKey, .nameKey]
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { opts.insert(.skipsHiddenFiles) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: opts,
                                                     errorHandler: { _, _ in true }) else { return }
        while let u = e.nextObject() as? URL {
            if cancel() { return }
            guard let v = try? u.resourceValues(forKeys: keys) else { continue }
            if v.isDirectory == true, skipNames.contains(v.name ?? "") { e.skipDescendants(); continue }
            if v.isRegularFile == true, v.isSymbolicLink != true { body(u, v) }
        }
    }
}

enum LargeOld {
    static func scan(root: URL, minBytes: Int64, olderThanDays: Int?, cancel: @escaping () -> Bool) -> [FoundFile] {
        var out: [FoundFile] = []
        let cutoff = olderThanDays.map { Date().addingTimeInterval(-Double($0) * 86400) }
        Walk.files(under: root, cancel: cancel) { u, v in
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            guard size >= minBytes else { return }
            let used = max(v.contentAccessDate ?? .distantPast, v.contentModificationDate ?? .distantPast)
            if let cutoff, used > cutoff { return }
            out.append(FoundFile(url: u, bytes: size, modified: v.contentModificationDate, accessed: v.contentAccessDate))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }
}

struct DuplicateGroup: Identifiable, Hashable {
    var id: String
    var files: [FoundFile]
    var similar: Bool        // visually similar photos rather than byte-identical
    var wasted: Int64 { files.dropFirst().reduce(0) { $0 + $1.bytes } }
}

enum Duplicates {
    /// Byte-identical files: same size → same first 64 KB → same SHA-256.
    static func scan(root: URL, minBytes: Int64 = 1024, cancel: @escaping () -> Bool, progress: (String) -> Void = { _ in }) -> [DuplicateGroup] {
        var bySize: [Int64: [FoundFile]] = [:]
        Walk.files(under: root, cancel: cancel) { u, v in
            let s = Int64(v.totalFileAllocatedSize ?? 0)
            if s >= minBytes { bySize[s, default: []].append(FoundFile(url: u, bytes: s, modified: v.contentModificationDate)) }
        }
        var groups: [DuplicateGroup] = []
        for (_, files) in bySize where files.count > 1 {
            if cancel() { break }
            let byHead = Dictionary(grouping: files) { hash($0.url, limit: 64 * 1024) ?? UUID().uuidString }
            for (_, same) in byHead where same.count > 1 {
                let byFull = Dictionary(grouping: same) { hash($0.url, limit: nil) ?? UUID().uuidString }
                for (h, dup) in byFull where dup.count > 1 {
                    groups.append(group(h, dup, similar: false))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// Keeps the oldest copy unselected; the others are pre-selected for the Trash.
    static func group(_ id: String, _ files: [FoundFile], similar: Bool) -> DuplicateGroup {
        var sorted = files.sorted { ($0.modified ?? .distantPast, $0.url.path.count) < ($1.modified ?? .distantPast, $1.url.path.count) }
        for i in sorted.indices { sorted[i].selected = i > 0 && !similar }
        return DuplicateGroup(id: id, files: sorted, similar: similar)
    }

    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        var read = 0
        while true {
            let chunk = (try? h.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            sha.update(data: chunk)
            read += chunk.count
            if let limit, read >= limit { break }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    /// Visually similar photos (dHash, Hamming distance ≤ 6). Nothing is pre-selected.
    static func similarPhotos(root: URL, cancel: @escaping () -> Bool) -> [DuplicateGroup] {
        var items: [(FoundFile, UInt64)] = []
        Walk.files(under: root, cancel: cancel) { u, v in
            guard imageExts.contains(u.pathExtension.lowercased()), let h = dHash(u) else { return }
            items.append((FoundFile(url: u, bytes: Int64(v.totalFileAllocatedSize ?? 0), modified: v.contentModificationDate), h))
        }
        var used = Set<Int>()
        var groups: [DuplicateGroup] = []
        for i in items.indices where !used.contains(i) {
            if cancel() { break }
            var g = [items[i].0]
            for j in (i + 1)..<items.count where !used.contains(j) && (items[i].1 ^ items[j].1).nonzeroBitCount <= 6 {
                g.append(items[j].0); used.insert(j)
            }
            if g.count > 1 { used.insert(i); groups.append(group("sim:\(i)", g, similar: true)) }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// 64-bit difference hash of a 9×8 grayscale thumbnail.
    static func dHash(_ url: URL) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        var px = [UInt8](repeating: 0, count: 9 * 8)
        guard let ctx = CGContext(data: &px, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var h: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { h = (h << 1) | (px[y * 9 + x] > px[y * 9 + x + 1] ? 1 : 0) } }
        return h
    }
}

// MARK: - Space Lens

final class SizeNode: Identifiable {
    let id = UUID()
    let url: URL
    let isDir: Bool
    var bytes: Int64 = 0
    var children: [SizeNode] = []
    weak var parent: SizeNode?
    init(url: URL, isDir: Bool) { self.url = url; self.isDir = isDir }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

enum SpaceLens {
    /// Builds a size tree. Only the top `keep` children per folder are stored, so the tree stays small.
    static func build(_ url: URL, depth: Int = 0, keep: Int = 60, cancel: () -> Bool, progress: (URL) -> Void) -> SizeNode {
        let node = SizeNode(url: url, isDir: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .isPackageKey]
        guard let kids = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else { return node }
        if depth <= 1 { progress(url) }
        var all: [SizeNode] = []
        var other: Int64 = 0
        for k in kids {
            if cancel() { break }
            guard let v = try? k.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let child: SizeNode
            if v.isDirectory == true {
                if ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm"].contains(k.path) { continue }
                child = depth < 40 ? build(k, depth: depth + 1, keep: keep, cancel: cancel, progress: progress) : SizeNode(url: k, isDir: true)
            } else {
                child = SizeNode(url: k, isDir: false)
                child.bytes = Int64(v.totalFileAllocatedSize ?? 0)
            }
            all.append(child)
        }
        all.sort { $0.bytes > $1.bytes }
        if all.count > keep { other = all[keep...].reduce(0) { $0 + $1.bytes }; all = Array(all[..<keep]) }
        for c in all { c.parent = node }
        node.children = all
        node.bytes = all.reduce(other) { $0 + $1.bytes }
        return node
    }
}

enum Treemap {
    /// Squarified treemap (Bruls et al.). Input sorted largest first.
    static func layout(_ nodes: [SizeNode], in rect: CGRect) -> [(SizeNode, CGRect)] {
        let total = Double(nodes.reduce(0) { $0 + $1.bytes })
        guard total > 0, rect.width > 1, rect.height > 1 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var out: [(SizeNode, CGRect)] = []
        var remaining = nodes[...]
        var r = rect
        while !remaining.isEmpty {
            let short = Double(min(r.width, r.height))
            var row: [SizeNode] = []
            var best = Double.infinity
            while let n = remaining.first {
                let candidate = row + [n]
                let w = worst(candidate.map { Double($0.bytes) * scale }, short)
                if w > best { break }
                best = w; row = candidate; remaining = remaining.dropFirst()
            }
            let area = row.reduce(0.0) { $0 + Double($1.bytes) * scale }
            let thick = CGFloat(area / short)
            var pos: CGFloat = 0
            for n in row {
                let len = CGFloat(Double(n.bytes) * scale / Double(thick))
                if r.width >= r.height {
                    out.append((n, CGRect(x: r.minX, y: r.minY + pos, width: thick, height: len)))
                } else {
                    out.append((n, CGRect(x: r.minX + pos, y: r.minY, width: len, height: thick)))
                }
                pos += len
            }
            if r.width >= r.height { r = CGRect(x: r.minX + thick, y: r.minY, width: r.width - thick, height: r.height) }
            else { r = CGRect(x: r.minX, y: r.minY + thick, width: r.width, height: r.height - thick) }
        }
        return out
    }

    static func worst(_ areas: [Double], _ side: Double) -> Double {
        let s = areas.reduce(0, +)
        guard let mx = areas.max(), let mn = areas.min(), s > 0, mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }
}

// MARK: - Trash, Mail attachments, Photo junk

enum Bins {
    static func trashes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var out = [home.appendingPathComponent(".Trash")]
        for vol in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let t = URL(fileURLWithPath: "/Volumes/\(vol)/.Trashes/\(getuid())")
            if FileManager.default.fileExists(atPath: t.path) { out.append(t) }
        }
        return out
    }

    static func trashItems() -> [JunkItem] {
        trashes().flatMap { root in
            Sizer.children(root).filter { $0.lastPathComponent != ".DS_Store" }.map {
                JunkItem(id: $0.path, name: $0.lastPathComponent, detail: root.path.hasPrefix("/Volumes") ? root.pathComponents[2] : "Trash",
                         bytes: Sizer.size(of: $0), kind: .file($0, root: root), selected: true)
            }
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Mail Downloads are copies Mail made when you opened an attachment (safe). Attachments inside
    /// ~/Library/Mail are local copies of what's on the server — listed, not pre-selected (POP mail may have no other copy).
    static func mailItems(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [JunkItem] {
        var out: [JunkItem] = []
        let dl = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        for u in Sizer.children(dl) {
            out.append(JunkItem(id: u.path, name: u.lastPathComponent, detail: "Opened-attachment copy",
                                bytes: Sizer.size(of: u), kind: .file(u, root: dl), selected: true))
        }
        let mail = home.appendingPathComponent("Library/Mail")
        if let e = FileManager.default.enumerator(at: mail, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            while let u = e.nextObject() as? URL {
                guard u.lastPathComponent == "Attachments" else { continue }
                e.skipDescendants()
                for a in Sizer.children(u) {
                    out.append(JunkItem(id: a.path, name: a.lastPathComponent, detail: "Downloaded attachment (kept on server for IMAP)",
                                        bytes: Sizer.size(of: a), kind: .file(a, root: u), selected: false))
                }
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Photos caches outside the library. The Photos library itself is never opened or changed.
    static func photoItems(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [JunkItem] {
        var out: [JunkItem] = []
        for rel in ["Library/Containers/com.apple.photoanalysisd/Data/Library/Caches",
                    "Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches",
                    "Library/Caches/com.apple.Photos", "Library/Containers/com.apple.Photos/Data/Library/Caches"] {
            let root = home.appendingPathComponent(rel)
            for u in Sizer.children(root) {
                out.append(JunkItem(id: u.path, name: u.lastPathComponent, detail: rel.components(separatedBy: "/")[2],
                                    bytes: Sizer.size(of: u), kind: .file(u, root: root), selected: true))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func photosLibrarySize(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        let lib = home.appendingPathComponent("Pictures/Photos Library.photoslibrary")
        return FileManager.default.fileExists(atPath: lib.path) ? Sizer.size(of: lib) : nil
    }
}

// MARK: - Privacy (opt-in: nothing selected by default)

enum Privacy {
    struct Browser { let name: String; let bundleID: String; let items: [(String, [String])] }

    /// Per browser: (label, paths relative to home). Chromium paths are per profile.
    static func items(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [JunkCategory] {
        var cats: [JunkCategory] = []
        func make(_ label: String, _ urls: [URL], root: URL) -> [JunkItem] {
            urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map {
                JunkItem(id: $0.path, name: label, detail: $0.lastPathComponent, bytes: Sizer.size(of: $0),
                         kind: .file($0, root: root), selected: false)
            }
        }
        for (name, rel) in Protection.chromiumBrowsers {
            let root = home.appendingPathComponent(rel)
            var items: [JunkItem] = []
            for p in Protection.profiles(root) {
                let tag = p.lastPathComponent == "Default" ? "" : " (\(p.lastPathComponent))"
                items += make("History" + tag, ["History", "History-journal", "Visited Links", "Top Sites", "Shortcuts"].map { p.appendingPathComponent($0) }, root: p)
                items += make("Cookies" + tag, ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"].map { p.appendingPathComponent($0) }, root: p)
                items += make("Autofill form data" + tag, ["Web Data", "Web Data-journal"].map { p.appendingPathComponent($0) }, root: p)
            }
            let cache = home.appendingPathComponent("Library/Caches").appendingPathComponent(rel.replacingOccurrences(of: "Library/Application Support/", with: ""))
            items += make("Cache", [cache], root: cache.deletingLastPathComponent())
            if !items.isEmpty {
                cats.append(JunkCategory(id: "priv:" + name, title: name, subtitle: "Quit \(name) first. Removes saved logins too when Cookies is selected.",
                                         icon: "globe", items: items))
            }
        }
        let safari = home.appendingPathComponent("Library/Safari")
        let sc = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library")
        var s = make("History", ["History.db", "History.db-wal", "History.db-shm", "LastSession.plist", "RecentlyClosedTabs.plist"].map { safari.appendingPathComponent($0) }, root: safari)
        s += make("Cookies", [sc.appendingPathComponent("Cookies/Cookies.binarycookies")], root: sc.appendingPathComponent("Cookies"))
        s += make("Cache", [sc.appendingPathComponent("Caches/com.apple.Safari")], root: sc.appendingPathComponent("Caches"))
        if !s.isEmpty { cats.append(JunkCategory(id: "priv:Safari", title: "Safari", subtitle: "Quit Safari first. Needs Full Disk Access.", icon: "safari", items: s)) }

        let ff = home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        var f: [JunkItem] = []
        for p in Sizer.children(ff) {
            f += make("History", ["places.sqlite", "places.sqlite-wal", "formhistory.sqlite"].map { p.appendingPathComponent($0) }, root: p)
            f += make("Cookies", ["cookies.sqlite", "cookies.sqlite-wal"].map { p.appendingPathComponent($0) }, root: p)
        }
        if !f.isEmpty { cats.append(JunkCategory(id: "priv:Firefox", title: "Firefox", subtitle: "Quit Firefox first.", icon: "flame", items: f)) }

        let recents = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        let r = make("Recent items list", Sizer.children(recents).filter { $0.lastPathComponent.contains("RecentDocuments") || $0.lastPathComponent.contains("RecentApplications") }, root: recents)
        if !r.isEmpty { cats.append(JunkCategory(id: "priv:recent", title: "Recent items", subtitle: "The Apple menu's recent apps and documents.", icon: "clock", items: r)) }
        return cats
    }

    static let browserBundles = ["Chrome": "com.google.Chrome", "Brave": "com.brave.Browser", "Edge": "com.microsoft.edgemac",
                                 "Arc": "company.thebrowser.Browser", "Vivaldi": "com.vivaldi.Vivaldi", "Opera": "com.operasoftware.Opera",
                                 "Safari": "com.apple.Safari", "Firefox": "org.mozilla.firefox"]
}
