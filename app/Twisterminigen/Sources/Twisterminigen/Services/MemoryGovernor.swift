import Foundation

/// Makes a synchronous start/no-start recommendation from one OS memory snapshot.
///
/// The governor does not poll and deliberately has no dependency on MLX. Its caller supplies a
/// fresh snapshot when asking for status or preflight, so allocator state is never read from a
/// task running alongside inference.
struct MemoryGovernor: Sendable {
    typealias SnapshotProvider = @Sendable () -> OSSnapshot

    static let bytesPerGiB: Int64 = 1_073_741_824
    static let amberSwapLowerBound = bytesPerGiB / 2
    static let highSwapThreshold = bytesPerGiB * 2
    static let hardStopSwapThreshold = bytesPerGiB * 4

    enum Level: Int, Sendable, Equatable, Comparable {
        case green
        case amber
        case red

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Pressure: Sendable, Equatable {
        case normal
        case warning
        case critical

        /// Maps `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical).
        init(systemLevel: Int) {
            switch systemLevel {
            case ..<2: self = .normal
            case 2..<4: self = .warning
            default: self = .critical
            }
        }
    }

    struct OSSnapshot: Sendable, Equatable {
        var swapUsedBytes: Int64
        var pressure: Pressure

        init(swapUsedBytes: Int64, pressure: Pressure) {
            self.swapUsedBytes = swapUsedBytes
            self.pressure = pressure
        }

        init(swapUsedBytes: Int64, systemPressureLevel: Int) {
            self.init(
                swapUsedBytes: swapUsedBytes,
                pressure: Pressure(systemLevel: systemPressureLevel))
        }
    }

    enum ModelProfile: Sendable, Equatable {
        /// The app's current Krea 2 mixed 4/8-bit transformer path.
        case mixed4And8Quantized
        case eightBitQuantized
        case halfPrecision
        case fullPrecision
    }

    struct Job: Sendable, Equatable {
        var width: Int
        var height: Int
        var model: ModelProfile
        var loraAdapterCount: Int
        var totalLoRABytes: Int64
        /// Twisterminigen renders batches sequentially. This measures duration/repeated-allocation
        /// exposure, not a concurrent batch's peak allocation.
        var batchSize: Int

        init(
            width: Int,
            height: Int,
            model: ModelProfile = .mixed4And8Quantized,
            loraAdapterCount: Int = 0,
            totalLoRABytes: Int64 = 0,
            batchSize: Int = 1
        ) {
            self.width = width
            self.height = height
            self.model = model
            self.loraAdapterCount = loraAdapterCount
            self.totalLoRABytes = totalLoRABytes
            self.batchSize = batchSize
        }
    }

    enum Risk: Int, Sendable, Equatable {
        case low
        case medium
        case high
    }

    struct JobRiskProfile: Sendable, Equatable {
        var resolution: Risk
        var model: Risk
        var lora: Risk
        var batch: Risk
        var overall: Risk
        var score: Int
    }

    enum HardStopReason: Sendable, Equatable {
        case swapAboveFourGiB
        case criticalPressure
    }

    struct Status: Sendable, Equatable {
        var level: Level
        var swapUsedBytes: Int64
        var pressure: Pressure
        var hardStopReasons: [HardStopReason]

        var requiresHardStop: Bool { !hardStopReasons.isEmpty }
    }

    enum PreflightDecision: Sendable, Equatable {
        case allow
        case warn
        case stop
    }

    enum PreflightReason: Sendable, Equatable {
        case elevatedSwap
        case highSwap
        case warningPressure
        case criticalPressure
        case swapAboveFourGiB
        case highRiskJob
    }

    struct PreflightResult: Sendable, Equatable {
        var decision: PreflightDecision
        var status: Status
        var risk: JobRiskProfile
        var reasons: [PreflightReason]

        var canStart: Bool { decision != .stop }
    }

    private let snapshotProvider: SnapshotProvider

    init(snapshotProvider: @escaping SnapshotProvider) {
        self.snapshotProvider = snapshotProvider
    }

    init(snapshot: OSSnapshot) {
        self.init(snapshotProvider: { snapshot })
    }

    /// Captures exactly one injected snapshot for each status request.
    func status() -> Status {
        Self.status(for: snapshotProvider())
    }

    /// Captures exactly one injected snapshot before a new job starts.
    func preflight(for job: Job) -> PreflightResult {
        Self.preflight(snapshot: snapshotProvider(), job: job)
    }

