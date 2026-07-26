import CryptoKit
import Darwin
import Foundation
import MLX

// MARK: - Stable digests

public enum Krea2StableDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(utf8 string: String) -> String {
        sha256(Data(string.utf8))
    }
}

public enum Krea2PixelDigestError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case invalidByteCount(expected: Int, actual: Int)
}

/// A cross-run digest of clamped, truncated RGB8 pixels in row-major HWC order.
public struct Krea2CanonicalPixelDigest: Codable, Equatable, Sendable {
    public static let algorithm = "sha256"
    public static let pixelFormat = "rgb8-hwc-clamped-truncate-v1"

    public var algorithm: String
    public var pixelFormat: String
    public var value: String

    public init(
        algorithm: String = Self.algorithm,
        pixelFormat: String = Self.pixelFormat,
        value: String
    ) {
        self.algorithm = algorithm
        self.pixelFormat = pixelFormat
        self.value = value
    }

    public static func make(width: Int, height: Int, rgb8: [UInt8]) throws -> Self {
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max) else {
            throw Krea2PixelDigestError.invalidDimensions(width: width, height: height)
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (expectedCount, channelOverflow) = pixelCount.multipliedReportingOverflow(by: 3)
        guard !pixelOverflow, !channelOverflow else {
            throw Krea2PixelDigestError.invalidDimensions(width: width, height: height)
        }
        guard rgb8.count == expectedCount else {
            throw Krea2PixelDigestError.invalidByteCount(expected: expectedCount, actual: rgb8.count)
        }

        var canonical = Data("KREA2-PIXEL-DIGEST\0".utf8)
        canonical.append(Data(Self.pixelFormat.utf8))
        canonical.append(0)
        var littleWidth = UInt32(width).littleEndian
        var littleHeight = UInt32(height).littleEndian
        withUnsafeBytes(of: &littleWidth) { canonical.append(contentsOf: $0) }
        withUnsafeBytes(of: &littleHeight) { canonical.append(contentsOf: $0) }
        canonical.append(contentsOf: rgb8)
        return Self(value: Krea2StableDigest.sha256(canonical))
    }
}

// MARK: - Memory values and sampling

public struct Krea2MLXMemorySnapshot: Codable, Equatable, Sendable {
    public var activeBytes: Int64
    public var cacheBytes: Int64
    public var peakBytes: Int64

    public init(activeBytes: Int64, cacheBytes: Int64, peakBytes: Int64) {
        self.activeBytes = activeBytes
        self.cacheBytes = cacheBytes
        self.peakBytes = peakBytes
    }

    public static let zero = Self(activeBytes: 0, cacheBytes: 0, peakBytes: 0)
}

public struct Krea2ProcessMemorySnapshot: Codable, Equatable, Sendable {
    public var footprintBytes: Int64
    public var swapUsedBytes: Int64

    public init(footprintBytes: Int64, swapUsedBytes: Int64) {
        self.footprintBytes = footprintBytes
        self.swapUsedBytes = swapUsedBytes
    }

    public static let zero = Self(footprintBytes: 0, swapUsedBytes: 0)
}

public struct Krea2MemorySnapshot: Codable, Equatable, Sendable {
    public var mlx: Krea2MLXMemorySnapshot
    public var process: Krea2ProcessMemorySnapshot

    public init(mlx: Krea2MLXMemorySnapshot, process: Krea2ProcessMemorySnapshot) {
        self.mlx = mlx
        self.process = process
    }
}

public enum Krea2MemorySampler {
    /// MLX counters must be captured synchronously on the inference path. The background monitor
    /// below intentionally calls only `captureProcess()`.
    public static func capturePhase() -> Krea2MemorySnapshot {
        let mlx = MLX.Memory.snapshot()
        return Krea2MemorySnapshot(
            mlx: Krea2MLXMemorySnapshot(
                activeBytes: Int64(mlx.activeMemory),
                cacheBytes: Int64(mlx.cacheMemory),
                peakBytes: Int64(mlx.peakMemory)),
            process: captureProcess())
    }

    /// Uses only task_info and sysctl, so it is safe for the OS-only polling task.
    public static func captureProcess() -> Krea2ProcessMemorySnapshot {
        Krea2ProcessMemorySnapshot(
            footprintBytes: max(0, processFootprint()),
            swapUsedBytes: max(0, swapUsed()))
    }

