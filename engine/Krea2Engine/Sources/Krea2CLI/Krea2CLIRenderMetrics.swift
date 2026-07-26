import Darwin
import Foundation
import Krea2Core

struct Krea2CLIRenderMetrics: Codable, Sendable {
    let schema: String
    let version: Int
    let checkpoint: String
    let quantization: String
    let transformerRevision: String
    let transformerSHA256: String
    let prompt: String
    let width: Int
    let height: Int
    let steps: Int
    let seed: UInt64
    let seconds: Double
    let imageSHA256: String
    let processBaselineBytes: Int64
    let processPeakBytes: Int64
    let processFinalBytes: Int64
    let mlxPeakBytes: Int64
    let mlxActiveBytes: Int64
    let mlxCacheBytes: Int64
    let swapBaselineBytes: Int64
    let swapPeakBytes: Int64
    let swapFinalBytes: Int64
    let swapIncreaseBytes: Int64
    let memoryPressureWorst: Int
    let thermalBaseline: Int
    let thermalWorst: Int
    let thermalFinal: Int

    static func write(_ value: Self, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// OS-only poller for reproducible CLI gates. It never touches MLX from its background task.
final class Krea2CLIOSMonitor: @unchecked Sendable {
    struct Report: Sendable {
        let processBaselineBytes: Int64
        let processPeakBytes: Int64
        let processFinalBytes: Int64
        let swapBaselineBytes: Int64
        let swapPeakBytes: Int64
        let swapFinalBytes: Int64
        let memoryPressureWorst: Int
        let thermalBaseline: Int
        let thermalWorst: Int
        let thermalFinal: Int

        var swapIncreaseBytes: Int64 { max(0, swapPeakBytes - swapBaselineBytes) }
    }

    private struct Sample {
        let processBytes: Int64
        let swapBytes: Int64
        let pressure: Int
        let thermal: Int
    }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var baseline: Sample?
    private var peak: Sample?
    private var final: Sample?

    func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        let first = Self.sample()
        baseline = first
        peak = first
        final = first
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.record(Self.sample())
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
        lock.unlock()
    }

    func stop() async -> Report {
        record(Self.sample())
        let polling = lock.withLock {
            let polling = task
            task = nil
            return polling
        }
        polling?.cancel()
        if let polling { await polling.value }

        let values = lock.withLock { () -> (Sample, Sample, Sample) in
            let first = self.baseline ?? Self.sample()
            return (first, self.peak ?? first, self.final ?? first)
        }
        let (baseline, peak, final) = values
        return Report(
            processBaselineBytes: baseline.processBytes,
            processPeakBytes: peak.processBytes,
            processFinalBytes: final.processBytes,
            swapBaselineBytes: baseline.swapBytes,
            swapPeakBytes: peak.swapBytes,
            swapFinalBytes: final.swapBytes,
            memoryPressureWorst: peak.pressure,
            thermalBaseline: baseline.thermal,
            thermalWorst: peak.thermal,
            thermalFinal: final.thermal)
    }

    private func record(_ sample: Sample) {
        lock.lock()
        defer { lock.unlock() }
        guard var peak else { return }
        peak = Sample(
            processBytes: max(peak.processBytes, sample.processBytes),
            swapBytes: max(peak.swapBytes, sample.swapBytes),
            pressure: max(peak.pressure, sample.pressure),
            thermal: max(peak.thermal, sample.thermal))
        self.peak = peak
        final = sample
    }

    private static func sample() -> Sample {
        let memory = Krea2MemorySampler.captureProcess()
        return Sample(
            processBytes: memory.footprintBytes,
            swapBytes: memory.swapUsedBytes,
            pressure: memoryPressureLevel(),
            thermal: min(3, max(0, ProcessInfo.processInfo.thermalState.rawValue)))
    }

    private static func memoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return result == 0 ? Int(level) : 1
    }
}
