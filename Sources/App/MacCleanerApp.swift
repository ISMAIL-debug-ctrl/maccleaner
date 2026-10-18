import SwiftUI

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var monitor = Monitor()
    @StateObject private var helper = HelperClient()
    @StateObject private var updater = Updater()
    @StateObject private var prefs = Prefs()

    var body: some Scene {
        Window("MacCleaner", id: "main") {
            MainView()
                .environmentObject(monitor).environmentObject(helper).environmentObject(updater).environmentObject(prefs)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 700)

        MenuBarExtra {
            MonitorPanel()
                .environmentObject(monitor).environmentObject(helper).environmentObject(updater).environmentObject(prefs)
        } label: {
            Image(systemName: monitor.mem.pressure >= 4 ? "exclamationmark.triangle.fill" : "memorychip")
            if prefs.showPercentInMenuBar { Text("\(monitor.usedPercent)%") }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started at login: stay in the menu bar only.
        if CommandLine.arguments.contains("--background") {
            DispatchQueue.main.async {
                for w in NSApp.windows where w.identifier?.rawValue.contains("main") == true || w.title == "MacCleaner" { w.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@MainActor
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard
    @Published var keepBrowserCaches: Bool { didSet { d.set(keepBrowserCaches, forKey: "keepBrowserCaches") } }
    @Published var skipRunningApps: Bool { didSet { d.set(skipRunningApps, forKey: "skipRunningApps") } }
    @Published var junkToTrash: Bool { didSet { d.set(junkToTrash, forKey: "junkToTrash") } }
    @Published var showPercentInMenuBar: Bool { didSet { d.set(showPercentInMenuBar, forKey: "showPercent") } }
    @Published var launchAtLogin: Bool { didSet { LoginItem.set(launchAtLogin) } }

    init() {
        d.register(defaults: ["keepBrowserCaches": true, "skipRunningApps": true, "junkToTrash": false, "showPercent": true])
        keepBrowserCaches = d.bool(forKey: "keepBrowserCaches")
        skipRunningApps = d.bool(forKey: "skipRunningApps")
        junkToTrash = d.bool(forKey: "junkToTrash")
        showPercentInMenuBar = d.bool(forKey: "showPercent")
        launchAtLogin = LoginItem.isEnabled
    }

    var junkOptions: JunkOptions {
        JunkOptions(keepBrowserCaches: keepBrowserCaches, skipRunningApps: skipRunningApps,
                    runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
    }
    var junkMode: DeleteMode { junkToTrash ? .trash : .permanent }
}

enum LoginItem {
    static let label = "com.ismailx.maccleaner.app"
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func set(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/Applications/MacCleaner.app/Contents/MacOS/MacCleaner", "--background"],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Live system numbers, shared by the menu bar and the Memory view.
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var mem = MemoryStats()
    @Published private(set) var disk = DiskStats()
    @Published private(set) var cpu = 0.0
    @Published private(set) var apps: [AppUsage] = []
    private let sampler = ProcessSampler()
    private var timer: Timer?
    private var tick = 0

    var usedPercent: Int { mem.total > 0 ? Int(Double(mem.used) / Double(mem.total) * 100) : 0 }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let m = Stats.memory()
        if m != mem { mem = m }
        cpu = Stats.cpu()
        if tick % 5 == 0 { disk = Stats.disk() }
        if tick % 2 == 0 {
            let s = sampler
            Task.detached {
                let a = s.sample()
                await MainActor.run { self.apps = a }
            }
        }
        tick += 1
    }

    func quit(_ app: AppUsage, force: Bool = false) {
        guard let r = NSRunningApplication(processIdentifier: app.pid) else { return }
        _ = force ? r.forceTerminate() : r.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }
}

extension ProcessSampler: @unchecked Sendable {}
