import Foundation

// Runs the cleaning core against a fake home folder in a temp directory. Never touches the real home.
// Run: ./Tests/run.sh

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("maccleaner-test-\(UUID().uuidString)")
let home = base.appendingPathComponent("home")
defer { try? fm.removeItem(at: base) }

func mk(_ rel: String, _ bytes: Int = 4096, root: URL = home) {
    let u = root.appendingPathComponent(rel)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(repeating: 7, count: bytes).write(to: u)
}
func exists(_ rel: String) -> Bool {
    var st = stat(); return lstat(home.appendingPathComponent(rel).path, &st) == 0
}

// Fake home
mk("Documents/important.txt")
mk("Desktop/project.prproj")
mk("Library/Caches/com.foo.app/data.bin", 100_000)
mk("Library/Caches/com.running.app/data.bin")
mk("Library/Caches/Google/Chrome/cache.bin")
mk("Library/Caches/BraveSoftware/Brave-Browser/cache.bin")
mk("Library/Caches/com.apple.Safari/cache.bin")
mk("Library/Logs/old.log")
mk("Library/Saved Application State/com.foo.app.savedState/data")
mk("Library/Saved Application State/com.google.Chrome.savedState/data")
mk("Library/Preferences/com.foo.app.plist")
mk("Library/Developer/Xcode/DerivedData/Proj-abc/Build/x.o", 50_000)
try! fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/evil-link"), withDestinationURL: home.appendingPathComponent("Documents"))
// Broken launch agent
try! fm.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
(["Label": "com.dead.agent", "Program": "/nonexistent/dead"] as NSDictionary)
    .write(to: home.appendingPathComponent("Library/LaunchAgents/com.dead.agent.plist"), atomically: true)
(["Label": "com.alive.agent", "Program": "/bin/ls"] as NSDictionary)
    .write(to: home.appendingPathComponent("Library/LaunchAgents/com.alive.agent.plist"), atomically: true)

print("System Junk scan")
let opts = JunkOptions(keepBrowserCaches: true, skipRunningApps: true, runningBundleIDs: ["com.running.app"])
var cats = JunkScanner.scan(home: home, options: opts)
let ids = Set(cats.flatMap(\.items).filter { if case .file = $0.kind { return true }; return false }.map(\.name))
check(ids.contains("com.foo.app"), "finds app cache")
check(!ids.contains("Google") && !ids.contains("BraveSoftware") && !ids.contains("com.apple.Safari"), "keeps browser caches")
check(!ids.contains("com.google.Chrome.savedState"), "keeps browser saved state")
check(cats.flatMap(\.items).first { $0.name == "com.running.app" }.map { if case .info = $0.kind { return true }; return false } ?? false,
      "running app's cache is shown but not deletable")
check(ids.contains("com.dead.agent.plist") && !ids.contains("com.alive.agent.plist"), "broken agent found, working one ignored")
check(ids.contains("Proj-abc"), "finds DerivedData")

// Never run real developer tool commands from a test.
for c in cats.indices { for i in cats[c].items.indices { if case .command = cats[c].items[i].kind { cats[c].items[i].selected = false } } }
// Broken agents go to the real Trash; deselect them here and test the rule separately.
for c in cats.indices { for i in cats[c].items.indices where cats[c].items[i].id.hasPrefix("agent:") { cats[c].items[i].selected = false } }

print("System Junk clean")
let r = JunkScanner.clean(cats, safety: Safety(home: home), mode: .permanent)
check(!exists("Library/Caches/com.foo.app"), "app cache removed")
check(exists("Library/Caches"), "Caches folder itself kept")
check(exists("Library/Caches/Google/Chrome/cache.bin"), "browser cache still there")
check(exists("Library/Caches/com.running.app/data.bin"), "running app cache still there")
check(exists("Documents/important.txt"), "symlink target (Documents) untouched")
check(!exists("Library/Caches/evil-link"), "the symlink itself was removed")
check(exists("Desktop/project.prproj"), "Desktop untouched")
check(exists("Library/Preferences/com.foo.app.plist"), "preferences untouched")
check(r.freed > 0 && r.failed.isEmpty, "report: \(r.summary)")

