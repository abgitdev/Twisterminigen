import Darwin
import Foundation
import MLX

/// Narrow process-wide boundaries around MLX work that is not part of a long-lived inference task.
///
/// `InferenceCoordinator` is the async admission gate for Generate, Queue, Enhance, Describe,
/// Upscale, and model-file mutations. This lock covers the remaining synchronous safetensors
/// operations. MLX 0.31.1 (embedded by mlx-swift 0.31.6) still dispatches CPU/Metal completion work
/// internally, so callers also drain both default streams before releasing either boundary.
enum MLXRuntimeSafety {
    private static let synchronousOperationLock = NSRecursiveLock()

    static func withExclusiveCPUOperation<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        synchronousOperationLock.lock()
        defer { synchronousOperationLock.unlock() }
        drainCompletions()
        let result = try Device.withDefaultDevice(.cpu, operation)
        drainCompletions()
        return result
    }

    /// Must run on the MLX worker before its `InferenceCoordinator` lease is released.
    static func drainCompletions() {
        Stream.cpu.synchronize()
        Stream.gpu.synchronize()
        MLX.Memory.clearCache()
        // Repeated safetensor/model construction leaves large freed allocations in Darwin malloc
        // zones even after MLX has released every active tensor. Returning those pages here keeps
        // the long-running app footprint bounded without invalidating live allocations.
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}
