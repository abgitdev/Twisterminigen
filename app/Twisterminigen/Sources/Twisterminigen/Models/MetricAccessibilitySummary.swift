import Foundation

/// Concise, non-visual descriptions for telemetry charts and metric cards.
enum MetricAccessibilitySummary {
    static func trend(_ samples: [Double]) -> String {
        let finite = samples.filter(\.isFinite)
        guard let first = finite.first,
              let last = finite.last,
              let minimum = finite.min(),
              let maximum = finite.max()
        else {
            return "No recent trend samples."
        }

        let span = max(1, maximum - minimum)
        let delta = last - first
        let direction: String
        if abs(delta) <= span * 0.02 {
            direction = "steady"
        } else if delta > 0 {
            direction = "rising"
        } else {
            direction = "falling"
        }

        return "Recent trend \(direction), from \(number(first)) to \(number(last)); minimum \(number(minimum)), maximum \(number(maximum))."
    }

    static func metric(
        label: String,
        value: String,
        detail: String,
        samples: [Double]? = nil
    ) -> String {
        var parts = ["\(label): \(value).", detail]
        if let samples { parts.append(trend(samples)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func performance(_ metrics: GenerationPerformanceMetrics) -> String {
        let scope = metrics.scope == .singleImage
            ? "Single image"
            : "Session totals for \(metrics.sessionItemCount) images"
        return [
            "\(scope).",
            "Measured phases \(GenerationPerformanceMetrics.durationText(metrics.measuredPhaseSeconds)).",
            "Text encoder \(GenerationPerformanceMetrics.durationText(metrics.textEncoderSeconds)); diffusion denoise \(GenerationPerformanceMetrics.durationText(metrics.denoisingSeconds)); VAE decode \(GenerationPerformanceMetrics.durationText(metrics.vaeDecodeSeconds)).",
            "Process peak \(ByteFormat.string(metrics.processPeakBytes)); MLX peak \(ByteFormat.string(metrics.mlxPeakBytes)); swap increase \(ByteFormat.string(metrics.swapIncreaseBytes)); memory pressure \(metrics.worstMemoryPressure.title); worst thermal state \(GenerationPerformanceMetrics.thermalStateTitle(metrics.worstThermalState)).",
        ].joined(separator: " ")
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}
