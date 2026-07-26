import Foundation

/// Polls process-level OS memory signals for the lifetime of one render.
///
/// The monitor is single-use: `start()` is idempotent, and a stopped monitor cannot be restarted.
/// All mutable state is protected by `LockedState.lock`; the unchecked conformance exists only
/// because `NSLock`-protected classes cannot derive `Sendable` conformance.
final class RenderMemoryMonitor: @unchecked Sendable {
    struct OSSample: Sendable, Equatable {
        var processPhysicalFootprintBytes: Int64
        var swapUsedBytes: Int64
        var pressure: MemoryGovernor.Pressure
        /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
        var thermalState: Int

        init(
            processPhysicalFootprintBytes: Int64,
            swapUsedBytes: Int64,
            pressure: MemoryGovernor.Pressure,
            thermalState: Int = 0
        ) {
            self.processPhysicalFootprintBytes = processPhysicalFootprintBytes
            self.swapUsedBytes = swapUsedBytes
            self.pressure = pressure
            self.thermalState = min(3, max(0, thermalState))
        }
    }

    struct Report: Sendable, Equatable {
        var processBaselineBytes: Int64
        var processPeakBytes: Int64
        var processFinalBytes: Int64
        var swapBaselineBytes: Int64
        var maxSwapUsedBytes: Int64
        var swapFinalBytes: Int64
        var worstPressure: MemoryGovernor.Pressure
        var thermalBaselineState: Int
        var worstThermalState: Int
        var thermalFinalState: Int
        var phaseDurations: [String: Duration]

        var maxSwapIncreaseBytes: Int64 {
            max(0, maxSwapUsedBytes - swapBaselineBytes)
        }
    }

    typealias SampleProvider = @Sendable () -> OSSample
    typealias HardStopHandler = @Sendable (MemoryGovernor.Status) -> Void
    typealias NowProvider = @Sendable () -> Duration

    private let sampleProvider: SampleProvider
    private let onHardStop: HardStopHandler
    private let pollInterval: Duration
    private let nowProvider: NowProvider
    private let state = LockedState()

    init(
        sampleProvider: @escaping SampleProvider,
        pollInterval: Duration = .milliseconds(250),
        nowProvider: NowProvider? = nil,
        onHardStop: @escaping HardStopHandler = { _ in }
    ) {
        self.sampleProvider = sampleProvider
        self.onHardStop = onHardStop
        self.pollInterval = pollInterval > .zero ? pollInterval : .milliseconds(1)
        self.nowProvider = nowProvider ?? Self.makeNowProvider()
    }

    deinit {
        state.cancelPolling()
    }

    /// Starts one polling task and captures the first sample immediately.
    func start() {
        let state = state
        let sampleProvider = sampleProvider
        let onHardStop = onHardStop
        let pollInterval = pollInterval

        let initialSample = sampleProvider()
        let started = state.start(initialSample: initialSample) {
            Task.detached(priority: .utility) {
                await Self.poll(
                    state: state,
                    sampleProvider: sampleProvider,
                    onHardStop: onHardStop,
                    interval: pollInterval)
            }
        }
        if let status = started.hardStopStatus {
            onHardStop(status)
        }
    }

    /// Ends the current phase and starts measuring `name`. Repeated marks of the same active
    /// phase do not reset its timer; later occurrences are accumulated under the same name.
    func markPhase(_ name: String) {
        state.markPhase(name, now: nowProvider)
    }

    /// Stops polling, closes the active phase, and returns an immutable report.
    /// Concurrent and repeated calls all wait for the same polling task and return the same data.
    func stop() async -> Report {
        if let status = state.record(sampleProvider()) {
            onHardStop(status)
        }
        let task = state.prepareToStop(now: nowProvider)
        task?.cancel()
        if let task {
            await task.value
        }
        return state.report()
    }

    /// Finalizes the monitor if necessary and returns its report.
    func finalReport() async -> Report {
        await stop()
    }

