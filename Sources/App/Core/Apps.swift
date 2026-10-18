import AppKit

// Uninstaller (app + its leftovers), leftovers of apps already deleted, and the Updater.

struct InstalledApp: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var bundleID: String
    var version: String
    var size: Int64
    var lastUsed: Date?
    var fromAppStore: Bool
    var sparkleFeed: URL?
    var isApple: Bool
}

struct Leftover: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var bytes: Int64
    var selected = true
}

enum AppInventory {
    static func list(includeSize: Bool = true) -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let u = dir.appendingPathComponent(name)
                if name.hasSuffix(".app") { urls.append(u) }
                else if Safety().isRealDirectory(u.path) {  // one level of sub-folders (e.g. /Applications/Utilities-like vendor folders)
                    for sub in (try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? [] where sub.hasSuffix(".app") {
                        urls.append(u.appendingPathComponent(sub))
                    }
                }
            }
        }
        return urls.compactMap { load($0, includeSize: includeSize) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func load(_ url: URL, includeSize: Bool) -> InstalledApp? {
        guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
        let info = b.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let md = MDItemCreateWithURL(nil, url as CFURL)
        let lastUsed = md.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        return InstalledApp(url: url, name: name, bundleID: id,
                            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "",
                            size: includeSize ? Sizer.size(of: url) : 0, lastUsed: lastUsed,
                            fromAppStore: FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path),
                            sparkleFeed: feed?.scheme == "https" ? feed : nil,
                            isApple: id.hasPrefix("com.apple."))
    }

    /// Library folders apps leave data in. Matched by bundle id (and, for Application Support / Caches / Logs, by app name).
    static let leftoverDirs: [(String, Bool)] = [  // (folder, also match by app name)
        ("Library/Application Support", true), ("Library/Caches", true), ("Library/Logs", true),
        ("Library/Preferences", false), ("Library/Containers", false), ("Library/Group Containers", false),
        ("Library/Saved Application State", false), ("Library/HTTPStorages", false), ("Library/WebKit", false),
        ("Library/Cookies", false), ("Library/Application Scripts", false), ("Library/LaunchAgents", false),
        ("Library/Preferences/ByHost", false),
    ]

    /// Files that belong to one app. Exact matches only, so "Notes" never matches "NotesHelper".
    static func leftovers(bundleID: String, name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Leftover] {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("com.apple.") else { return [] }
        let idLower = bundleID.lowercased(), nameLower = name.lowercased()
        var out: [Leftover] = []
        for (rel, byName) in leftoverDirs {
            let dir = home.appendingPathComponent(rel)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let e = entry.lowercased()
                let stem = (e as NSString).deletingPathExtension
                let matchesID = e == idLower || stem == idLower || e.hasPrefix(idLower + ".") || stem.hasSuffix("." + idLower)
                    || (rel == "Library/Group Containers" && e.hasSuffix("." + idLower))
                let matchesName = byName && nameLower.count >= 4 && e == nameLower
                if matchesID || matchesName {
                    let u = dir.appendingPathComponent(entry)
                    out.append(Leftover(url: u, bytes: Sizer.size(of: u)))
                }
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Data folders named like a bundle id whose app is no longer installed anywhere.
    /// Deliberately conservative: anything from a vendor that still has an app, agent or plug-in on this Mac
    /// is left alone, and so are licences and shared frameworks.
    static func orphanLeftovers(home: URL = FileManager.default.homeDirectoryForCurrentUser, installed: Set<String>) -> [Leftover] {
        let idLike = try! NSRegularExpression(pattern: #"^[a-z0-9-]+(\.[a-z0-9-]+){2,}$"#, options: .caseInsensitive)
        func vendor(_ id: String) -> String { id.lowercased().split(separator: ".").prefix(2).joined(separator: ".") }
        var known = Set(installed.map(vendor))
        known.formUnion(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).map(vendor))
        for dir in ["/Library/LaunchAgents", "/Library/LaunchDaemons", home.appendingPathComponent("Library/LaunchAgents").path,
                    "/Library/PrivilegedHelperTools"] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { known.insert(vendor(f)) }
        }
        // Company words (e.g. "stremio", "borisfx") that still show up in apps, running apps or support folders.
        var companyWords = Set<String>()
        func addWords(_ s: String) { for w in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where w.count >= 4 { companyWords.insert(String(w)) } }
        for app in AppInventory.list(includeSize: false) { addWords(app.name); addWords(app.bundleID) }
        for r in NSWorkspace.shared.runningApplications { addWords(r.localizedName ?? ""); addWords(r.bundleIdentifier ?? "") }
        for dir in ["/Library/Application Support", "/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST3",
                    "/Library/Application Support/Adobe/Common/Plug-ins", "/Applications"] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { addWords(f) }
        }
        let common: Set<String> = ["apple", "google", "microsoft", "software", "studio", "media", "helper", "player"]
        companyWords.subtract(common)
        let neverPrefixes = ["com.apple.", "systemgroup.", "group.", "org.cups.", "org.sparkle-project.", "com.google.keystone"]
        let neverWords = ["lic", "license", "licence", "serial", "activation", "registration", "helper", "agent", "daemon", "plugin", "fxplug", "shared", "cli", "filter"]
        var out: [Leftover] = []
        for rel in ["Library/Application Support", "Library/Caches", "Library/Containers", "Library/Saved Application State",
                    "Library/HTTPStorages", "Library/WebKit", "Library/Preferences"] {
            let dir = home.appendingPathComponent(rel)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                var id = entry
                for ext in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
                let lower = id.lowercased()
                let words = lower.split(whereSeparator: { !$0.isLetter })
                guard idLike.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil,
                      !neverPrefixes.contains(where: lower.hasPrefix),
                      !words.contains(where: { w in neverWords.contains(String(w)) }),
                      !known.contains(vendor(id)),
                      lower.split(separator: ".").dropFirst().prefix(1).allSatisfy({ !companyWords.contains(String($0)) }),
                      rel != "Library/Preferences" || entry.hasSuffix(".plist"),
                      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil,
                      !existsAnywhere(bundleID: id) else { continue }
                let u = dir.appendingPathComponent(entry)
                out.append(Leftover(url: u, bytes: Sizer.size(of: u), selected: false))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Spotlight: is any bundle (app, plug-in, extension) with this id still on disk?
    static func existsAnywhere(bundleID: String) -> Bool {
        guard bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return true }
        return !Shell.run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(bundleID)'"], timeout: 10).out
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Updater (list outdated apps; never installs anything by itself)

struct AppUpdate: Identifiable, Hashable {
    var id: String { app.id }
    var app: InstalledApp
    var latest: String
    var source: String   // "App Store", "Sparkle", "Homebrew"
    var link: URL?
}

enum UpdateChecker {
    static func check(_ apps: [InstalledApp]) async -> [AppUpdate] {
        await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps where !app.isApple {
                group.addTask {
                    if app.fromAppStore { return await appStore(app) }
                    if app.sparkleFeed != nil { return await sparkle(app) }
                    return nil
                }
            }
            var out: [AppUpdate] = []
            for await u in group { if let u { out.append(u) } }
            out += brewOutdated(apps)
            return out.sorted { $0.app.name.lowercased() < $1.app.name.lowercased() }
        }
    }

    static func newer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    static func appStore(_ app: InstalledApp) async -> AppUpdate? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [URLQueryItem(name: "bundleId", value: app.bundleID), URLQueryItem(name: "entity", value: "macSoftware")]
        guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = (j["results"] as? [[String: Any]])?.first, let v = r["version"] as? String,
              newer(v, than: app.version) else { return nil }
        let link = (r["trackViewUrl"] as? String).flatMap(URL.init(string:)).map {
            URL(string: $0.absoluteString.replacingOccurrences(of: "https://", with: "macappstore://")) ?? $0
        }
        return AppUpdate(app: app, latest: v, source: "App Store", link: link)
    }

    static func sparkle(_ app: InstalledApp) async -> AppUpdate? {
        guard let feed = app.sparkleFeed else { return nil }
        var req = URLRequest(url: feed, timeoutInterval: 15)
        req.setValue("MacCleaner", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req), data.count < 5_000_000 else { return nil }
        let p = AppcastParser(); let x = XMLParser(data: data); x.delegate = p; x.parse()
        guard let best = p.versions.max(by: { !newer($0, than: $1) }) else { return nil }
        let installedBuild = Bundle(url: app.url)?.infoDictionary?["CFBundleVersion"] as? String ?? app.version
        let isNew = p.shortFor[best].map { newer($0, than: app.version) } ?? newer(best, than: installedBuild)
        guard isNew else { return nil }
        return AppUpdate(app: app, latest: p.shortFor[best] ?? best, source: "Sparkle", link: nil)
    }

    static func brewOutdated(_ apps: [InstalledApp]) -> [AppUpdate] {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let out = Shell.run(brew, ["outdated", "--cask", "--greedy", "--verbose"], timeout: 120).out
        var res: [AppUpdate] = []
        for line in out.split(separator: "\n") {
            // "visual-studio-code (1.2.3) != 1.2.4"
            let parts = line.components(separatedBy: " != ")
            guard parts.count == 2 else { continue }
            let token = parts[0].split(separator: " ").first.map(String.init) ?? ""
            let norm = token.replacingOccurrences(of: "-", with: "").lowercased()
            if let app = apps.first(where: { $0.name.replacingOccurrences(of: " ", with: "").lowercased() == norm }),
               !app.fromAppStore, app.sparkleFeed == nil {
                res.append(AppUpdate(app: app, latest: parts[1], source: "Homebrew (brew upgrade --cask \(token))", link: nil))
            }
        }
        return res
    }
}

final class AppcastParser: NSObject, XMLParserDelegate {
    var versions: [String] = []
    var shortFor: [String: String] = [:]
    private var text = ""
    private var currentVersion: String?
    private var currentShort: String?
    private var beta = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        if name == "item" { currentVersion = nil; currentShort = nil; beta = false }
        if name == "enclosure" {
            if let v = a["sparkle:version"] { currentVersion = v }
            if let s = a["sparkle:shortVersionString"] { currentShort = s }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "sparkle:version" { currentVersion = t }
        if name == "sparkle:shortVersionString" { currentShort = t }
        if name == "sparkle:channel" { beta = true }  // beta/nightly channels are not offered
        if name == "item", !beta, let v = currentVersion {
            versions.append(v)
            if let s = currentShort { shortFor[v] = s }
        }
    }
}
