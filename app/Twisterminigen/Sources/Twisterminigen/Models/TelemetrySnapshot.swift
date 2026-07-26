import Foundation

/// One sample of live system telemetry. Pure syscalls / IOKit — NO MLX memory reads
/// (reading MLX.Memory from a background sampler races the renderer and can crash on a mutex).
/// The render's memory pressure is reported via `appFootprintBytes` (task phys_footprint) instead.
struct TelemetrySnapshot: Sendable, Equatable {
    var cpuPercent: Double = 0
    var cpuCoreCount: Int = 0
    var appFootprintBytes: Int64 = 0
    var systemUsedBytes: Int64 = 0
    var systemTotalBytes: Int64 = 0
    var gpuName: String = ""
    var gpuCoreCount: Int = 0
    var gpuPercent: Double = 0
    var diskFreeBytes: Int64 = 0
    var diskTotalBytes: Int64 = 0
    var swapUsedBytes: Int64 = 0
    var memoryPressureLevel: Int = 1   // 1 = normal, 2 = warn, 4 = critical
    var thermalState: Int = 0          // 0 nominal · 1 fair · 2 serious · 3 critical
}