    private static func poll(
        state: LockedState,
        sampleProvider: SampleProvider,
        onHardStop: HardStopHandler,
        interval: Duration
    ) async {
        while !Task.isCancelled {
            let sample = sampleProvider()
            if let status = state.record(sample) {
                onHardStop(status)
            }

            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    private static func makeNowProvider() -> NowProvider {
        let clock = ContinuousClock()
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }

    private final class LockedState: @unchecked Sendable {
        private enum Lifecycle {
            case idle
            case running
            case stopped
        }

        private struct ActivePhase {
            var name: String
            var startedAt: Duration
        }

        private let lock = NSLock()
        private var lifecycle = Lifecycle.idle
        private var pollingTask: Task<Void, Never>?
        private var processBaselineBytes: Int64 = 0
        private var processPeakBytes: Int64 = 0
        private var processFinalBytes: Int64 = 0
        private var swapBaselineBytes: Int64 = 0
        private var maxSwapUsedBytes: Int64 = 0
        private var swapFinalBytes: Int64 = 0
        private var worstPressure = MemoryGovernor.Pressure.normal
        private var thermalBaselineState = 0
        private var worstThermalState = 0
        private var thermalFinalState = 0
        private var phaseDurations: [String: Duration] = [:]
        private var activePhase: ActivePhase?
        private var didRequestHardStop = false

        func start(
            initialSample: OSSample,
            makeTask: () -> Task<Void, Never>
        ) -> (didStart: Bool, hardStopStatus: MemoryGovernor.Status?) {
            withLock {
                guard lifecycle == .idle else { return (false, nil) }
                lifecycle = .running
                let footprint = max(0, initialSample.processPhysicalFootprintBytes)
                let swap = max(0, initialSample.swapUsedBytes)
                processBaselineBytes = footprint
                processPeakBytes = footprint
                processFinalBytes = footprint
                swapBaselineBytes = swap
                maxSwapUsedBytes = swap
                swapFinalBytes = swap
                worstPressure = initialSample.pressure
                thermalBaselineState = initialSample.thermalState
                worstThermalState = initialSample.thermalState
                thermalFinalState = initialSample.thermalState
                let status = hardStopStatus(for: initialSample)
                pollingTask = makeTask()
                return (true, status)
            }
        }

        func markPhase(_ name: String, now: NowProvider) {
            withLock {
                guard lifecycle == .running else { return }
                guard activePhase?.name != name else { return }

                let timestamp = now()
                closeActivePhase(at: timestamp)
                activePhase = ActivePhase(name: name, startedAt: timestamp)
            }
        }

        /// Returns a status only for the first hard-stop sample, reserving the callback while the
        /// lock is held so even future concurrent producers cannot deliver it twice.
        func record(_ sample: OSSample) -> MemoryGovernor.Status? {
            withLock {
                guard lifecycle == .running else { return nil }

                processPeakBytes = max(
                    processPeakBytes,
                    max(0, sample.processPhysicalFootprintBytes))
                processFinalBytes = max(0, sample.processPhysicalFootprintBytes)
                maxSwapUsedBytes = max(maxSwapUsedBytes, max(0, sample.swapUsedBytes))
                swapFinalBytes = max(0, sample.swapUsedBytes)
                if pressureRank(sample.pressure) > pressureRank(worstPressure) {
                    worstPressure = sample.pressure
                }
                worstThermalState = max(worstThermalState, sample.thermalState)
                thermalFinalState = sample.thermalState

                return hardStopStatus(for: sample)
            }
        }

        func prepareToStop(now: NowProvider) -> Task<Void, Never>? {
            withLock {
                switch lifecycle {
                case .idle:
                    lifecycle = .stopped
                case .running:
                    if activePhase != nil {
                        closeActivePhase(at: now())
                    }
                    lifecycle = .stopped
                case .stopped:
                    break
                }
                return pollingTask
            }
        }

        func report() -> Report {
            withLock {
                Report(
                    processBaselineBytes: processBaselineBytes,
                    processPeakBytes: processPeakBytes,
                    processFinalBytes: processFinalBytes,
                    swapBaselineBytes: swapBaselineBytes,
                    maxSwapUsedBytes: maxSwapUsedBytes,
                    swapFinalBytes: swapFinalBytes,
                    worstPressure: worstPressure,
                    thermalBaselineState: thermalBaselineState,
                    worstThermalState: worstThermalState,
                    thermalFinalState: thermalFinalState,
                    phaseDurations: phaseDurations)
            }
        }

        func cancelPolling() {
            let task = withLock { pollingTask }
            task?.cancel()
        }

        private func closeActivePhase(at timestamp: Duration) {
            guard let activePhase else { return }
            let elapsed = timestamp > activePhase.startedAt
                ? timestamp - activePhase.startedAt
                : .zero
            phaseDurations[activePhase.name, default: .zero] += elapsed
            self.activePhase = nil
        }

        private func pressureRank(_ pressure: MemoryGovernor.Pressure) -> Int {
            switch pressure {
            case .normal: 0
            case .warning: 1
            case .critical: 2
            }
        }

        private func hardStopStatus(for sample: OSSample) -> MemoryGovernor.Status? {
            let status = MemoryGovernor.status(for: .init(
                swapUsedBytes: sample.swapUsedBytes,
                pressure: sample.pressure))
            guard status.requiresHardStop, !didRequestHardStop else { return nil }
            didRequestHardStop = true
            return status
        }

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }
}
