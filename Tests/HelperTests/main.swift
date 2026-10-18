import Foundation

// Tests the helper's descriptor-based deletion in a temp folder (runs as you, not root).

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("maccleaner-helpertest-\(UUID().uuidString)")
defer { try? fm.removeItem(at: base) }
let target = base.appendingPathComponent("target")
let outside = base.appendingPathComponent("outside")
try! fm.createDirectory(at: target.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
try! Data(count: 10_000).write(to: target.appendingPathComponent("a/b/c/f"))
try! Data(count: 10_000).write(to: outside.appendingPathComponent("precious"))
try! fm.createSymbolicLink(at: target.appendingPathComponent("a/link-to-outside"), withDestinationURL: outside)
try! fm.createSymbolicLink(at: target.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("precious"))

print("Helper safe deletion")
let fd = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
var st = stat(); fstat(fd, &st)
let size = entries(of: fd).reduce(Int64(0)) { $0 + measureAt(fd, $1, dev: st.st_dev) }
check(size >= 10_000, "measures the tree (\(size) bytes)")
for name in entries(of: fd) { removeAt(fd, name, dev: st.st_dev) }
check(entries(of: fd).isEmpty, "everything inside removed")
close(fd)
check(fm.fileExists(atPath: outside.appendingPathComponent("precious").path), "file behind a symlink survives")
check(fm.fileExists(atPath: target.path), "the folder itself is kept")
check(openSystemDir(target.path) == nil, "refuses a folder not owned by root")
let link = base.appendingPathComponent("dirlink")
try! fm.createSymbolicLink(at: link, withDestinationURL: outside)
check(open(link.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) < 0, "won't open a linked folder")
check(rotatedLog.firstMatch(in: "system.log.0.gz", range: NSRange(location: 0, length: 15)) != nil &&
      rotatedLog.firstMatch(in: "system.log", range: NSRange(location: 0, length: 10)) == nil, "only rotated logs match")

print(failures == 0 ? "\nALL HELPER TESTS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
