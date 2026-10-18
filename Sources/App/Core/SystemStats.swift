import AppKit
import Darwin

// Live numbers for the menu bar and the Memory view. Uses the same counters Activity Monitor uses.

struct MemoryStats: Equatable {
    var total: UInt64 = 0
    var app: UInt64 = 0          // anonymous memory apps own (minus purgeable)
    var wired: UInt64 = 0        // kernel, can't be freed
    var compressed: UInt64 = 0   // squeezed by macOS to avoid swapping
    var cached: UInt64 = 0       // file cache: free to reuse at any moment
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure = 1             // 1 normal, 2 warning, 4 critical (kernel's own level)
    var freePercent = 100        // kernel's "memory free percentage" (what memory_pressure prints)
    var used: UInt64 { app + wired + compressed }

    var pressureLabel: String { pressure >= 4 ? "Critical" : pressure >= 2 ? "Warning" : "Normal" }
}

struct DiskStats: Equatable {
    var total: Int64 = 0
    var available: Int64 = 0
}

enum Stats {
    static let pageSize = UInt64(vm_kernel_page_size)

    static func memory() -> MemoryStats {
        var m = MemoryStats()
        m.total = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let anon = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
            m.app = (anon > purgeable ? anon - purgeable : 0) * pageSize
            m.wired = UInt64(vm.wire_count) * pageSize
            m.compressed = UInt64(vm.compressor_page_count) * pageSize
            m.cached = (UInt64(vm.external_page_count) + purgeable) * pageSize
            m.free = UInt64(vm.free_count) * pageSize
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used; m.swapTotal = swap.xsu_total
        }
        m.pressure = Int(sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
        m.freePercent = Int(sysctlInt("kern.memorystatus_level") ?? 100)
        return m
    }

    static func sysctlInt(_ name: String) -> Int32? {
        var v: Int32 = 0
        var s = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &s, nil, 0) == 0 ? v : nil
    }

    static func disk() -> DiskStats {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DiskStats(total: Int64(v?.volumeTotalCapacity ?? 0), available: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private static var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

    /// Whole-machine CPU use since the previous call, 0…1.
    static func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = (user: info.cpu_ticks.0, sys: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { lastTicks = t }
        guard let l = lastTicks else { return 0 }
        let busy = Double((t.user &- l.user) &+ (t.sys &- l.sys) &+ (t.nice &- l.nice))
        let all = busy + Double(t.idle &- l.idle)
        return all > 0 ? busy / all : 0
    }
}

// MARK: - Processes grouped by app

struct AppUsage: Identifiable, Equatable {
    var id: pid_t { pid }
    var pid: pid_t                // the app (or top process) everything is grouped under
    var name: String
    var bundleID: String?
    var memory: UInt64            // phys_footprint summed over the app and its helpers
    var cpu: Double               // percent of one core
    var processes: Int
    var isApp: Bool               // a regular app you can quit
}

final class ProcessSampler {
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastTime = mach_absolute_time()
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    /// Private libsystem call Activity Monitor relies on: which app is "responsible" for a process
    /// (e.g. Safari for its WebKit content processes). Falls back to the parent chain if missing.
    private let responsible: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(s, to: RespFn.self)
    }()

    func sample() -> [AppUsage] {
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let me = getuid()
        let now = mach_absolute_time()
        let dt = Double(now - lastTime) * timebase  // ns
        lastTime = now

        var parent: [pid_t: pid_t] = [:]
        var names: [pid_t: String] = [:]
        var mem: [pid_t: UInt64] = [:]
        var cpu: [pid_t: Double] = [:]
        var newCPU: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == me else { continue }
            parent[pid] = pid_t(bsd.pbi_ppid)
            names[pid] = withUnsafePointer(to: bsd.pbi_name) { $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) } }
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 {
                mem[pid] = ri.ri_phys_footprint
                let t = ri.ri_user_time + ri.ri_system_time
                newCPU[pid] = t
                if let old = lastCPU[pid], dt > 0, t >= old { cpu[pid] = Double(t - old) * timebase / dt * 100 }
            }
        }
        lastCPU = newCPU

        func owner(_ pid: pid_t) -> pid_t {
            if apps[pid] != nil { return pid }
            if let r = responsible?(pid), r > 0, r != pid, apps[r] != nil { return r }
            var p = pid, hops = 0
            while let pp = parent[p], pp > 1, hops < 16 {
                if apps[pp] != nil { return pp }
                p = pp; hops += 1
            }
            return p
        }

        var groups: [pid_t: AppUsage] = [:]
        for (pid, m) in mem {
            let o = owner(pid)
            let app = apps[o]
            var g = groups[o] ?? AppUsage(pid: o, name: app?.localizedName ?? names[o] ?? "pid \(o)", bundleID: app?.bundleIdentifier,
                                          memory: 0, cpu: 0, processes: 0, isApp: app?.activationPolicy == .regular)
            g.memory += m; g.cpu += cpu[pid] ?? 0; g.processes += 1
            groups[o] = g
        }
        return groups.values.sorted { $0.memory > $1.memory }
    }
}
