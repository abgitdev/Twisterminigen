import Foundation
import Testing
@testable import Twisterminigen

@Suite("Render memory monitor")
struct RenderMemoryMonitorTests {
    typealias Monitor = RenderMemoryMonitor

    @Test("Polling captures independent process, swap, pressure, and thermal maxima")
    func capturesWorstObservedValues() async {
        let samples = FakeSamples([
            Self.sample(footprint: 100, swap: 30, pressure: .normal, thermal: 0),
            Self.sample(footprint: 500, swap: 20, pressure: .warning, thermal: 2),
            Self.sample(footprint: 300, swap: 90, pressure: .normal, thermal: 1),
        ])
        let monitor = Monitor(
            sampleProvider: { samples.next() },
            pollInterval: .milliseconds(1))

        monitor.start()
        #expect(await waitUntil { samples.callCount >= 3 })
        let report = await monitor.stop()

        #expect(report.processBaselineBytes == 100)
        #expect(report.processPeakBytes == 500)
        #expect(report.processFinalBytes == 300)
        #expect(report.swapBaselineBytes == 30)
        #expect(report.maxSwapUsedBytes == 90)
        #expect(report.swapFinalBytes == 90)
        #expect(report.maxSwapIncreaseBytes == 60)
        #expect(report.worstPressure == .warning)
        #expect(report.thermalBaselineState == 0)
        #expect(report.worstThermalState == 2)
        #expect(report.thermalFinalState == 1)
    }

    @Test("Hard-stop callback is delivered exactly once")
    func hardStopIsDeliveredOnce() async throws {
        let hardStop = Self.sample(
            footprint: 400,
            swap: MemoryGovernor.hardStopSwapThreshold + 1,
            pressure: .critical)
        let samples = FakeSamples(Array(repeating: hardStop, count: 6))
        let callbacks = StatusRecorder()
        let monitor = Monitor(
            sampleProvider: { samples.next() },
            pollInterval: .milliseconds(1),
            onHardStop: { callbacks.append($0) })

        monitor.start()
        #expect(await waitUntil { samples.callCount >= 5 })
        _ = await monitor.stop()

        let statuses = callbacks.values
        let status = try #require(statuses.first)
        #expect(statuses.count == 1)
        #expect(status.requiresHardStop)
        #expect(status.hardStopReasons == [.swapAboveFourGiB, .criticalPressure])
    }

    @Test("Marked phase durations are deterministic and repeated phases accumulate")
    func recordsPhaseDurations() async {
        let clock = FakeNow()
        let monitor = Monitor(
            sampleProvider: { Self.sample() },
            pollInterval: .seconds(60),
            nowProvider: { clock.now })

        monitor.start()
        monitor.markPhase("loading")
        clock.advance(by: .seconds(2))
        monitor.markPhase("denoising")
        clock.advance(by: .seconds(3))
        monitor.markPhase("loading")
        clock.advance(by: .milliseconds(1_500))

        let report = await monitor.stop()

        #expect(report.phaseDurations["loading"] == .milliseconds(3_500))
        #expect(report.phaseDurations["denoising"] == .seconds(3))
        #expect(report.phaseDurations.count == 2)
    }

    @Test("Concurrent stop and finalReport are idempotent")
    func stopIsIdempotent() async {
        let clock = FakeNow()
        let monitor = Monitor(
            sampleProvider: { Self.sample(footprint: 42, swap: 24) },
            pollInterval: .seconds(60),
            nowProvider: { clock.now })
        monitor.start()
        monitor.markPhase("render")
        clock.advance(by: .seconds(4))

        async let stopped = monitor.stop()
        async let finalized = monitor.finalReport()
        let (first, second) = await (stopped, finalized)

        #expect(first == second)
        #expect(first.phaseDurations["render"] == .seconds(4))

        monitor.markPhase("ignored-after-stop")
        let third = await monitor.stop()
        #expect(third == first)
    }

    private static func sample(
        footprint: Int64 = 0,
        swap: Int64 = 0,
        pressure: MemoryGovernor.Pressure = .normal,
        thermal: Int = 0
    ) -> Monitor.OSSample {
        .init(
            processPhysicalFootprintBytes: footprint,
            swapUsedBytes: swap,
            pressure: pressure,
            thermalState: thermal)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private final class FakeSamples: @unchecked Sendable {
        private let lock = NSLock()
        private let samples: [Monitor.OSSample]
        private var index = 0

        init(_ samples: [Monitor.OSSample]) {
            precondition(!samples.isEmpty)
            self.samples = samples
        }

        var callCount: Int {
            withLock { index }
        }

        func next() -> Monitor.OSSample {
            withLock {
                let sample = samples[min(index, samples.count - 1)]
                index += 1
                return sample
            }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private final class FakeNow: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Duration.zero

        var now: Duration {
            withLock { value }
        }

        func advance(by duration: Duration) {
            withLock { value += duration }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private final class StatusRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [MemoryGovernor.Status] = []

        var values: [MemoryGovernor.Status] {
            withLock { statuses }
        }

        func append(_ status: MemoryGovernor.Status) {
            withLock { statuses.append(status) }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
}