    private static func processFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return result == 0 ? Int64(usage.xsu_used) : 0
    }
}

public struct Krea2ProcessMemorySummary: Codable, Equatable, Sendable {
    public var processBaselineBytes: Int64
    public var processPeakBytes: Int64
    public var processFinalBytes: Int64
    public var swapBaselineBytes: Int64
    public var swapPeakBytes: Int64
    public var swapDeltaBytes: Int64

    public init(
        processBaselineBytes: Int64,
        processPeakBytes: Int64,
        processFinalBytes: Int64,
        swapBaselineBytes: Int64,
        swapPeakBytes: Int64,
        swapDeltaBytes: Int64
    ) {
        self.processBaselineBytes = processBaselineBytes
        self.processPeakBytes = processPeakBytes
        self.processFinalBytes = processFinalBytes
        self.swapBaselineBytes = swapBaselineBytes
        self.swapPeakBytes = swapPeakBytes
        self.swapDeltaBytes = swapDeltaBytes
    }

    public static let zero = Self(
        processBaselineBytes: 0,
        processPeakBytes: 0,
        processFinalBytes: 0,
        swapBaselineBytes: 0,
        swapPeakBytes: 0,
        swapDeltaBytes: 0)
}

/// Polls process footprint and system swap only. It never reads MLX state from its detached task.
public final class Krea2ProcessMemoryMonitor: @unchecked Sendable {
    private let pollInterval: Duration
    private let state = State()

    public init(pollInterval: Duration = .milliseconds(100)) {
        self.pollInterval = pollInterval > .zero ? pollInterval : .milliseconds(1)
    }

    deinit {
        state.cancel()
    }

    public func start() {
        let initial = Krea2MemorySampler.captureProcess()
        let state = state
        let interval = pollInterval
        state.start(initial: initial) {
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    state.record(Krea2MemorySampler.captureProcess())
                }
            }
        }
    }

    public func stop() async -> Krea2ProcessMemorySummary {
        let final = Krea2MemorySampler.captureProcess()
        let task = state.stop(final: final)
        task?.cancel()
        if let task {
            await task.value
        }
        return state.summary()
    }

    private final class State: @unchecked Sendable {
        private enum Lifecycle {
            case idle
            case running
            case stopped
        }

        private let lock = NSLock()
        private var lifecycle = Lifecycle.idle
        private var task: Task<Void, Never>?
        private var baseline = Krea2ProcessMemorySnapshot.zero
        private var peak = Krea2ProcessMemorySnapshot.zero
        private var final = Krea2ProcessMemorySnapshot.zero

        func start(initial: Krea2ProcessMemorySnapshot, makeTask: () -> Task<Void, Never>) {
            withLock {
                guard lifecycle == .idle else { return }
                lifecycle = .running
                baseline = initial
                peak = initial
                final = initial
                task = makeTask()
            }
        }

        func record(_ sample: Krea2ProcessMemorySnapshot) {
            withLock {
                guard lifecycle == .running else { return }
                peak.footprintBytes = max(peak.footprintBytes, sample.footprintBytes)
                peak.swapUsedBytes = max(peak.swapUsedBytes, sample.swapUsedBytes)
                final = sample
            }
        }

        func stop(final sample: Krea2ProcessMemorySnapshot) -> Task<Void, Never>? {
            withLock {
                if lifecycle == .running {
                    peak.footprintBytes = max(peak.footprintBytes, sample.footprintBytes)
                    peak.swapUsedBytes = max(peak.swapUsedBytes, sample.swapUsedBytes)
                    final = sample
                    lifecycle = .stopped
                } else if lifecycle == .idle {
                    lifecycle = .stopped
                }
                return task
            }
        }

        func summary() -> Krea2ProcessMemorySummary {
            withLock {
                Krea2ProcessMemorySummary(
                    processBaselineBytes: baseline.footprintBytes,
                    processPeakBytes: peak.footprintBytes,
                    processFinalBytes: final.footprintBytes,
                    swapBaselineBytes: baseline.swapUsedBytes,
                    swapPeakBytes: peak.swapUsedBytes,
                    swapDeltaBytes: max(0, peak.swapUsedBytes - baseline.swapUsedBytes))
            }
        }

        func cancel() {
            withLock { task }?.cancel()
        }

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }
}

