import Foundation

// MacCleaner helper — runs as root via launchd (see Actions.swift for what it can do).

umask(0o022)
prepareRootDir()
let helper = Helper()
helper.save()
signal(SIGTERM) { _ in exit(0) }
var ticks = 0
while true {
    helper.poll()
    ticks += 1
    if ticks % 5 == 0 { helper.save() }  // heartbeat for the app
    Thread.sleep(forTimeInterval: 1)
}
