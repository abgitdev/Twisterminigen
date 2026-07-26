import SwiftUI
import Observation
import Darwin
import Metal
import IOKit

/// Samples live CPU / GPU / RAM / disk telemetry on a ~1.5s loop. Owned once at app level and
/// kept running while the window is open, so both the bottom status bar and the Generation
/// telemetry rail always show fresh, real data. Keeps short history rings for sparklines.
///
/// The recurring sampling (mach/sysctl syscalls + an IOKit IOAccelerator registry walk) runs
/// off the main actor in a detached task; only the @Observable writes hop back to MainActor.
///
/// IMPORTANT: this sampler NEVER reads MLX.Memory. Reading the MLX allocator's counters from a
/// background loop races the renderer and can crash on the allocator mutex — the render's memory
/// pressure is reported via the app's phys_footprint (`footprintGB()`) instead.
@MainActor
@Observable
final class TelemetryService {
    var snapshot = TelemetrySnapshot()

    /// App launch time — drives the System screen's live uptime readout.
    let launched = Date()
    /// Session peak of the app's memory footprint (MLX card "peak").
    private(set) var appMemPeakBytes: Int64 = 0

    // Sparkline history (newest appended last), capped at `historyLen`.
    private(set) var cpuHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private let historyLen = 48

    /// Red status-bar chip text while swap / free disk crosses the danger line, nil when healthy.
    /// Hysteresis (danger ≠ safe thresholds) so the chip doesn't flicker at the boundary.
    private(set) var healthWarning: String?
    private(set) var memoryHealthLevel: MemoryGovernor.Level = .green

    private var prevTicks: CPUTicks?
    private let gpuName: String = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"
    private let gpuCores: Int = TelemetryService.readGPUCoreCount()
    private var running = false

    /// Snapshot of the four CPU tick counters — Sendable so it can cross into a detached task.
    struct CPUTicks: Sendable {
        var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0
    }