// MARK: - Trace values

public struct Krea2PerformanceSpan: Codable, Equatable, Sendable {
    public var runID: String
    public var sequence: Int
    public var parentSequence: Int?
    public var name: String
    public var startedNanoseconds: Int64
    public var durationNanoseconds: Int64

    public init(
        runID: String,
        sequence: Int,
        parentSequence: Int?,
        name: String,
        startedNanoseconds: Int64,
        durationNanoseconds: Int64
    ) {
        self.runID = runID
        self.sequence = sequence
        self.parentSequence = parentSequence
        self.name = name
        self.startedNanoseconds = startedNanoseconds
        self.durationNanoseconds = durationNanoseconds
    }
}

public struct Krea2StepDuration: Codable, Equatable, Sendable {
    public var runID: String
    public var phase: String
    public var stepIndex: Int
    public var totalSteps: Int
    public var startedNanoseconds: Int64
    public var durationNanoseconds: Int64

    public init(
        runID: String,
        phase: String,
        stepIndex: Int,
        totalSteps: Int,
        startedNanoseconds: Int64,
        durationNanoseconds: Int64
    ) {
        self.runID = runID
        self.phase = phase
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.startedNanoseconds = startedNanoseconds
        self.durationNanoseconds = durationNanoseconds
    }
}

public enum Krea2MemorySampleKind: String, Codable, Equatable, Sendable {
    case baseline
    case phase
    case final
}

public struct Krea2PhaseMemorySample: Codable, Equatable, Sendable {
    public var runID: String
    public var sequence: Int
    public var phase: String
    public var kind: Krea2MemorySampleKind
    public var elapsedNanoseconds: Int64
    public var memory: Krea2MemorySnapshot

    public init(
        runID: String,
        sequence: Int,
        phase: String,
        kind: Krea2MemorySampleKind,
        elapsedNanoseconds: Int64,
        memory: Krea2MemorySnapshot
    ) {
        self.runID = runID
        self.sequence = sequence
        self.phase = phase
        self.kind = kind
        self.elapsedNanoseconds = elapsedNanoseconds
        self.memory = memory
    }
}

public struct Krea2TraceSnapshot: Codable, Equatable, Sendable {
    public var spans: [Krea2PerformanceSpan]
    public var stepDurations: [Krea2StepDuration]
    public var memorySamples: [Krea2PhaseMemorySample]

    public init(
        spans: [Krea2PerformanceSpan],
        stepDurations: [Krea2StepDuration],
        memorySamples: [Krea2PhaseMemorySample]
    ) {
        self.spans = spans
        self.stepDurations = stepDurations
        self.memorySamples = memorySamples
    }
}

public typealias Krea2TraceNowProvider = @Sendable () -> Duration

/// A lock-protected recorder so synchronous pipeline callbacks can share one monotonic trace.
public final class Krea2PerformanceTrace: @unchecked Sendable {
    public struct SpanToken: Hashable, Sendable {
        public let sequence: Int
        fileprivate let traceID: UUID

        fileprivate init(sequence: Int, traceID: UUID) {
            self.sequence = sequence
            self.traceID = traceID
        }
    }

    private struct ActiveSpan {
        var sequence: Int
        var parentSequence: Int?
        var name: String
        var startedNanoseconds: Int64
    }

    private struct ActiveStepSequence {
        var phase: String
        var totalSteps: Int
        var lastStepIndex: Int
        var startedNanoseconds: Int64
    }

    private let runID: String
    private let traceID = UUID()
    private let now: Krea2TraceNowProvider
    private let lock = NSLock()
    private var nextSpanSequence = 0
    private var activeSpans: [Int: ActiveSpan] = [:]
    private var sequentialSpans: [String: Int] = [:]
    private var stepSequences: [String: ActiveStepSequence] = [:]
    private var completedSpans: [Krea2PerformanceSpan] = []
    private var completedSteps: [Krea2StepDuration] = []
    private var memorySamples: [Krea2PhaseMemorySample] = []

    public init(runID: String) {
        self.runID = runID
        let clock = ContinuousClock()
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
    }

    public init(runID: String, now: @escaping Krea2TraceNowProvider) {
        self.runID = runID
        self.now = now
    }

