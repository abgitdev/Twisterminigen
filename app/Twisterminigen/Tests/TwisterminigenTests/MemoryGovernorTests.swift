import Testing
@testable import Twisterminigen

@Suite("Memory governor")
struct MemoryGovernorTests {
    typealias Governor = MemoryGovernor

    private let baselineJob = Governor.Job(width: 1_024, height: 1_024)

    @Test("Swap remains advisory through four GiB and turns red only above it")
    func swapLevelBoundaries() {
        let halfGiB = Governor.amberSwapLowerBound
        let twoGiB = Governor.highSwapThreshold
        let fourGiB = Governor.hardStopSwapThreshold

        #expect(status(swap: halfGiB - 1).level == .green)
        #expect(status(swap: halfGiB).level == .amber)
        #expect(status(swap: twoGiB).level == .amber)
        #expect(status(swap: twoGiB + 1).level == .amber)
        #expect(status(swap: fourGiB).level == .amber)
        #expect(status(swap: fourGiB + 1).level == .red)
    }

    @Test("Warning and critical OS pressure raise the level")
    func pressureRaisesLevel() {
        #expect(status(swap: 0, pressure: .warning).level == .amber)

        let critical = status(swap: 0, pressure: .critical)
        #expect(critical.level == .red)
        #expect(critical.requiresHardStop)
        #expect(critical.hardStopReasons == [.criticalPressure])
    }

    @Test("Only swap strictly above four GiB is a swap hard stop")
    func swapHardStopBoundary() {
        let fourGiB = Governor.hardStopSwapThreshold
        let atLimit = status(swap: fourGiB)
        let aboveLimit = status(swap: fourGiB + 1)

        #expect(atLimit.level == .amber)
        #expect(!atLimit.requiresHardStop)
        #expect(aboveLimit.requiresHardStop)
        #expect(aboveLimit.hardStopReasons == [.swapAboveFourGiB])
    }

    @Test("2.04 GiB with normal OS pressure warns but never blocks")
    func recoveredPressureWithResidualSwap() {
        let residualSwap = Int64(Double(Governor.bytesPerGiB) * 2.04)
        let snapshot = Governor.OSSnapshot(
            swapUsedBytes: residualSwap,
            pressure: .normal)

        let status = Governor.status(for: snapshot)
        #expect(status.level == .amber)
        #expect(!status.requiresHardStop)

        let result = Governor.preflight(snapshot: snapshot, job: baselineJob)
        #expect(result.decision == .warn)
        #expect(result.canStart)
        #expect(result.reasons == [.highSwap])
    }

    @Test("Injected fake snapshots drive synchronous status and preflight")
    func injectedSnapshot() {
        let fake = Governor.OSSnapshot(
            swapUsedBytes: Governor.amberSwapLowerBound,
            pressure: .normal)
        let governor = Governor(snapshotProvider: { fake })

        #expect(governor.status().level == .amber)
        let result = governor.preflight(for: baselineJob)
        #expect(result.decision == .warn)
        #expect(result.canStart)
        #expect(result.reasons == [.elevatedSwap])
    }

    @Test("Current quantized one-megapixel job is low risk")
    func baselineRisk() {
        let risk = Governor.riskProfile(for: baselineJob)

        #expect(risk.resolution == .low)
        #expect(risk.model == .low)
        #expect(risk.lora == .low)
        #expect(risk.batch == .low)
        #expect(risk.overall == .low)
        #expect(risk.score == 0)
    }

    @Test("Resolution, model, LoRA, and batch each contribute risk")
    func workloadDimensions() {
        let job = Governor.Job(
            width: 2_048,
            height: 2_048,
            model: .halfPrecision,
            loraAdapterCount: 3,
            totalLoRABytes: Governor.bytesPerGiB + 1,
            batchSize: 8)
        let risk = Governor.riskProfile(for: job)

        #expect(risk.resolution == .high)
        #expect(risk.model == .high)
        #expect(risk.lora == .high)
        #expect(risk.batch == .high)
        #expect(risk.overall == .high)
    }

    @Test("Several medium factors combine into high overall risk")
    func stackedMediumRisks() {
        let job = Governor.Job(
            width: 1_536,
            height: 1_536,
            model: .eightBitQuantized,
            loraAdapterCount: 1,
            batchSize: 1)

        let risk = Governor.riskProfile(for: job)
        #expect(risk.resolution == .medium)
        #expect(risk.model == .medium)
        #expect(risk.lora == .medium)
        #expect(risk.overall == .high)
    }

    @Test("High-risk and elevated-swap jobs warn while hard red snapshots reject")
    func preflightPolicy() {
        let highRiskJob = Governor.Job(width: 2_048, height: 2_048)
        let green = Governor.OSSnapshot(swapUsedBytes: 0, pressure: .normal)
        let hardStop = Governor.OSSnapshot(
            swapUsedBytes: Governor.hardStopSwapThreshold + 1,
            pressure: .normal)

        let warning = Governor.preflight(snapshot: green, job: highRiskJob)
        #expect(warning.decision == .warn)
        #expect(warning.canStart)
        #expect(warning.reasons == [.highRiskJob])

        let stopped = Governor.preflight(snapshot: hardStop, job: baselineJob)
        #expect(stopped.decision == .stop)
        #expect(!stopped.canStart)
        #expect(stopped.reasons == [.swapAboveFourGiB])

        let elevated = Governor.OSSnapshot(
            swapUsedBytes: Governor.highSwapThreshold + 1,
            pressure: .normal)
        let elevatedResult = Governor.preflight(snapshot: elevated, job: baselineJob)
        #expect(elevatedResult.decision == .warn)
        #expect(elevatedResult.canStart)
        #expect(!elevatedResult.status.requiresHardStop)
        #expect(elevatedResult.reasons == [.highSwap])
    }

    private func status(
        swap: Int64,
        pressure: Governor.Pressure = .normal
    ) -> Governor.Status {
        Governor.status(for: .init(swapUsedBytes: swap, pressure: pressure))
    }
}
