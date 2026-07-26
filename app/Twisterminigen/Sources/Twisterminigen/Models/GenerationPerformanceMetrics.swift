import Foundation

/// Persisted, evidence-based timings and memory high-water marks for one render session.
///
/// Planned/batched generation can reuse TE, DiT, and VAE state across several outputs. In that
/// case the same session report is attached to every output and `sessionItemCount` makes the scope
/// explicit; these values must never be presented as per-image timings.
struct GenerationPerformanceMetrics: Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    static let maximumSessionItemCount = GenerationProvenance.maximumGroupCount
    static let maximumByteCount: Int64 = 1 << 50 // 1 PiB: corruption guard, not a device claim.

    enum Scope: String, Codable, Sendable, Hashable {
        case singleImage
        case plannedSession
    }

    enum MemoryPressure: String, Codable, Sendable, Hashable {
        case normal
        case warning
        case critical

        var title: String {
            switch self {
            case .normal: "Normal"
            case .warning: "Warning"
            case .critical: "Critical"
            }
        }
    }

    let schemaVersion: Int
    let scope: Scope
    let sessionItemCount: Int

    /// Input preparation outside the engine (including Remix source preprocessing).
    let preparationSeconds: Double
    /// Text-encoder conditioning. This is the TE metric shown in Gallery.
    let textEncoderSeconds: Double
    /// VAE encoding of a Remix source. Zero for text-to-image sessions.
    let imageEncoderSeconds: Double
    /// Loading/materializing the quantized diffusion transformer.
    let transformerLoadSeconds: Double
    /// All diffusion-transformer denoise steps in the session.
    let denoisingSeconds: Double
    /// Final VAE image decode.
    let vaeDecodeSeconds: Double
    /// Tensor-to-PNG conversion after the engine returns pixels.
    let pngEncodingSeconds: Double

    let processBaselineBytes: Int64
    let processPeakBytes: Int64
    let processFinalBytes: Int64
    let mlxPeakBytes: Int64
    let mlxActiveBytes: Int64
    let mlxCacheBytes: Int64
    let swapBaselineBytes: Int64
    let swapPeakBytes: Int64
    let swapFinalBytes: Int64
    let worstMemoryPressure: MemoryPressure
    /// Optional for backward compatibility with Gallery records written before Stage 6.
    let thermalBaselineState: Int?
    let worstThermalState: Int?
    let thermalFinalState: Int?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionItemCount: Int,
        preparationSeconds: Double,
        textEncoderSeconds: Double,
        imageEncoderSeconds: Double,
        transformerLoadSeconds: Double,
        denoisingSeconds: Double,
        vaeDecodeSeconds: Double,
        pngEncodingSeconds: Double,
        processBaselineBytes: Int64,
        processPeakBytes: Int64,
        processFinalBytes: Int64,
        mlxPeakBytes: Int64,
        mlxActiveBytes: Int64,
        mlxCacheBytes: Int64,
        swapBaselineBytes: Int64,
        swapPeakBytes: Int64,
        swapFinalBytes: Int64,
        worstMemoryPressure: MemoryPressure,
        thermalBaselineState: Int? = nil,
        worstThermalState: Int? = nil,
        thermalFinalState: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.scope = sessionItemCount == 1 ? .singleImage : .plannedSession
        self.sessionItemCount = sessionItemCount
        self.preparationSeconds = preparationSeconds
        self.textEncoderSeconds = textEncoderSeconds
        self.imageEncoderSeconds = imageEncoderSeconds
        self.transformerLoadSeconds = transformerLoadSeconds
        self.denoisingSeconds = denoisingSeconds
        self.vaeDecodeSeconds = vaeDecodeSeconds
        self.pngEncodingSeconds = pngEncodingSeconds
        self.processBaselineBytes = processBaselineBytes
        self.processPeakBytes = processPeakBytes
        self.processFinalBytes = processFinalBytes
        self.mlxPeakBytes = mlxPeakBytes
        self.mlxActiveBytes = mlxActiveBytes
        self.mlxCacheBytes = mlxCacheBytes
        self.swapBaselineBytes = swapBaselineBytes
        self.swapPeakBytes = swapPeakBytes
        self.swapFinalBytes = swapFinalBytes
        self.worstMemoryPressure = worstMemoryPressure
        self.thermalBaselineState = thermalBaselineState
        self.worstThermalState = worstThermalState
        self.thermalFinalState = thermalFinalState
    }

    /// Converts the monitor's named phases without inventing timings for phases that did not run.
    /// Unknown future phase names are intentionally ignored by schema v1.
    init(
        sessionItemCount: Int,
        phaseDurations: [String: Duration],
        processBaselineBytes: Int64,
        processPeakBytes: Int64,
        processFinalBytes: Int64,
        mlxPeakBytes: Int64,
        mlxActiveBytes: Int64,
        mlxCacheBytes: Int64,
        swapBaselineBytes: Int64,
        swapPeakBytes: Int64,
        swapFinalBytes: Int64,
        worstMemoryPressure: MemoryPressure,
        thermalBaselineState: Int? = nil,
        worstThermalState: Int? = nil,
        thermalFinalState: Int? = nil
    ) {
        self.init(
            sessionItemCount: sessionItemCount,
            preparationSeconds: Self.seconds(phaseDurations["preparing"]),
            textEncoderSeconds: Self.seconds(phaseDurations["encodingPrompt"]),
            imageEncoderSeconds: Self.seconds(phaseDurations["encodingImage"]),
            transformerLoadSeconds: Self.seconds(phaseDurations["loadingTransformer"]),
            denoisingSeconds: Self.seconds(phaseDurations["denoising"]),
            vaeDecodeSeconds: Self.seconds(phaseDurations["decoding"]),
            pngEncodingSeconds: Self.seconds(phaseDurations["encodingPNG"]),
            processBaselineBytes: processBaselineBytes,
            processPeakBytes: processPeakBytes,
            processFinalBytes: processFinalBytes,
            mlxPeakBytes: mlxPeakBytes,
            mlxActiveBytes: mlxActiveBytes,
            mlxCacheBytes: mlxCacheBytes,
            swapBaselineBytes: swapBaselineBytes,
            swapPeakBytes: swapPeakBytes,
            swapFinalBytes: swapFinalBytes,
            worstMemoryPressure: worstMemoryPressure,
            thermalBaselineState: thermalBaselineState,
            worstThermalState: worstThermalState,
            thermalFinalState: thermalFinalState)
    }

    var measuredPhaseSeconds: Double {
        preparationSeconds
            + textEncoderSeconds
            + imageEncoderSeconds
            + transformerLoadSeconds
            + denoisingSeconds
            + vaeDecodeSeconds
            + pngEncodingSeconds
    }

    var swapIncreaseBytes: Int64 { max(0, swapPeakBytes - swapBaselineBytes) }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard (1 ... Self.maximumSessionItemCount).contains(sessionItemCount) else {
            throw ValidationError.invalidSessionItemCount(sessionItemCount)
        }
        guard scope == (sessionItemCount == 1 ? .singleImage : .plannedSession) else {
            throw ValidationError.inconsistentScope
        }

        let timings = [
            preparationSeconds,
            textEncoderSeconds,
            imageEncoderSeconds,
            transformerLoadSeconds,
            denoisingSeconds,
            vaeDecodeSeconds,
            pngEncodingSeconds,
        ]
        guard timings.allSatisfy({
            $0.isFinite && $0 >= 0 && $0 <= Generation.maximumDurationSeconds
        }), measuredPhaseSeconds <= Generation.maximumDurationSeconds else {
            throw ValidationError.invalidTiming
        }

        let bytes = [
            processBaselineBytes,
            processPeakBytes,
            processFinalBytes,
            mlxPeakBytes,
            mlxActiveBytes,
            mlxCacheBytes,
            swapBaselineBytes,
            swapPeakBytes,
            swapFinalBytes,
        ]
        guard bytes.allSatisfy({ (0 ... Self.maximumByteCount).contains($0) }),
              processBaselineBytes <= processPeakBytes,
              processFinalBytes <= processPeakBytes,
              swapBaselineBytes <= swapPeakBytes,
              swapFinalBytes <= swapPeakBytes else {
            throw ValidationError.invalidMemory
        }
        let thermal = [thermalBaselineState, worstThermalState, thermalFinalState].compactMap { $0 }
        guard thermal.allSatisfy({ (0 ... 3).contains($0) }),
              thermalBaselineState.map({ $0 <= (worstThermalState ?? $0) }) ?? true,
              thermalFinalState.map({ $0 <= (worstThermalState ?? $0) }) ?? true else {
            throw ValidationError.invalidThermalState
        }
    }

    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unknown" }
        if seconds < 0.001 { return "<1 ms" }
        if seconds < 1 { return "\(Int((seconds * 1_000).rounded())) ms" }
        if seconds < 10 { return String(format: "%.2f s", seconds) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }

    static func thermalStateTitle(_ rawValue: Int?) -> String {
        switch rawValue {
        case 0: "Nominal"
        case 1: "Fair"
        case 2: "Serious"
        case 3: "Critical"
        default: "Not recorded"
        }
    }

    enum ValidationError: Error, Equatable, LocalizedError {
        case unsupportedSchemaVersion(Int)
        case invalidSessionItemCount(Int)
        case inconsistentScope
        case invalidTiming
        case invalidMemory
        case invalidThermalState

        var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "Performance metrics use unsupported schema version \(version)."
            case .invalidSessionItemCount(let count):
                return "Performance metrics session item count \(count) is invalid."
            case .inconsistentScope:
                return "Performance metrics scope does not match its session item count."
            case .invalidTiming:
                return "Performance metrics contain an invalid phase duration."
            case .invalidMemory:
                return "Performance metrics contain inconsistent memory measurements."
            case .invalidThermalState:
                return "Performance metrics contain inconsistent thermal measurements."
            }
        }
    }

    private static func seconds(_ duration: Duration?) -> Double {
        guard let duration else { return 0 }
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