    @discardableResult
    public func beginSpan(_ name: String, parent: SpanToken? = nil) -> SpanToken {
        let timestamp = timestampNanoseconds()
        return withLock {
            let sequence = nextSpanSequence
            nextSpanSequence += 1
            activeSpans[sequence] = ActiveSpan(
                sequence: sequence,
                parentSequence: parent.flatMap {
                    $0.traceID == traceID ? $0.sequence : nil
                },
                name: name,
                startedNanoseconds: timestamp)
            return SpanToken(sequence: sequence, traceID: traceID)
        }
    }

    @discardableResult
    public func endSpan(_ token: SpanToken) -> Krea2PerformanceSpan? {
        let timestamp = timestampNanoseconds()
        return withLock {
            guard token.traceID == traceID else { return nil }
            sequentialSpans = sequentialSpans.filter { $0.value != token.sequence }
            return closeSpan(sequence: token.sequence, at: timestamp)
        }
    }

    /// Closes the prior span in `lane` and starts the next one at the same clock instant.
    @discardableResult
    public func transition(
        to name: String,
        in lane: String = "default",
        parent: SpanToken? = nil
    ) -> SpanToken {
        let timestamp = timestampNanoseconds()
        return withLock {
            if let previous = sequentialSpans[lane] {
                _ = closeSpan(sequence: previous, at: timestamp)
            }
            let sequence = nextSpanSequence
            nextSpanSequence += 1
            activeSpans[sequence] = ActiveSpan(
                sequence: sequence,
                parentSequence: parent.flatMap {
                    $0.traceID == traceID ? $0.sequence : nil
                },
                name: name,
                startedNanoseconds: timestamp)
            sequentialSpans[lane] = sequence
            return SpanToken(sequence: sequence, traceID: traceID)
        }
    }

    @discardableResult
    public func finishSequence(in lane: String = "default") -> Krea2PerformanceSpan? {
        let timestamp = timestampNanoseconds()
        return withLock {
            guard let sequence = sequentialSpans.removeValue(forKey: lane) else { return nil }
            return closeSpan(sequence: sequence, at: timestamp)
        }
    }

    public func beginStepSequence(
        phase: String,
        totalSteps: Int,
        in lane: String = "steps"
    ) {
        let timestamp = timestampNanoseconds()
        withLock {
            guard totalSteps > 0 else {
                stepSequences.removeValue(forKey: lane)
                return
            }
            stepSequences[lane] = ActiveStepSequence(
                phase: phase,
                totalSteps: totalSteps,
                lastStepIndex: 0,
                startedNanoseconds: timestamp)
        }
    }

    @discardableResult
    public func completeStep(
        _ stepIndex: Int,
        totalSteps: Int,
        in lane: String = "steps"
    ) -> Krea2StepDuration? {
        let timestamp = timestampNanoseconds()
        return withLock {
            guard var active = stepSequences[lane],
                  totalSteps == active.totalSteps,
                  stepIndex > active.lastStepIndex,
                  stepIndex <= totalSteps
            else {
                return nil
            }
            let duration = max(0, timestamp - active.startedNanoseconds)
            let record = Krea2StepDuration(
                runID: runID,
                phase: active.phase,
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                startedNanoseconds: active.startedNanoseconds,
                durationNanoseconds: duration)
            completedSteps.append(record)
            active.lastStepIndex = stepIndex
            active.startedNanoseconds = timestamp
            stepSequences[lane] = active
            return record
        }
    }

    public func recordMemory(
        phase: String,
        kind: Krea2MemorySampleKind = .phase,
        memory: Krea2MemorySnapshot
    ) {
        let timestamp = timestampNanoseconds()
        withLock {
            memorySamples.append(Krea2PhaseMemorySample(
                runID: runID,
                sequence: memorySamples.count,
                phase: phase,
                kind: kind,
                elapsedNanoseconds: timestamp,
                memory: memory))
        }
    }

    public func snapshot() -> Krea2TraceSnapshot {
        withLock {
            Krea2TraceSnapshot(
                spans: completedSpans.sorted(by: Self.spanOrder),
                stepDurations: completedSteps.sorted(by: Self.stepOrder),
                memorySamples: memorySamples.sorted(by: Self.memoryOrder))
        }
    }

