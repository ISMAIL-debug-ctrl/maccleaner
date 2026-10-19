import Foundation

// Protection basics. Not an antivirus: it lists things that start by themselves or run inside your
// browser, and flags the patterns real Mac adware/malware tends to use. You decide what to do.

enum Protection {
    static let suspiciousDirs = ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]

    static func flags(for item: LaunchItem) -> [String] {
        if item.label.hasPrefix("com.ismailx.maccleaner.") { return [] }  // our own helper / login item
        var f: [String] = []
        guard let prog = item.program else { return ["No program"] }
        if !item.programExists { f.append("Program is missing") }
        if item.signer == "Unsigned" { f.append("Unsigned") }
        if item.signer == "Ad-hoc" { f.append("Ad-hoc signed") }
        if suspiciousDirs.contains(where: { prog.hasPrefix($0) }) { f.append("Runs from a shared/temp folder") }
        if prog.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { f.append("Runs from a hidden folder") }
        let interpreters = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python3", "/usr/bin/osascript", "/usr/bin/curl"]
        if interpreters.contains(prog) { f.append("Runs a script") }
        if let c = item.created, Date().timeIntervalSince(c) < 7 * 86400 { f.append("Added this week") }
        return f
    }

    struct Extension: Identifiable, Hashable {
        var id: String { browser + "/" + extID }
        var browser: String
        var extID: String
        var name: String
        var version: String
        var permissions: [String]
        var folder: URL
        var risky: Bool { permissions.contains { ["<all_urls>", "webRequest", "nativeMessaging", "proxy", "debugger", "management"].contains($0) || $0.hasPrefix("*://*/") || $0 == "http://*/*" || $0 == "https://*/*" } }
    }

    static let chromiumBrowsers: [(String, String)] = [
        ("Chrome", "Library/Application Support/Google/Chrome"),
        ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Edge", "Library/Application Support/Microsoft Edge"),
        ("Arc", "Library/Application Support/Arc/User Data"),
        ("Vivaldi", "Library/Application Support/Vivaldi"),
        ("Opera", "Library/Application Support/com.operasoftware.Opera"),
    ]

    /// Chromium-family profiles (Default, Profile 1, …).
    static func profiles(_ root: URL) -> [URL] {
        Sizer.children(root).filter {
            let n = $0.lastPathComponent
            return n == "Default" || n.hasPrefix("Profile ")
        }
    }

    static func extensions(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Extension] {
        var out: [Extension] = []
        for (browser, rel) in chromiumBrowsers {
            for profile in profiles(home.appendingPathComponent(rel)) {
                for ext in Sizer.children(profile.appendingPathComponent("Extensions")) {
                    // Each extension folder holds one folder per version.
                    guard let ver = Sizer.children(ext).filter({ !$0.lastPathComponent.hasPrefix(".") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first,
                          let data = try? Data(contentsOf: ver.appendingPathComponent("manifest.json")),
                          let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    var name = m["name"] as? String ?? ext.lastPathComponent
                    if name.hasPrefix("__MSG_") { name = localized(name, in: ver) ?? ext.lastPathComponent }
                    var perms = (m["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
                    perms += (m["host_permissions"] as? [String]) ?? []
                    out.append(Extension(browser: browser + (profile.lastPathComponent == "Default" ? "" : " (\(profile.lastPathComponent))"),
                                         extID: ext.lastPathComponent, name: name, version: m["version"] as? String ?? "",
                                         permissions: perms, folder: ext))
                }
            }
        }
        // Firefox
        let ff = home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        for profile in Sizer.children(ff) {
            guard let data = try? Data(contentsOf: profile.appendingPathComponent("extensions.json")),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let addons = j["addons"] as? [[String: Any]] else { continue }
            for a in addons where (a["location"] as? String) == "app-profile" {
                let name = ((a["defaultLocale"] as? [String: Any])?["name"] as? String) ?? (a["id"] as? String ?? "?")
                let perms = ((a["userPermissions"] as? [String: Any])?["permissions"] as? [String] ?? [])
                    + ((a["userPermissions"] as? [String: Any])?["origins"] as? [String] ?? [])
                out.append(Extension(browser: "Firefox", extID: a["id"] as? String ?? "", name: name,
                                     version: a["version"] as? String ?? "", permissions: perms,
                                     folder: profile.appendingPathComponent("extensions")))
            }
        }
        // Safari web extensions live in apps; pluginkit lists them.
        let pk = Shell.run("/usr/bin/pluginkit", ["-mAv", "-p", "com.apple.Safari.web-extension"]).out
        for line in pk.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "\t").map(String.init)
            guard parts.count >= 2 else { continue }
            let idv = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "+-!= "))
            let bits = idv.split(separator: "(")
            out.append(Extension(browser: "Safari", extID: String(bits.first ?? ""),
                                 name: String(bits.first ?? "").components(separatedBy: ".").suffix(2).joined(separator: "."),
                                 version: bits.count > 1 ? String(bits[1].dropLast()) : "", permissions: [],
                                 folder: URL(fileURLWithPath: parts.last ?? "/")))
        }
        return out.sorted { ($0.browser, $0.name.lowercased()) < ($1.browser, $1.name.lowercased()) }
    }

    static func localized(_ key: String, in dir: URL) -> String? {
        let k = String(key.dropFirst(6).dropLast(2))
        for loc in ["en", "en_US", "en_GB"] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent("_locales/\(loc)/messages.json")),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let hit = j.first { $0.key.lowercased() == k.lowercased() }?.value as? [String: Any]
                if let m = hit?["message"] as? String { return m }
            }
        }
        return nil
    }
}