    /// Idempotent — safe to call from multiple `.task`s.
    func start() {
        guard !running else { return }
        running = true
        // Warm-up sample runs synchronously so `snapshot` is populated before the first paint.
        // CPU% needs a prior tick reading, so this first sample's CPU is 0 — we deliberately do
        // NOT push it into the history rings (it would seed the sparkline with a bogus flat 0).
        let (s, t) = TelemetryService.collect(prev: nil, fallbackCPU: 0, fallbackGPU: 0,
                                              gpuName: gpuName, gpuCores: gpuCores)
        prevTicks = t
        snapshot = s
        appMemPeakBytes = s.appFootprintBytes

        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                let prev = self.prevTicks
                let fc = self.snapshot.cpuPercent
                let fg = self.snapshot.gpuPercent
                let name = self.gpuName
                let cores = self.gpuCores
                let (snap, ticks) = await Task.detached {
                    TelemetryService.collect(prev: prev, fallbackCPU: fc, fallbackGPU: fg,
                                             gpuName: name, gpuCores: cores)
                }.value
                self.prevTicks = ticks
                self.snapshot = snap
                self.pushHistory(snap)
                self.updateHealthWarning(snap)
            }
        }
    }

    /// Warn as soon as swap reaches the governor's amber band, well before it becomes unsafe.
    private func updateHealthWarning(_ s: TelemetrySnapshot) {
        let swapGB = Double(s.swapUsedBytes) / Double(SystemRAM.bytesPerGiB)
        let diskGB = Double(s.diskFreeBytes) / Double(SystemRAM.bytesPerGiB)
        let status = MemoryGovernor.status(for: .init(
            swapUsedBytes: s.swapUsedBytes,
            systemPressureLevel: s.memoryPressureLevel))
        memoryHealthLevel = status.level
        if diskGB < 5 {
            healthWarning = "disk \(String(format: "%.1f", diskGB)) GB free"
        } else if status.level != .green {
            let label = status.level == .red ? "memory red" : "memory amber"
            healthWarning = "\(label) · swap \(String(format: "%.1f", swapGB)) GB"
        } else {
            healthWarning = nil
        }
    }

    private func pushHistory(_ s: TelemetrySnapshot) {
        if s.appFootprintBytes > appMemPeakBytes { appMemPeakBytes = s.appFootprintBytes }
        push(&cpuHistory, s.cpuPercent)
        push(&gpuHistory, s.gpuPercent)
    }

    private func push(_ buf: inout [Double], _ value: Double) {
        if buf.isEmpty { buf = Array(repeating: value, count: 8); return }   // seed exactly N for a clean first paint
        buf.append(value)
        if buf.count > historyLen { buf.removeFirst(buf.count - historyLen) }
    }

    // MARK: Off-main collection (pure syscalls / IOKit — no actor state, no MLX)

    nonisolated static func collect(prev: CPUTicks?, fallbackCPU: Double, fallbackGPU: Double,
                                    gpuName: String, gpuCores: Int) -> (TelemetrySnapshot, CPUTicks) {
        var s = TelemetrySnapshot()
        let (cpu, ticks) = sampleCPU(prev: prev, fallback: fallbackCPU)
        s.cpuPercent = cpu
        s.cpuCoreCount = ProcessInfo.processInfo.processorCount
        s.appFootprintBytes = appFootprint()
        let (used, total) = systemMemory()
        s.systemUsedBytes = used
        s.systemTotalBytes = total
        s.gpuName = gpuName
        s.gpuCoreCount = gpuCores
        s.gpuPercent = sampleGPU(fallback: fallbackGPU)
        let (free, dtotal) = diskSpace()
        s.diskFreeBytes = free
        s.diskTotalBytes = dtotal
        s.swapUsedBytes = swapUsed()
        s.memoryPressureLevel = memoryPressureLevel()
        s.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        return (s, ticks)
    }

    private nonisolated static func sampleCPU(prev: CPUTicks?, fallback: Double) -> (Double, CPUTicks) {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (fallback, prev ?? CPUTicks()) }
        let cur = CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                           idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        guard let prev else { return (0, cur) }
        let user = Double(cur.user) - Double(prev.user)
        let system = Double(cur.system) - Double(prev.system)
        let idle = Double(cur.idle) - Double(prev.idle)
        let nice = Double(cur.nice) - Double(prev.nice)
        let totalTicks = user + system + idle + nice
        guard totalTicks > 0 else { return (fallback, cur) }
        return (max(0, min(100, (user + system + nice) / totalTicks * 100)), cur)
    }

    /// Public snapshot of the app's REAL memory footprint in GB (phys_footprint — what Activity
    /// Monitor shows; ps-rss undercounts Metal unified memory). Used for per-render peak-RAM
    /// telemetry; same source as the status-bar readout so the numbers agree.
    nonisolated static func footprintGB() -> Double { Double(appFootprint()) / Double(SystemRAM.bytesPerGiB) }

    /// One synchronous OS-only sample for inference admission and hard-stop checks.
    nonisolated static func memoryGovernorSnapshot() -> MemoryGovernor.OSSnapshot {
        .init(swapUsedBytes: swapUsed(), systemPressureLevel: memoryPressureLevel())
    }

    /// OS-only render sample. Safe to poll beside MLX because it uses task_info/sysctl only.
    nonisolated static func renderMemorySample() -> RenderMemoryMonitor.OSSample {
        .init(
            processPhysicalFootprintBytes: appFootprint(),
            swapUsedBytes: swapUsed(),
            pressure: .init(systemLevel: memoryPressureLevel()),
            thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }

    private nonisolated static func appFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private nonisolated static func systemMemory() -> (used: Int64, total: Int64) {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = Int64(sysconf(_SC_PAGESIZE))
        let used = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        return (used, total)
    }

    private nonisolated static func diskSpace() -> (free: Int64, total: Int64) {
        // Plain statfs-level key (the "ForImportantUsage" variant makes an XPC round-trip to the
        // CacheDelete daemon every tick — irrelevant for a status-bar readout).
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        ) else { return (0, 0) }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let total = Int64(v.volumeTotalCapacity ?? 0)
        return (free, total)
    }

    private nonisolated static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let r = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return r == 0 ? Int64(usage.xsu_used) : 0
    }

    private nonisolated static func memoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let r = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return r == 0 ? Int(level) : 1
    }

    // MARK: IOKit GPU

    /// Real GPU busy % from IOAccelerator's PerformanceStatistics (no sudo, no private framework).
    private nonisolated static func sampleGPU(fallback: Double) -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return fallback
        }
        defer { IOObjectRelease(iterator) }
        var result = -1.0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                if let util = props["Device Utilization %"] as? Int { result = Double(util) }
                else if let util = props["GPU Activity(%)"] as? Int { result = Double(util) }
            }
            IOObjectRelease(service)
            if result >= 0 { break }
            service = IOIteratorNext(iterator)
        }
        return result >= 0 ? max(0, min(100, result)) : fallback
    }

    /// Best-effort GPU core count from the IO registry; 0 if unavailable.
    private static func readGPUCoreCount() -> Int {
        for matchName in ["AGXAccelerator", "IOGPU"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(matchName), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            var svc = IOIteratorNext(it)
            while svc != 0 {
                let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                if let n = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "gpu-core-count" as CFString, kCFAllocatorDefault, opts) as? Int {
                    IOObjectRelease(svc)
                    return n
                }
                IOObjectRelease(svc)
                svc = IOIteratorNext(it)
            }
        }
        return 0
    }
}