    private func closeSpan(sequence: Int, at timestamp: Int64) -> Krea2PerformanceSpan? {
        guard let active = activeSpans.removeValue(forKey: sequence) else { return nil }
        let span = Krea2PerformanceSpan(
            runID: runID,
            sequence: active.sequence,
            parentSequence: active.parentSequence,
            name: active.name,
            startedNanoseconds: active.startedNanoseconds,
            durationNanoseconds: max(0, timestamp - active.startedNanoseconds))
        completedSpans.append(span)
        return span
    }

    private func timestampNanoseconds() -> Int64 {
        max(0, Self.nanoseconds(now()))
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let (wholeNanoseconds, productOverflow) = components.seconds.multipliedReportingOverflow(
            by: 1_000_000_000)
        if productOverflow {
            return components.seconds >= 0 ? Int64.max : Int64.min
        }
        let fractionalNanoseconds = components.attoseconds / 1_000_000_000
        let (result, sumOverflow) = wholeNanoseconds.addingReportingOverflow(fractionalNanoseconds)
        if sumOverflow {
            return wholeNanoseconds >= 0 ? Int64.max : Int64.min
        }
        return result
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func spanOrder(_ lhs: Krea2PerformanceSpan, _ rhs: Krea2PerformanceSpan) -> Bool {
        if lhs.startedNanoseconds != rhs.startedNanoseconds {
            return lhs.startedNanoseconds < rhs.startedNanoseconds
        }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.name < rhs.name
    }

    private static func stepOrder(_ lhs: Krea2StepDuration, _ rhs: Krea2StepDuration) -> Bool {
        if lhs.startedNanoseconds != rhs.startedNanoseconds {
            return lhs.startedNanoseconds < rhs.startedNanoseconds
        }
        if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
        if lhs.stepIndex != rhs.stepIndex { return lhs.stepIndex < rhs.stepIndex }
        return lhs.totalSteps < rhs.totalSteps
    }

    private static func memoryOrder(
        _ lhs: Krea2PhaseMemorySample,
        _ rhs: Krea2PhaseMemorySample
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.elapsedNanoseconds != rhs.elapsedNanoseconds {
            return lhs.elapsedNanoseconds < rhs.elapsedNanoseconds
        }
        return lhs.phase < rhs.phase
    }
}

// MARK: - Versioned report

public struct Krea2BenchmarkEnvironment: Codable, Equatable, Sendable {
    public var operatingSystem: String
    public var architecture: String
    public var hardwareModel: String
    public var processorCount: Int
    public var physicalMemoryBytes: UInt64
    public var engineRevision: String
    public var mlxVersion: String

    public init(
        operatingSystem: String,
        architecture: String,
        hardwareModel: String,
        processorCount: Int,
        physicalMemoryBytes: UInt64,
        engineRevision: String,
        mlxVersion: String
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.processorCount = processorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.engineRevision = engineRevision
        self.mlxVersion = mlxVersion
    }

    public static func current(engineRevision: String, mlxVersion: String) -> Self {
        let process = ProcessInfo.processInfo
        return Self(
            operatingSystem: process.operatingSystemVersionString,
            architecture: currentArchitecture,
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            processorCount: process.processorCount,
            physicalMemoryBytes: process.physicalMemory,
            engineRevision: engineRevision,
            mlxVersion: mlxVersion)
    }

    /// Engine revisions are expected to differ when an optimization is compared with a baseline.
    fileprivate func hasSameBenchmarkHost(as other: Self) -> Bool {
        operatingSystem == other.operatingSystem
            && architecture == other.architecture
            && hardwareModel == other.hardwareModel
            && processorCount == other.processorCount
            && physicalMemoryBytes == other.physicalMemoryBytes
            && mlxVersion == other.mlxVersion
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }
}

public struct Krea2BenchmarkModelIdentity: Codable, Equatable, Sendable {
    public var family: String
    public var checkpoint: String
    public var revision: String
    public var quantization: String
    public var artifactName: String
    public var artifactDigest: String?

