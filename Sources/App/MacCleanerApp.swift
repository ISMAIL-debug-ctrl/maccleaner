import SwiftUI

import ServiceManagement

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var monitor: Monitor
    @StateObject private var helper: HelperClient
    @StateObject private var updater = Updater()
    @StateObject private var prefs: Prefs
    private let glyph = IconArt.menuBarGlyph()

    init() {
        let h = HelperClient(), p = Prefs()
        _helper = StateObject(wrappedValue: h)
        _prefs = StateObject(wrappedValue: p)
        _monitor = StateObject(wrappedValue: Monitor(helper: h, prefs: p))
    }

    var body: some Scene {
        Window("MacCleaner", id: "main") {
            MainView()
                .environmentObject(monitor).environmentObject(helper).environmentObject(updater).environmentObject(prefs)
                // Fill exactly the window. Without maxHeight the split view grew to its content's ideal height
                // (1400+ pt) and the window centred it, cutting the header and sidebar off at the top.
                .frame(minWidth: 920, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        }
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MonitorPanel()
                .environmentObject(monitor).environmentObject(helper).environmentObject(updater).environmentObject(prefs)
        } label: {
            Image(nsImage: glyph)   // the app's own mark, template so it follows light/dark
        }
        .menuBarExtraStyle(.window)
    }
}

/// Closing the window keeps MacCleaner in the menu bar; the Dock icon only shows while the window is open.
/// Quitting is done from the menu bar panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = CommandLine.arguments.contains("--background")
            || ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.migrateOldAgent()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, Self.isMain(w) else { return }
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { Self.isMain($0) && $0.isVisible && $0 !== w }) { NSApp.setActivationPolicy(.accessory) }
            }
        }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, Self.isMain(w), NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
        }
        if launchedAtLogin {
            DispatchQueue.main.async {
                for w in NSApp.windows where Self.isMain(w) { w.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    static func isMain(_ w: NSWindow) -> Bool { w.title == "MacCleaner" && !(w is NSPanel) && w.styleMask.contains(.titled) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@MainActor
final class Prefs: ObservableObject {
    private let d = UserDefaults.standard
    @Published var keepBrowserCaches: Bool { didSet { d.set(keepBrowserCaches, forKey: "keepBrowserCaches") } }
    @Published var skipRunningApps: Bool { didSet { d.set(skipRunningApps, forKey: "skipRunningApps") } }
    @Published var junkToTrash: Bool { didSet { d.set(junkToTrash, forKey: "junkToTrash") } }
    @Published var stopBackgroundHogs: Bool { didSet { d.set(stopBackgroundHogs, forKey: "stopBackgroundHogs") } }
    @Published var autoFreeRAM: Bool { didSet { d.set(autoFreeRAM, forKey: "autoFreeRAM") } }
    @Published var launchAtLogin: Bool { didSet { if launchAtLogin != oldValue { LoginItem.set(launchAtLogin) } } }

    init() {
        d.register(defaults: ["keepBrowserCaches": true, "skipRunningApps": true, "junkToTrash": false,
                              "stopBackgroundHogs": true, "autoFreeRAM": false])
        keepBrowserCaches = d.bool(forKey: "keepBrowserCaches")
        skipRunningApps = d.bool(forKey: "skipRunningApps")
        junkToTrash = d.bool(forKey: "junkToTrash")
        stopBackgroundHogs = d.bool(forKey: "stopBackgroundHogs")
        autoFreeRAM = d.bool(forKey: "autoFreeRAM")
        launchAtLogin = LoginItem.isEnabled
    }

    var junkOptions: JunkOptions {
        JunkOptions(keepBrowserCaches: keepBrowserCaches, skipRunningApps: skipRunningApps,
                    runningBundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
    }
    var junkMode: DeleteMode { junkToTrash ? .trash : .permanent }
}

/// Open at login through macOS's own Login Items (System Settings ▸ General ▸ Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Login item: \(error)") }
    }

    /// 1.0 used a LaunchAgent plist; switch it over to SMAppService.
    static func migrateOldAgent() {
        let old = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.ismailx.maccleaner.app.plist")
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        try? FileManager.default.removeItem(at: old)
        set(true)
    }
}

/// Live system numbers, shared by the menu bar and the Memory view.
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var mem = MemoryStats()
    @Published private(set) var disk = DiskStats()
    @Published private(set) var cpu = 0.0
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var freeing = false
    @Published private(set) var lastFree: String?
    private let sampler = ProcessSampler()
    private var timer: Timer?
    private var tick = 0
    private var lastAuto = Date.distantPast
    let helper: HelperClient
    let prefs: Prefs

    var usedPercent: Int { mem.total > 0 ? Int(Double(mem.used) / Double(mem.total) * 100) : 0 }

    init(helper: HelperClient, prefs: Prefs) {
        self.helper = helper
        self.prefs = prefs
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
        // Auto mode: when the kernel says memory is tight, do the safe part (purge + background services),
        // at most every 30 minutes. It never quits or relaunches your apps.
        if prefs.autoFreeRAM, m.pressure >= 2, !freeing, Date().timeIntervalSince(lastAuto) > 1800 {
            lastAuto = Date()
            freeRAM(auto: true)
        }
    }

    /// Purge + stop background hogs, then measure again. Reports only what really changed.
    func freeRAM(auto: Bool = false) {
        guard !freeing else { return }
        freeing = true
        let before = MemSnapshot(Stats.memory())
        let hogs = prefs.stopBackgroundHogs
        let finish: (HelperResult?) -> Void = { r in
            Task.detached {
                let stopped = hogs ? RAMFree.stopBackgroundHogs() : []
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let after = MemSnapshot(Stats.memory())
                await MainActor.run {
                    var parts: [String] = []
                    if let r, !r.ok { parts.append("purge: \(r.message)") }
                    if !stopped.isEmpty {
                        parts.append("Stopped \(stopped.map(\.name).joined(separator: ", ")) (\(Fmt.mem(stopped.reduce(0) { $0 + $1.bytes }))) — macOS restarts them when needed")
                    }
                    parts.append(MemSnapshot.report(before, after))
                    self.lastFree = (auto ? "Auto: " : "") + parts.joined(separator: "\n")
                    self.freeing = false
                    self.refresh()
                }
            }
        }
        // Auto mode never shows a password prompt: without the helper it only stops background services.
        if helper.busy == nil && (helper.alive || !auto) { helper.run(.purgeRAM) { finish($0) } } else { finish(nil) }
    }

    func relaunch(_ app: AppUsage) {
        Task {
            let r = await RAMFree.relaunch(pid: app.pid)
            lastFree = switch r {
            case .done: "Relaunched \(app.name) — it started fresh (was \(Fmt.mem(app.memory)))."
            case .stillOpen: "\(app.name) is still open — it may be asking you to save something."
            case .failed: "Couldn't relaunch \(app.name)."
            }
            refresh()
        }
    }

    func quit(_ app: AppUsage, force: Bool = false) {
        guard let r = NSRunningApplication(processIdentifier: app.pid) else { return }
        _ = force ? r.forceTerminate() : r.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }
}

extension ProcessSampler: @unchecked Sendable {}
