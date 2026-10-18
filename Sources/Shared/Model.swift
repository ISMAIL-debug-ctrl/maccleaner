import Foundation

// Shared between the app (runs as the user) and the root helper.
//
// Security model (same as XCharge):
// - App → helper: command.json in the logged-in user's own ~/Library/Application Support/MacCleaner (0700).
//   The helper only *reads* it, only for the console user, refusing symlinks, non-regular files,
//   foreign owners and oversized files. A command is a fixed action name — never a path or a shell string.
// - Helper → app: status.json in root-owned /Library/Application Support/MacCleaner (0755).
enum Paths {
    static let rootDir = URL(fileURLWithPath: "/Library/Application Support/MacCleaner")
    static let status = rootDir.appendingPathComponent("status.json")
    static let helperLabel = "com.ismailx.maccleaner.helper"

    static func userDir(home: URL) -> URL { home.appendingPathComponent("Library/Application Support/MacCleaner") }
    static func command(home: URL) -> URL { userDir(home: home).appendingPathComponent("command.json") }
}

/// Everything the root helper can do. Each one runs a fixed, built-in operation.
enum HelperAction: String, Codable, CaseIterable {
    case scanSystemJunk     // measure root-owned caches / crash reports / rotated logs / local snapshots
    case cleanSystemJunk    // delete root-owned entries in those fixed folders
    case purgeRAM           // /usr/sbin/purge
    case flushDNS           // dscacheutil -flushcache + HUP mDNSResponder
    case reindexSpotlight   // mdutil -E /
    case maintenanceScripts // periodic (if present) or newsyslog + locate.updatedb
    case thinSnapshots      // tmutil thinlocalsnapshots /
    case repairPermissions  // diskutil resetUserPermissions / <console uid>

    /// Minimum seconds between two runs, so a local program can't make the helper hammer the disk.
    var cooldown: TimeInterval {
        switch self {
        case .reindexSpotlight, .repairPermissions: return 600
        case .maintenanceScripts, .thinSnapshots: return 120
        default: return 3
        }
    }
}

struct HelperCommand: Codable {
    var action: HelperAction
    var id = UUID()
    var created = Date()  // stale commands (> 60 s) are ignored
}

struct SystemJunkItem: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var path: String
    var bytes: Int64
    var count: Int
}

struct HelperResult: Codable, Equatable {
    var id: UUID
    var action: HelperAction
    var ok: Bool
    var message: String
    var finished: Date
}

struct HelperStatus: Codable, Equatable {
    var updated = Date()
    var version = ""
    var running: HelperAction?
    var last: HelperResult?
    var systemJunk: [SystemJunkItem] = []
    var systemJunkScanned: Date?
}

extension JSONEncoder {
    static let mc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let mc: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder.mc.decode(type, from: data)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL, mode: Int = 0o644) {
    guard let data = try? JSONEncoder.mc.encode(value) else { return }
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}