print("Safety rules")
let s = Safety(home: home)
mk("Library/Caches/realdir/file")
try! fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/linkdir"), withDestinationURL: home.appendingPathComponent("Documents"))
let caches = home.appendingPathComponent("Library/Caches")
check(s.isInside(caches.appendingPathComponent("realdir/file"), root: caches), "inside a real folder: allowed")
check(!s.isInside(caches.appendingPathComponent("linkdir/important.txt"), root: caches), "through a linked folder: refused")
check(!s.isInside(caches.appendingPathComponent("../Preferences/com.foo.app.plist"), root: caches), "../ escape: refused")
check(!s.isInside(caches, root: caches), "the root itself: refused")
check(!s.mayTrashUserSelection(home), "home itself: refused")
check(!s.mayTrashUserSelection(home.appendingPathComponent("Documents")), "Documents itself: refused")
check(!s.mayTrashUserSelection(home.appendingPathComponent("Library")), "Library itself: refused")
check(s.mayTrashUserSelection(home.appendingPathComponent("Documents/important.txt")), "a file you picked in Documents: allowed")
check(!s.mayTrashUserSelection(URL(fileURLWithPath: "/System/Library/x")), "/System: refused")
check(!s.mayTrashUserSelection(URL(fileURLWithPath: "/Library/Preferences/x")), "/Library: refused")
check(!s.mayTrashUserSelection(URL(fileURLWithPath: "/Users/someoneelse/file")), "another user's home: refused")
check(s.mayTrashUserSelection(URL(fileURLWithPath: "/Applications/Foo.app")), "an app in /Applications: allowed")
check(!s.mayTrashUserSelection(URL(fileURLWithPath: "/Applications/Foo.app/Contents/Info.plist")), "inside an app bundle: refused")
check(!s.mayTrashUserSelection(URL(fileURLWithPath: "/Applications")), "/Applications itself: refused")

print("Leftovers matching")
mk("Library/Application Support/com.foo.app/db")
mk("Library/Application Support/com.foobar.app/db")
mk("Library/Containers/com.foo.app/x")
mk("Library/Application Support/Foo/x")
let left = Set(AppInventory.leftovers(bundleID: "com.foo.app", name: "Foo", home: home).map { $0.url.path.replacingOccurrences(of: home.path + "/", with: "") })
check(left.contains("Library/Application Support/com.foo.app"), "matches by bundle id")
check(left.contains("Library/Preferences/com.foo.app.plist"), "matches preferences plist")
check(left.contains("Library/Containers/com.foo.app"), "matches container")
check(!left.contains("Library/Application Support/com.foobar.app"), "does not match a similar id")
check(!left.contains("Library/Application Support/Foo"), "short names (< 4 letters) are not matched by name")
check(AppInventory.leftovers(bundleID: "com.apple.Safari", name: "Safari", home: home).isEmpty, "never for Apple apps")

print("Duplicates")
let dup = base.appendingPathComponent("dups")
mk("a/one.bin", 20_000, root: dup); mk("b/two.bin", 20_000, root: dup)
try! Data(repeating: 9, count: 20_000).write(to: dup.appendingPathComponent("b/other.bin"))
let groups = Duplicates.scan(root: dup, cancel: { false })
check(groups.count == 1 && groups[0].files.count == 2, "one group of two identical files")
check(groups.first?.files.filter(\.selected).count == 1, "keeps one copy unselected")

print("Large files")
mk("big/huge.mov", 3_000_000, root: base)
let large = LargeOld.scan(root: base.appendingPathComponent("big"), minBytes: 1_000_000, olderThanDays: nil, cancel: { false })
check(large.count == 1 && !large[0].selected, "found, not pre-selected")

print("Space Lens")
let tree = SpaceLens.build(home, cancel: { false }) { _ in }
check(tree.bytes > 0 && !tree.children.isEmpty, "builds a size tree (\(Fmt.bytes(tree.bytes)))")
let rects = Treemap.layout(tree.children.filter { $0.bytes > 0 }, in: CGRect(x: 0, y: 0, width: 800, height: 500))
let area = rects.reduce(0.0) { $0 + Double($1.1.width * $1.1.height) }
check(abs(area - 400_000) < 1, "treemap fills the area")

print("Memory stats")
let m = Stats.memory()
check(m.total > 0 && m.used > 0 && m.used <= m.total, "memory numbers make sense (used \(Fmt.mem(m.used)) of \(Fmt.mem(m.total)), pressure \(m.pressureLabel), swap \(Fmt.mem(m.swapUsed)))")
let sampler = ProcessSampler()
_ = sampler.sample()
let top = sampler.sample().prefix(5)
check(!top.isEmpty, "top memory users: " + top.map { "\($0.name) \(Fmt.mem($0.memory))" }.joined(separator: ", "))

print(failures == 0 ? "\nALL CORE TESTS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