    public init(
        family: String,
        checkpoint: String,
        revision: String,
        quantization: String,
        artifactName: String,
        artifactDigest: String? = nil
    ) {
        self.family = family
        self.checkpoint = checkpoint
        self.revision = revision
        self.quantization = quantization
        self.artifactName = artifactName
        self.artifactDigest = artifactDigest
    }
}

public enum Krea2FilesystemCacheState: String, Codable, Equatable, Sendable {
    /// No attempt was made to evict or characterize the operating system's file cache.
    case uncontrolled
    case processWarm
}

public enum Krea2BenchmarkExecutionMode: String, Codable, Equatable, Sendable {
    case single
    case sequential
}

public struct Krea2BenchmarkRunIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var ordinal: Int
    public var benchmarkCase: String
    public var promptKind: String
    public var prompt: String
    public var promptDigest: String
    public var seed: UInt64
    public var width: Int
    public var height: Int
    public var steps: Int
    public var workloadSize: Int
    public var queueDepth: Int
    public var executionMode: Krea2BenchmarkExecutionMode
    public var filesystemCacheState: Krea2FilesystemCacheState

    public init(
        id: String,
        ordinal: Int,
        benchmarkCase: String,
        promptKind: String,
        prompt: String,
        promptDigest: String,
        seed: UInt64,
        width: Int,
        height: Int,
        steps: Int,
        workloadSize: Int,
        queueDepth: Int,
        executionMode: Krea2BenchmarkExecutionMode,
        filesystemCacheState: Krea2FilesystemCacheState
    ) {
        self.id = id
        self.ordinal = ordinal
        self.benchmarkCase = benchmarkCase
        self.promptKind = promptKind
        self.prompt = prompt
        self.promptDigest = promptDigest
        self.seed = seed
        self.width = width
        self.height = height
        self.steps = steps
        self.workloadSize = workloadSize
        self.queueDepth = queueDepth
        self.executionMode = executionMode
        self.filesystemCacheState = filesystemCacheState
    }

    fileprivate func hasSameBaselineConfiguration(as other: Self) -> Bool {
        ordinal == other.ordinal
            && benchmarkCase == other.benchmarkCase
            && promptKind == other.promptKind
            && prompt == other.prompt
            && promptDigest == other.promptDigest
            && seed == other.seed
            && width == other.width
            && height == other.height
            && steps == other.steps
            && workloadSize == other.workloadSize
            && queueDepth == other.queueDepth
            && executionMode == other.executionMode
            && filesystemCacheState == other.filesystemCacheState
    }
}

public struct Krea2MemorySummary: Codable, Equatable, Sendable {
    public var mlxActiveBytes: Int64
    public var mlxCacheBytes: Int64
    public var mlxPeakBytes: Int64
    public var processBaselineBytes: Int64
    public var processPeakBytes: Int64
    public var processFinalBytes: Int64
    public var swapBaselineBytes: Int64
    public var swapPeakBytes: Int64
    public var swapDeltaBytes: Int64

    public init(
        mlxActiveBytes: Int64,
        mlxCacheBytes: Int64,
        mlxPeakBytes: Int64,
        processBaselineBytes: Int64,
        processPeakBytes: Int64,
        processFinalBytes: Int64,
        swapBaselineBytes: Int64,
        swapPeakBytes: Int64,
        swapDeltaBytes: Int64
    ) {
        self.mlxActiveBytes = mlxActiveBytes
        self.mlxCacheBytes = mlxCacheBytes
        self.mlxPeakBytes = mlxPeakBytes
        self.processBaselineBytes = processBaselineBytes
        self.processPeakBytes = processPeakBytes
        self.processFinalBytes = processFinalBytes
        self.swapBaselineBytes = swapBaselineBytes
        self.swapPeakBytes = swapPeakBytes
        self.swapDeltaBytes = swapDeltaBytes
    }

