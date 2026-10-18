import Foundation
import Security

// Launch agents / daemons: broken login items (System Junk), Optimization list, Protection checks.

struct LaunchItem: Identifiable, Hashable {
    enum Scope: String { case user = "Your agents", allAgents = "All-user agents", daemons = "System daemons" }
    var id: String { plist.path }
    var label: String
    var plist: URL
    var program: String?
    var scope: Scope
    var loaded: Bool
    var programExists: Bool
    var signer: String          // "Apple", team name, "Unsigned", "Ad-hoc", "Missing"
    var flags: [String]         // reasons it looks suspicious
    var created: Date?
}

enum LoginItems {
    static func read(_ plist: URL) -> (label: String, program: String?)? {
        guard let d = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        let label = d["Label"] as? String ?? plist.deletingPathExtension().lastPathComponent
        let prog = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
        return (label, prog)
    }

    static func list(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LaunchItem] {
        let dirs: [(URL, LaunchItem.Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .allAgents),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemons),
        ]
        let loadedUser = Set(Shell.run("/bin/launchctl", ["list"]).out.split(separator: "\n")
            .compactMap { $0.split(separator: "\t").last.map(String.init) })
        var out: [LaunchItem] = []
        for (dir, scope) in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".plist") {
                let url = dir.appendingPathComponent(name)
                guard let (label, prog) = read(url) else { continue }
                let exists = prog.map { FileManager.default.fileExists(atPath: $0) } ?? false
                let signer = prog.map { exists ? Signing.signer(of: $0) : "Missing" } ?? "Missing"
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                var item = LaunchItem(label: label, plist: url, program: prog, scope: scope,
                                      loaded: scope == .daemons ? false : loadedUser.contains(label),
                                      programExists: exists, signer: signer, flags: [], created: created)
                item.flags = Protection.flags(for: item)
                out.append(item)
            }
        }
        return out.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    /// Agents in ~/Library/LaunchAgents whose program no longer exists (app was deleted).
    static func brokenAgents(home: URL) -> JunkCategory {
        let dir = home.appendingPathComponent("Library/LaunchAgents")
        var items: [JunkItem] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".plist") {
            let url = dir.appendingPathComponent(name)
            guard let (_, prog) = read(url), let prog, !FileManager.default.fileExists(atPath: prog) else { continue }
            items.append(JunkItem(id: "agent:" + url.path, name: name, detail: "Missing: " + prog,
                                  bytes: Sizer.size(of: url), kind: .file(url, root: dir), selected: true))
        }
        return JunkCategory(id: "agents", title: "Broken login items",
                            subtitle: "Launch agents left behind by apps you deleted.", icon: "exclamationmark.triangle", items: items)
    }

    static var uid: String { String(getuid()) }

    static func bootout(plist: URL) {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", plist.path])
    }

    /// Reversible: stop it now and mark it disabled; the plist stays where it is.
    static func disable(_ item: LaunchItem) -> Bool {
        guard item.scope == .user else { return false }
        bootout(plist: item.plist)
        return Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(item.label)"]).code == 0
    }

    static func enable(_ item: LaunchItem) -> Bool {
        guard item.scope == .user else { return false }
        _ = Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(item.label)"])
        return Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.plist.path]).code == 0
    }

    static func disabledLabels() -> Set<String> {
        let out = Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).out
        var s = Set<String>()
        for line in out.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let q = line.split(separator: "\"").dropFirst().first { s.insert(String(q)) }
        }
        return s
    }
}

enum Signing {
    /// Who signed a binary or bundle, without running it.
    static func signer(of path: String) -> String {
        var url = URL(fileURLWithPath: path)
        // Point at the .app bundle when the program lives inside one.
        if let r = path.range(of: ".app/") { url = URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return "Unknown" }
        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess,
           SecStaticCodeCheckValidity(code, [], req) == errSecSuccess { return "Apple" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return "Unsigned" }
        if let team = d[kSecCodeInfoTeamIdentifier as String] as? String {
            if let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
               let name = SecCertificateCopySubjectSummary(leaf) as String? {
                return name.replacingOccurrences(of: "Developer ID Application: ", with: "")
            }
            return team
        }
        if let flags = d[kSecCodeInfoFlags as String] as? UInt32, flags & 0x2 != 0 { return "Ad-hoc" }
        return d[kSecCodeInfoIdentifier as String] == nil ? "Unsigned" : "Ad-hoc"
    }
}