    /// Pure status classification. Swap is a lagging signal on macOS and can remain allocated
    /// after system pressure returns to normal, so it is advisory through 4 GiB. Red is reserved
    /// for the same boundary that blocks new work or for critical live OS memory pressure.
    static func status(for snapshot: OSSnapshot) -> Status {
        let swap = max(0, snapshot.swapUsedBytes)
        let swapLevel: Level
        if swap < amberSwapLowerBound {
            swapLevel = .green
        } else if swap <= hardStopSwapThreshold {
            swapLevel = .amber
        } else {
            swapLevel = .red
        }

        let pressureLevel: Level
        switch snapshot.pressure {
        case .normal: pressureLevel = .green
        case .warning: pressureLevel = .amber
        case .critical: pressureLevel = .red
        }

        var hardStopReasons: [HardStopReason] = []
        if swap > hardStopSwapThreshold {
            hardStopReasons.append(.swapAboveFourGiB)
        }
        if snapshot.pressure == .critical {
            hardStopReasons.append(.criticalPressure)
        }

        return Status(
            level: max(swapLevel, pressureLevel),
            swapUsedBytes: swap,
            pressure: snapshot.pressure,
            hardStopReasons: hardStopReasons)
    }

    /// Pure, monotonic workload classification. Resolution is based on pixel area; LoRA includes
    /// both adapter stacking and file bytes because adapters execute as float32 side branches.
    static func riskProfile(for job: Job) -> JobRiskProfile {
        let resolution = resolutionRisk(width: job.width, height: job.height)
        let model = modelRisk(job.model)
        let lora = loraRisk(
            adapterCount: job.loraAdapterCount,
            totalBytes: job.totalLoRABytes)
        let batch = batchRisk(job.batchSize)
        let components = [resolution, model, lora, batch]
        let score = components.reduce(0) { $0 + $1.rawValue }

        let overall: Risk
        if components.contains(.high) || score >= 3 {
            overall = .high
        } else if score > 0 {
            overall = .medium
        } else {
            overall = .low
        }

        return JobRiskProfile(
            resolution: resolution,
            model: model,
            lora: lora,
            batch: batch,
            overall: overall,
            score: score)
    }

    /// Pure preflight policy. Red memory state rejects a new job before it allocates anything;
    /// the stricter hard-stop reasons are also used to cancel work that is already in progress.
    /// A high-risk job warns even while the OS is currently green so the UI can ask once.
    static func preflight(snapshot: OSSnapshot, job: Job) -> PreflightResult {
        let status = status(for: snapshot)
        let risk = riskProfile(for: job)
        var reasons: [PreflightReason] = []

        switch status.pressure {
        case .normal: break
        case .warning: reasons.append(.warningPressure)
        case .critical: reasons.append(.criticalPressure)
        }

        if status.swapUsedBytes > hardStopSwapThreshold {
            reasons.append(.swapAboveFourGiB)
        } else if status.swapUsedBytes > highSwapThreshold {
            reasons.append(.highSwap)
        } else if status.swapUsedBytes >= amberSwapLowerBound {
            reasons.append(.elevatedSwap)
        }

        if risk.overall == .high {
            reasons.append(.highRiskJob)
        }

        let decision: PreflightDecision
        if status.level == .red {
            decision = .stop
        } else if status.level != .green || risk.overall == .high {
            decision = .warn
        } else {
            decision = .allow
        }

        return PreflightResult(
            decision: decision,
            status: status,
            risk: risk,
            reasons: reasons)
    }

    private static func resolutionRisk(width: Int, height: Int) -> Risk {
        guard width > 0, height > 0 else { return .high }
        let pixels = Double(width) * Double(height)
        if pixels <= Double(1_024 * 1_024) { return .low }
        if pixels <= Double(1_536 * 1_536) { return .medium }
        return .high
    }

    private static func modelRisk(_ model: ModelProfile) -> Risk {
        switch model {
        case .mixed4And8Quantized: return .low
        case .eightBitQuantized: return .medium
        case .halfPrecision, .fullPrecision: return .high
        }
    }

    private static func loraRisk(adapterCount: Int, totalBytes: Int64) -> Risk {
        let count = max(0, adapterCount)
        let bytes = max(0, totalBytes)
        guard count > 0 || bytes > 0 else { return .low }
        if count >= 3 || bytes > bytesPerGiB { return .high }
        return .medium
    }

    private static func batchRisk(_ batchSize: Int) -> Risk {
        guard batchSize > 0 else { return .high }
        if batchSize <= 2 { return .low }
        if batchSize <= 4 { return .medium }
        return .high
    }
}
