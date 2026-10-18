import SwiftUI

struct MonitorPanel: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var helper: HelperClient
    @EnvironmentObject var updater: Updater
    @Environment(\.openWindow) var openWindow
    @State private var note: String?

    var body: some View {
        let m = monitor.mem
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MacCleaner").font(.headline)
                Spacer()
                PressureBadge(m: m).font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Memory").bold()
                    Spacer()
                    Text("\(Fmt.mem(m.used)) of \(Fmt.mem(m.total))").monospacedDigit().foregroundStyle(.secondary)
                }
                MemoryBar(m: m).font(.caption2)
            }
            HStack(spacing: 10) {
                Stat(title: "Swap", value: Fmt.mem(m.swapUsed), warn: m.swapUsed > 2 << 30)
                Stat(title: "CPU", value: String(format: "%.0f%%", monitor.cpu * 100), warn: monitor.cpu > 0.8)
                Stat(title: "Disk free", value: Fmt.bytes(monitor.disk.available), warn: monitor.disk.available < 20_000_000_000)
            }
            Divider()
            Text("Using the most memory").font(.caption).foregroundStyle(.secondary)
            AppUsageList(limit: 6, compact: true)
            Divider()
            HStack {
                Button(helper.busy == .purgeRAM ? "Working…" : "Free up RAM") {
                    let before = monitor.mem.cached
                    helper.run(.purgeRAM) { r in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            monitor.refresh()
                            let d = Int64(before) - Int64(monitor.mem.cached)
                            note = r.ok ? "Released \(Fmt.mem(UInt64(max(0, d)))) of file cache. Quit a big app above to free more." : r.message
                        }
                    }
                }
                .disabled(helper.busy != nil)
                Spacer()
                Button("Open MacCleaner") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if case .available = updater.state {
                Button("Update available — install") { updater.update() }.font(.caption)
            }
            HStack {
                Spacer()
                Button("Quit MacCleaner") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct Stat: View {
    let title: String, value: String
    var warn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit().bold().foregroundStyle(warn ? .orange : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