    public init(
        phaseSamples: [Krea2PhaseMemorySample],
        processSummary: Krea2ProcessMemorySummary
    ) {
        let orderedSamples = phaseSamples.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.elapsedNanoseconds < $1.elapsedNanoseconds
        }
        let finalMLX = orderedSamples.last(where: { $0.kind == .final })?.memory.mlx
            ?? orderedSamples.last?.memory.mlx
            ?? .zero
        let sampledMLXPeak = phaseSamples.map(\.memory.mlx.peakBytes).max() ?? 0
        let sampledProcessPeak = phaseSamples.map(\.memory.process.footprintBytes).max() ?? 0
        let sampledSwapPeak = phaseSamples.map(\.memory.process.swapUsedBytes).max() ?? 0
        let processPeak = max(processSummary.processPeakBytes, sampledProcessPeak)
        let swapPeak = max(processSummary.swapPeakBytes, sampledSwapPeak)
        self.init(
            mlxActiveBytes: finalMLX.activeBytes,
            mlxCacheBytes: finalMLX.cacheBytes,
            mlxPeakBytes: sampledMLXPeak,
            processBaselineBytes: processSummary.processBaselineBytes,
            processPeakBytes: processPeak,
            processFinalBytes: processSummary.processFinalBytes,
            swapBaselineBytes: processSummary.swapBaselineBytes,
            swapPeakBytes: swapPeak,
            swapDeltaBytes: max(0, swapPeak - processSummary.swapBaselineBytes))
    }
}

public struct Krea2BenchmarkRunReport: Codable, Equatable, Sendable {
    public var identity: Krea2BenchmarkRunIdentity
    public var cacheHit: Bool
    public var canonicalPixelDigest: Krea2CanonicalPixelDigest
    public var spans: [Krea2PerformanceSpan]
    public var stepDurations: [Krea2StepDuration]
    public var memorySamples: [Krea2PhaseMemorySample]
    public var memorySummary: Krea2MemorySummary

    public init(
        identity: Krea2BenchmarkRunIdentity,
        cacheHit: Bool,
        canonicalPixelDigest: Krea2CanonicalPixelDigest,
        spans: [Krea2PerformanceSpan],
        stepDurations: [Krea2StepDuration],
        memorySamples: [Krea2PhaseMemorySample],
        memorySummary: Krea2MemorySummary
    ) {
        self.identity = identity
        self.cacheHit = cacheHit
        self.canonicalPixelDigest = canonicalPixelDigest
        self.spans = spans
        self.stepDurations = stepDurations
        self.memorySamples = memorySamples
        self.memorySummary = memorySummary
    }

    public func canonicalized() -> Self {
        var copy = self
        copy.spans.sort {
            if $0.startedNanoseconds != $1.startedNanoseconds {
                return $0.startedNanoseconds < $1.startedNanoseconds
            }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.name < $1.name
        }
        copy.stepDurations.sort {
            if $0.startedNanoseconds != $1.startedNanoseconds {
                return $0.startedNanoseconds < $1.startedNanoseconds
            }
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            if $0.stepIndex != $1.stepIndex { return $0.stepIndex < $1.stepIndex }
            return $0.totalSteps < $1.totalSteps
        }
        copy.memorySamples.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if $0.elapsedNanoseconds != $1.elapsedNanoseconds {
                return $0.elapsedNanoseconds < $1.elapsedNanoseconds
            }
            return $0.phase < $1.phase
        }
        return copy
    }
}

public enum Krea2BaselineCompatibilityError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case unsupportedBenchmarkVersion(Int)
    case benchmarkVersionMismatch(report: Int, baseline: Int)
    case environmentMismatch
    case modelMismatch
    case runCountMismatch(report: Int, baseline: Int)
    case runConfigurationMismatch(index: Int)
    case canonicalPixelDigestMismatch(index: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported benchmark report schema version: \(version)."
        case let .unsupportedBenchmarkVersion(version):
            return "Unsupported benchmark definition version: \(version)."
        case let .benchmarkVersionMismatch(report, baseline):
            return "Benchmark definition version mismatch: report \(report), baseline \(baseline)."
        case .environmentMismatch:
            return "Benchmark environment does not match the baseline environment."
        case .modelMismatch:
            return "Benchmark model identity does not match the baseline model identity."
        case let .runCountMismatch(report, baseline):
            return "Benchmark run count mismatch: report \(report), baseline \(baseline)."
        case let .runConfigurationMismatch(index):
            return "Benchmark run configuration mismatch at canonical index \(index)."
        case let .canonicalPixelDigestMismatch(index):
            return "Canonical pixel digest mismatch at canonical index \(index)."
        }
    }
}

