import Foundation

// System Junk: whitelist of folders whose *contents* macOS and apps rebuild on their own.
// Carried over from the original Mac-Cleaner.command — same folders, same exclusions.

struct JunkItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case file(URL, root: URL)          // entry inside a whitelisted folder
        case command(String, [String])     // a developer tool's own cleanup command
        case info                          // shown, never deleted
    }
    var id: String
    var name: String
    var detail: String = ""
    var bytes: Int64
    var kind: Kind
    var selected: Bool
}

struct JunkCategory: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var icon: String
    var items: [JunkItem]
    var selectedBytes: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.bytes } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

struct JunkOptions {
    var keepBrowserCaches = true
    var skipRunningApps = true
    var runningBundleIDs: Set<String> = []
}

enum JunkScanner {
    /// Browser caches are kept on purpose (faster sites, no re-downloads). Same list as the script.
    static let browserKeep = try! NSRegularExpression(pattern:
        #"^(Google|com\.google\..*|com\.apple\.Safari.*|com\.apple\.WebKit.*|Firefox|Mozilla|org\.mozilla\..*|BraveSoftware|com\.brave\..*|Microsoft Edge|com\.microsoft\.edgemac.*|Arc|company\.thebrowser\..*|com\.operasoftware\..*|Opera.*|Vivaldi|com\.vivaldi\..*|Chromium|org\.chromium\..*)$"#)

    static func isBrowser(_ name: String) -> Bool {
        let n = name.hasSuffix(".savedState") ? String(name.dropLast(11)) : name
        return browserKeep.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
    }

    /// Caches macOS protects (SIP/TCC); listing them would only produce "couldn't remove".
    static let systemLocked: Set<String> = ["CloudKit", "FamilyCircle", "com.apple.HomeKit", "com.apple.ap.adprivacyd",
                                            "com.apple.homed", "com.apple.containermanagerd", "com.apple.findmy.fmipcore"]

    struct Folder { let rel: String; let label: String; let filterBrowsers: Bool }

    static func scan(home: URL, options: JunkOptions) -> [JunkCategory] {
        let L = "Library"
        var cats: [JunkCategory] = []

        cats.append(category(home: home, id: "caches", title: "User caches", icon: "archivebox",
            subtitle: options.keepBrowserCaches ? "App caches. Browser caches are kept." : "App caches, including browsers.",
            folders: [Folder(rel: "\(L)/Caches", label: "", filterBrowsers: options.keepBrowserCaches)], options: options))

        cats.append(category(home: home, id: "logs", title: "Logs & crash reports", icon: "doc.text",
            subtitle: "Diagnostic logs apps write and never read again.",
            folders: [Folder(rel: "\(L)/Logs", label: "", filterBrowsers: false),
                      Folder(rel: "\(L)/Application Support/CrashReporter", label: "CrashReporter", filterBrowsers: false)],
            options: options))

        cats.append(category(home: home, id: "state", title: "Saved app states", icon: "macwindow.on.rectangle",
            subtitle: "Window positions macOS restores on relaunch. Browsers are kept.",
            folders: [Folder(rel: "\(L)/Saved Application State", label: "", filterBrowsers: true)], options: options))

        var dev = category(home: home, id: "dev", title: "Developer leftovers", icon: "hammer",
            subtitle: "Xcode build data, simulators, package manager caches.",
            folders: [Folder(rel: "\(L)/Developer/Xcode/DerivedData", label: "DerivedData", filterBrowsers: false),
                      Folder(rel: "\(L)/Developer/Xcode/iOS DeviceSupport", label: "iOS DeviceSupport", filterBrowsers: false),
                      Folder(rel: "\(L)/Developer/Xcode/watchOS DeviceSupport", label: "watchOS DeviceSupport", filterBrowsers: false),
                      Folder(rel: "\(L)/Developer/CoreSimulator/Caches", label: "Simulator caches", filterBrowsers: false),
                      Folder(rel: ".gradle/caches", label: "Gradle", filterBrowsers: false),
                      Folder(rel: ".cocoapods/repos", label: "CocoaPods", filterBrowsers: false),
                      Folder(rel: ".npm/_cacache", label: "npm", filterBrowsers: false)],
            options: options, group: true)
        for (tool, args, label) in devCommands() {
            dev.items.append(JunkItem(id: "cmd:" + label, name: label, detail: "Runs the tool's own cleanup",
                                      bytes: 0, kind: .command(tool, args), selected: true))
        }
        cats.append(dev)

        cats.append(category(home: home, id: "updates", title: "Old device updates", icon: "iphone",
            subtitle: "iPhone and iPad update files Finder downloaded.",
            folders: [Folder(rel: "\(L)/iTunes/iPhone Software Updates", label: "iPhone updates", filterBrowsers: false),
                      Folder(rel: "\(L)/iTunes/iPad Software Updates", label: "iPad updates", filterBrowsers: false)],
            options: options, group: true))

        cats.append(LoginItems.brokenAgents(home: home))
        cats.append(Languages.report())
        return cats.filter { !$0.items.isEmpty }
    }

    /// One item per entry inside each folder, or (group) one item per folder.
    static func category(home: URL, id: String, title: String, icon: String, subtitle: String,
                         folders: [Folder], options: JunkOptions, group: Bool = false) -> JunkCategory {
        var items: [JunkItem] = []
        let fm = FileManager.default
        for f in folders {
            let root = home.appendingPathComponent(f.rel)
            guard Safety(home: home).isRealDirectory(root.path),
                  let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name != ".DS_Store" && !systemLocked.contains(name) {
                if f.filterBrowsers && isBrowser(name) { continue }
                let bare = name.replacingOccurrences(of: ".savedState", with: "")
                let isRunning = options.skipRunningApps && options.runningBundleIDs.contains(bare)
                let url = root.appendingPathComponent(name)
                let b = Sizer.size(of: url)
                if group {
                    items.append(JunkItem(id: url.path, name: name, detail: f.label, bytes: b,
                                          kind: .file(url, root: root), selected: true))
                } else {
                    items.append(JunkItem(id: url.path, name: name, detail: isRunning ? "App is open — skipped" : f.label,
                                          bytes: b, kind: isRunning ? .info : .file(url, root: root), selected: !isRunning))
                }
            }
        }
        items.sort { $0.bytes > $1.bytes }
        return JunkCategory(id: id, title: title, subtitle: subtitle, icon: icon, items: items)
    }

    static func devCommands() -> [(String, [String], String)] {
        var out: [(String, [String], String)] = []
        let fm = FileManager.default
        func find(_ name: String) -> String? {
            ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map { $0 + name }.first { fm.isExecutableFile(atPath: $0) }
        }
        if let b = find("brew") { out.append((b, ["cleanup", "-s", "--prune=all"], "Homebrew cleanup")) }
        if let x = find("xcrun"), fm.fileExists(atPath: "/Applications/Xcode.app") {
            out.append((x, ["simctl", "delete", "unavailable"], "Unavailable simulators"))
        }
        if let y = find("yarn") { out.append((y, ["cache", "clean"], "yarn cache")) }
        if let p = find("pnpm") { out.append((p, ["store", "prune"], "pnpm store")) }
        return out
    }

    /// Runs the selected junk. Commands run as the user with a fixed PATH.
    static func clean(_ cats: [JunkCategory], safety: Safety, mode: DeleteMode) -> DeleteReport {
        let all = cats.flatMap(\.items).filter(\.selected)
        // Broken login agents: unload before their plist goes.
        for it in all where it.id.hasPrefix("agent:") {
            if case .file(let u, _) = it.kind { LoginItems.bootout(plist: u) }
        }
        var files: [(url: URL, root: URL, bytes: Int64)] = []
        var toTrash: [(url: URL, root: URL, bytes: Int64)] = []
        var report = DeleteReport()
        for it in all {
            switch it.kind {
            case .file(let u, let root):
                // Leftovers of deleted apps and broken agents may hold settings: always via the Trash.
                if it.id.hasPrefix("left:") || it.id.hasPrefix("agent:") { toTrash.append((u, root, it.bytes)) }
                else { files.append((u, root, it.bytes)) }
            case .command(let tool, let args):
                if Shell.run(tool, args, timeout: 600).code == 0 { report.count += 1 }
            case .info: break
            }
        }
        for r in [Deleter.deleteJunk(files, safety: safety, mode: mode), Deleter.deleteJunk(toTrash, safety: safety, mode: .trash)] {
            report.freed += r.freed; report.count += r.count; report.failed += r.failed
        }
        // Broken login agents: unload them too.
        return report
    }
}

/// Unused language files inside app bundles. Reported only: on macOS 13+ editing a signed app breaks
/// its signature (Gatekeeper may refuse to open it), so a safe cleaner must not strip them.
enum Languages {
    static func report() -> JunkCategory {
        let keep = Set(Locale.preferredLanguages.flatMap { l -> [String] in
            let base = String(l.split(separator: "-").first ?? "")
            return [l, base, "Base", "en", "English"]
        })
        var total: Int64 = 0, apps = 0
        for app in (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [] where app.hasSuffix(".app") {
            let res = URL(fileURLWithPath: "/Applications/\(app)/Contents/Resources")
            var found = false
            for name in (try? FileManager.default.contentsOfDirectory(atPath: res.path)) ?? [] where name.hasSuffix(".lproj") {
                let lang = String(name.dropLast(6))
                if keep.contains(lang) || keep.contains(String(lang.split(separator: "_").first ?? "")) { continue }
                total += Sizer.size(of: res.appendingPathComponent(name)); found = true
            }
            if found { apps += 1 }
        }
        guard total > 0 else { return JunkCategory(id: "lang", title: "", subtitle: "", icon: "", items: []) }
        return JunkCategory(id: "lang", title: "Language files (report only)",
            subtitle: "Removing them breaks app signatures on modern macOS, so MacCleaner leaves them.", icon: "globe",
            items: [JunkItem(id: "lang", name: "Unused languages in \(apps) apps", detail: "Not removed",
                             bytes: total, kind: .info, selected: false)])
    }
}

enum Shell {
    static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        e["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return e
    }()

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