public struct Krea2PerformanceReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentBenchmarkVersion = 1

    public var schemaVersion: Int
    public var benchmarkVersion: Int
    public var generatedAt: String
    public var environment: Krea2BenchmarkEnvironment
    public var model: Krea2BenchmarkModelIdentity
    public var runs: [Krea2BenchmarkRunReport]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        benchmarkVersion: Int = Self.currentBenchmarkVersion,
        generatedAt: String,
        environment: Krea2BenchmarkEnvironment,
        model: Krea2BenchmarkModelIdentity,
        runs: [Krea2BenchmarkRunReport]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkVersion = benchmarkVersion
        self.generatedAt = generatedAt
        self.environment = environment
        self.model = model
        self.runs = runs
    }

    public func canonicalized() -> Self {
        var copy = self
        copy.runs = runs.map { $0.canonicalized() }.sorted {
            if $0.identity.ordinal != $1.identity.ordinal {
                return $0.identity.ordinal < $1.identity.ordinal
            }
            return $0.identity.id < $1.identity.id
        }
        return copy
    }

    /// Timing, memory, cache outcomes, run UUIDs, and pixel digests may differ. Everything that
    /// defines the machine/model/workload must match before performance numbers are compared.
    public func validateBaselineCompatibility(with baseline: Self) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw Krea2BaselineCompatibilityError.unsupportedSchemaVersion(schemaVersion)
        }
        guard baseline.schemaVersion == Self.currentSchemaVersion else {
            throw Krea2BaselineCompatibilityError.unsupportedSchemaVersion(baseline.schemaVersion)
        }
        guard benchmarkVersion == baseline.benchmarkVersion else {
            throw Krea2BaselineCompatibilityError.benchmarkVersionMismatch(
                report: benchmarkVersion,
                baseline: baseline.benchmarkVersion)
        }
        guard benchmarkVersion == Self.currentBenchmarkVersion else {
            throw Krea2BaselineCompatibilityError.unsupportedBenchmarkVersion(benchmarkVersion)
        }
        guard environment.hasSameBenchmarkHost(as: baseline.environment) else {
            throw Krea2BaselineCompatibilityError.environmentMismatch
        }
        guard model == baseline.model else {
            throw Krea2BaselineCompatibilityError.modelMismatch
        }

        let reportRuns = canonicalized().runs
        let baselineRuns = baseline.canonicalized().runs
        guard reportRuns.count == baselineRuns.count else {
            throw Krea2BaselineCompatibilityError.runCountMismatch(
                report: reportRuns.count,
                baseline: baselineRuns.count)
        }
        for index in reportRuns.indices {
            guard reportRuns[index].identity.hasSameBaselineConfiguration(
                as: baselineRuns[index].identity)
            else {
                throw Krea2BaselineCompatibilityError.runConfigurationMismatch(index: index)
            }
        }
    }

    /// Applies the compatibility gate and then requires byte-canonical output equality.
    public func validateBaseline(with baseline: Self) throws {
        try validateBaselineCompatibility(with: baseline)
        let reportRuns = canonicalized().runs
        let baselineRuns = baseline.canonicalized().runs
        for index in reportRuns.indices {
            guard reportRuns[index].canonicalPixelDigest
                    == baselineRuns[index].canonicalPixelDigest
            else {
                throw Krea2BaselineCompatibilityError.canonicalPixelDigestMismatch(index: index)
            }
        }
    }

    fileprivate func validateSupportedVersions() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw Krea2BaselineCompatibilityError.unsupportedSchemaVersion(schemaVersion)
        }
        guard benchmarkVersion == Self.currentBenchmarkVersion else {
            throw Krea2BaselineCompatibilityError.unsupportedBenchmarkVersion(benchmarkVersion)
        }
    }
}

public enum Krea2PerformanceReportJSON {
    public static func encode(_ report: Krea2PerformanceReport) throws -> Data {
        try report.validateSupportedVersions()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report.canonicalized())
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> Krea2PerformanceReport {
        let report = try JSONDecoder().decode(Krea2PerformanceReport.self, from: data)
        try report.validateSupportedVersions()
        return report
    }

    public static func read(from url: URL) throws -> Krea2PerformanceReport {
        try decode(Data(contentsOf: url))
    }

    /// Foundation writes a sibling temporary file and atomically replaces the destination.
    public static func write(_ report: Krea2PerformanceReport, to url: URL) throws {
        try encode(report).write(to: url, options: .atomic)
    }
}
