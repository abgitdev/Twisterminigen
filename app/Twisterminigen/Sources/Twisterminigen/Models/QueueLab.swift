import Foundation

/// A versioned, replayable description of the table that produced a Queue Lab group.
///
/// The context is stored with every member's provenance. Keeping the source recipe and the axes
/// together means Gallery can rebuild the original table without inferring it from whichever
/// results happened to finish. Older queue/gallery JSON has no `experimentContext` key and keeps
/// decoding through the optional provenance field.
struct ExperimentContext: Codable, Sendable, Hashable {
    static let supportedSchema = "twisterminigen.queue-lab-experiment"
    static let currentVersion = 1

    let schema: String
    let version: Int
    let sourceRecipe: GenerationRecipe
    let configuration: QueueLab.Configuration

    init(
        schema: String = Self.supportedSchema,
        version: Int = Self.currentVersion,
        sourceRecipe: GenerationRecipe,
        configuration: QueueLab.Configuration
    ) {
        self.schema = schema
        self.version = version
        self.sourceRecipe = sourceRecipe
        self.configuration = configuration
    }

    func preview() throws -> QueueLab.Preview {
        try QueueLab.preview(for: self)
    }

    var summary: String {
        var fields = [
            "\(configuration.seedCount) seed\(configuration.seedCount == 1 ? "" : "s")",
        ]
        if let label = QueueLab.axisLabel(configuration.xAxis, in: sourceRecipe) {
            fields.append("X: \(label)")
        }
        if let label = QueueLab.axisLabel(configuration.yAxis, in: sourceRecipe) {
            fields.append("Y: \(label)")
        }
        return fields.joined(separator: " · ")
    }
}

/// Builds deterministic, bounded queue experiments from one generation recipe.
enum QueueLab {
    static let maximumJobCount = 64
    static let minimumTurboSteps = 4
    static let maximumTurboSteps = 12
    static let minimumStrength = 0.05

    enum Parameter: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
        case promptVariants
        case canvasSize
        case steps
        case guidance
        case imageToImageStrength
        /// The persisted spelling predates selectable adapters. `Axis.loRAID` now identifies which
        /// adapter is swept; a nil ID deliberately retains the old first-adapter behavior.
        case firstLoRAScale

        var id: String { rawValue }

        var title: String {
            switch self {
            case .promptVariants: "Prompt variants"
            case .canvasSize: "Aspect / size"
            case .steps: "Steps"
            case .guidance: "Guidance"
            case .imageToImageStrength: "Remix strength"
            case .firstLoRAScale: "LoRA scale"
            }
        }

        var isDiscrete: Bool {
            self == .promptVariants || self == .canvasSize
        }
    }

    struct Axis: Codable, Equatable, Hashable, Sendable {
        var parameter: Parameter?
        var start: Double
        var end: Double
        var valueCount: Int
        var promptTemplate: String
        var canvasSizes: [GenerationRecipe.Canvas]
        var loRAID: UUID?

        init(
            parameter: Parameter? = nil,
            start: Double = 0,
            end: Double = 0,
            valueCount: Int = 1,
            promptTemplate: String = "",
            canvasSizes: [GenerationRecipe.Canvas] = [],
            loRAID: UUID? = nil
        ) {
            self.parameter = parameter
            self.start = start
            self.end = end
            self.valueCount = valueCount
            self.promptTemplate = promptTemplate
            self.canvasSizes = canvasSizes
            self.loRAID = loRAID
        }

        static let disabled = Axis()

        static func defaults(
            for parameter: Parameter,
            in recipe: GenerationRecipe
        ) -> Axis {
            switch parameter {
            case .promptVariants:
                return Axis(
                    parameter: parameter,
                    promptTemplate: recipe.prompts.positive)
            case .canvasSize:
                return Axis(
                    parameter: parameter,
                    canvasSizes: QueueLab.defaultCanvasSizes(for: recipe.canvas))
            case .steps:
                let center = recipe.sampler.steps
                return Axis(
                    parameter: parameter,
                    start: Double(max(minimumTurboSteps, center - 2)),
                    end: Double(min(maximumTurboSteps, center + 2)),
                    valueCount: 3)
            case .guidance:
                let center = recipe.sampler.guidance
                return Axis(
                    parameter: parameter,
                    start: max(0, center - 2),
                    end: min(GenerationRecipe.maximumGuidance, center + 2),
                    valueCount: 3)
            case .imageToImageStrength:
                let center = recipe.inputImage?.strength ?? 0.65
                return Axis(
                    parameter: parameter,
                    start: max(minimumStrength, center - 0.2),
                    end: min(1, center + 0.2),
                    valueCount: 3)
            case .firstLoRAScale:
                let lora = recipe.loras.first
                let center = lora?.scale ?? 1
                return Axis(
                    parameter: parameter,
                    start: max(minimumStrength, center - 0.25),
                    end: min(GenerationRecipe.maximumLoRAScale, center + 0.25),
                    valueCount: 3,
                    loRAID: lora?.managedID)
            }
        }
    }

    struct Configuration: Codable, Equatable, Hashable, Sendable {
        var seedStart: UInt64
        var seedCount: Int
        var xAxis: Axis
        var yAxis: Axis

        init(
            seedStart: UInt64,
            seedCount: Int = 1,
            xAxis: Axis = .disabled,
            yAxis: Axis = .disabled
        ) {
            self.seedStart = seedStart
            self.seedCount = seedCount
            self.xAxis = xAxis
            self.yAxis = yAxis
        }

        init(recipe: GenerationRecipe, seedCount: Int = 1) {
            seedStart = recipe.sampler.seed.fixedValue ?? 0
            self.seedCount = seedCount
            xAxis = .disabled
            yAxis = .disabled
        }
    }

    struct ParameterValue: Equatable, Hashable, Sendable {
        enum Payload: Equatable, Hashable, Sendable {
            case number(Double)
            case prompt(String)
            case canvas(GenerationRecipe.Canvas)
        }

        let parameter: Parameter
        let payload: Payload
        let loRAID: UUID?

        init(parameter: Parameter, value: Double, loRAID: UUID? = nil) {
            self.parameter = parameter
            payload = .number(value)
            self.loRAID = loRAID
        }

        init(prompt: String) {
            parameter = .promptVariants
            payload = .prompt(prompt)
            loRAID = nil
        }

        init(canvas: GenerationRecipe.Canvas) {
            parameter = .canvasSize
            payload = .canvas(canvas)
            loRAID = nil
        }

        var value: Double? {
            guard case .number(let value) = payload else { return nil }
            return value
        }

        var prompt: String? {
            guard case .prompt(let prompt) = payload else { return nil }
            return prompt
        }

        var canvas: GenerationRecipe.Canvas? {
            guard case .canvas(let canvas) = payload else { return nil }
            return canvas
        }

        var steps: Int? {
            guard parameter == .steps, let value else { return nil }
            return Int(value)
        }

        var displayText: String {
            switch payload {
            case .number(let value):
                if parameter == .steps { return String(Int(value)) }
                return value.formatted(.number.precision(.fractionLength(0 ... 3)))
            case .prompt(let prompt):
                return prompt
            case .canvas(let canvas):
                return "\(canvas.width)×\(canvas.height)"
            }
        }
    }

    struct PreviewEntry: Equatable, Identifiable, Sendable {
        let index: Int
        let seedIndex: Int
        let xIndex: Int
        let yIndex: Int
        let seed: UInt64
        let xValue: ParameterValue?
        let yValue: ParameterValue?
        let recipe: GenerationRecipe

        var id: Int { index }
    }

    struct Preview: Equatable, Sendable {
        let entries: [PreviewEntry]
        let seeds: [UInt64]
        let xValues: [ParameterValue]
        let yValues: [ParameterValue]
        let context: ExperimentContext

        var jobCount: Int { entries.count }

        func makeJobs(
            groupID: UUID = UUID(),
            id: (Int) -> UUID = { _ in UUID() }
        ) -> [QueueJob] {
            let xLabel = QueueLab.axisLabel(context.configuration.xAxis, in: context.sourceRecipe)
            let yLabel = QueueLab.axisLabel(context.configuration.yAxis, in: context.sourceRecipe)
            return entries.map { entry in
                let grid = GenerationProvenance.QueueLabGrid(
                    seedIndex: entry.seedIndex,
                    seedCount: seeds.count,
                    xIndex: entry.xIndex,
                    xCount: max(1, xValues.count),
                    xLabel: xLabel,
                    yIndex: entry.yIndex,
                    yCount: max(1, yValues.count),
                    yLabel: yLabel)
                return QueueJob(
                    id: id(entry.index),
                    recipe: entry.recipe,
                    provenance: .queueLab(
                        groupID: groupID,
                        itemIndex: entry.index,
                        itemCount: entries.count,
                        grid: grid,
                        experimentContext: context))
            }
        }
    }

    struct WildcardExpansion: Equatable, Sendable {
        let prompts: [String]
        let truncated: Bool
        let totalCombinations: Int
    }

    enum ValidationError: Error, Equatable, Sendable {
        case invalidBaseRecipe(String)
        case invalidExperimentSchema(String)
        case unsupportedExperimentVersion(Int)
        case invalidSeedCount(Int)
        case seedRangeOverflow
        case duplicateParameters(Parameter)
        case unavailableParameter(Parameter)
        case unavailableLoRA(UUID)
        case invalidValueCount(parameter: Parameter, count: Int)
        case nonFiniteValue(parameter: Parameter)
        case outOfBounds(parameter: Parameter, value: Double)
        case nonIntegralStepValue(Double)
        case emptyPromptVariant(Int)
        case promptTemplateTooLong
        case invalidCanvas(width: Int, height: Int)
        case duplicateValues(Parameter)
        case jobLimitExceeded(actual: Int, maximum: Int)
    }

    static let standardCanvasSizes: [GenerationRecipe.Canvas] = [
        .init(width: 1_024, height: 1_024),
        .init(width: 1_216, height: 832),
        .init(width: 832, height: 1_216),
        .init(width: 1_344, height: 768),
        .init(width: 768, height: 1_344),
    ]

    static func defaultCanvasSizes(
        for source: GenerationRecipe.Canvas
    ) -> [GenerationRecipe.Canvas] {
        unique([source] + standardCanvasSizes.prefix(3))
    }

    static func availableParameters(
        for recipe: GenerationRecipe
    ) -> [Parameter] {
        Parameter.allCases.filter { parameter in
            switch parameter {
            case .promptVariants, .canvasSize, .steps: true
            // The regional sampler does not support nonzero CFG. Hide and reject the entire axis
            // instead of allowing a range that can only fail after the queue starts.
            case .guidance: recipe.regions.isEmpty
            case .imageToImageStrength: recipe.inputImage != nil
            case .firstLoRAScale: !recipe.loras.isEmpty
            }
        }
    }

    static func jobCount(
        for recipe: GenerationRecipe,
        configuration: Configuration
    ) throws -> Int {
        try plan(for: recipe, configuration: configuration).jobCount
    }

    /// Ordering is stable: each seed contains a row-major Y-by-X sweep grid.
    static func preview(
        for recipe: GenerationRecipe,
        configuration: Configuration
    ) throws -> Preview {
        try preview(
            for: recipe,
            configuration: configuration,
            context: ExperimentContext(sourceRecipe: recipe, configuration: configuration))
    }

    static func preview(for context: ExperimentContext) throws -> Preview {
        guard context.schema == ExperimentContext.supportedSchema else {
            throw ValidationError.invalidExperimentSchema(context.schema)
        }
        guard context.version == ExperimentContext.currentVersion else {
            throw ValidationError.unsupportedExperimentVersion(context.version)
        }
        return try preview(
            for: context.sourceRecipe,
            configuration: context.configuration,
            context: context)
    }

    /// Expands deterministic `{one|two}` choices without regex backtracking or unbounded products.
    /// Malformed/nested braces remain literal. A valid JSON object/array remains one literal prompt,
    /// so structured prompts containing braces and pipes are never split accidentally.
    static func expandWildcards(
        _ prompt: String,
        cap: Int = maximumJobCount
    ) -> WildcardExpansion {
        guard prompt.contains("{") else {
            return WildcardExpansion(
                prompts: [prompt],
                truncated: false,
                totalCombinations: 1)
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return WildcardExpansion(
                prompts: [prompt],
                truncated: false,
                totalCombinations: 1)
        }

        // Choice groups deliberately do not nest. Treat the complete prompt as literal as soon as
        // another opener appears before the current group closes; partially expanding the inner
        // group would silently mutate a malformed prompt into text the user never authored.
        var insideGroup = false
        for character in prompt {
            if character == "{" {
                guard !insideGroup else {
                    return WildcardExpansion(
                        prompts: [prompt],
                        truncated: false,
                        totalCombinations: 1)
                }
                insideGroup = true
            } else if character == "}", insideGroup {
                insideGroup = false
            }
        }

        enum Part {
            case literal(String)
            case group([String])
        }

        let characters = Array(prompt)
        var parts: [Part] = []
        var literal = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "{" else {
                literal.append(characters[index])
                index += 1
                continue
            }

            var closingIndex = index + 1
            var content = ""
            var closed = false
            while closingIndex < characters.count {
                if characters[closingIndex] == "{" { break }
                if characters[closingIndex] == "}" {
                    closed = true
                    break
                }
                content.append(characters[closingIndex])
                closingIndex += 1
            }
            guard closed, content.contains("|") else {
                literal.append(characters[index])
                index += 1
                continue
            }

            parts.append(.literal(literal))
            literal = ""
            parts.append(.group(content
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }))
            index = closingIndex + 1
        }
        parts.append(.literal(literal))

        let groups: [[String]] = parts.compactMap { part in
            guard case .group(let options) = part else { return nil }
            return options
        }
        guard !groups.isEmpty else {
            return WildcardExpansion(
                prompts: [prompt],
                truncated: false,
                totalCombinations: 1)
        }

        var totalCombinations = 1
        for group in groups {
            let (next, overflow) = totalCombinations.multipliedReportingOverflow(by: group.count)
            totalCombinations = overflow ? .max : next
        }
        let effectiveCap = max(1, cap)
        let count = min(effectiveCap, totalCombinations)

        func build(_ selections: [Int]) -> String {
            var output = ""
            var groupIndex = 0
            for part in parts {
                switch part {
                case .literal(let string): output += string
                case .group(let options):
                    output += options[selections[groupIndex]]
                    groupIndex += 1
                }
            }
            return output
        }

        var prompts: [String] = []
        prompts.reserveCapacity(count)
        for combination in 0 ..< count {
            var remaining = combination
            var selections = [Int](repeating: 0, count: groups.count)
            for groupIndex in stride(from: groups.count - 1, through: 0, by: -1) {
                selections[groupIndex] = remaining % groups[groupIndex].count
                remaining /= groups[groupIndex].count
            }
            prompts.append(build(selections))
        }
        return WildcardExpansion(
            prompts: prompts,
            truncated: totalCombinations > effectiveCap,
            totalCombinations: totalCombinations)
    }

    static func axisLabel(
        _ axis: Axis,
        in recipe: GenerationRecipe
    ) -> String? {
        guard let parameter = axis.parameter else { return nil }
        if parameter == .firstLoRAScale,
           let id = resolvedLoRAID(for: axis, in: recipe),
           let index = recipe.loras.firstIndex(where: { $0.managedID == id }) {
            return "LoRA \(index + 1) scale"
        }
        return parameter.title
    }
}

extension QueueLab.ValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidBaseRecipe(reason):
            return "The source recipe is invalid: \(reason)"
        case let .invalidExperimentSchema(schema):
            return "Unsupported Queue Lab experiment schema: \(schema)."
        case let .unsupportedExperimentVersion(version):
            return "Queue Lab experiment version \(version) is not supported."
        case let .invalidSeedCount(count):
            return "Seed count must be between 1 and \(QueueLab.maximumJobCount); received \(count)."
        case .seedRangeOverflow:
            return "The seed sequence exceeds the UInt64 range."
        case let .duplicateParameters(parameter):
            return "X and Y cannot both sweep \(parameter.title)."
        case let .unavailableParameter(parameter):
            return "\(parameter.title) is not available in the source recipe."
        case let .unavailableLoRA(id):
            return "The selected LoRA \(id.uuidString) is not active in the source recipe."
        case let .invalidValueCount(parameter, count):
            return "\(parameter.title) needs 1...\(QueueLab.maximumJobCount) values; received \(count)."
        case let .nonFiniteValue(parameter):
            return "\(parameter.title) values must be finite."
        case let .outOfBounds(parameter, value):
            return "\(parameter.title) value \(value) is outside its supported range."
        case let .nonIntegralStepValue(value):
            return "Step endpoint \(value) must be a whole number."
        case let .emptyPromptVariant(index):
            return "Prompt variant \(index + 1) is empty."
        case .promptTemplateTooLong:
            return "The prompt-variant template exceeds the recipe prompt limit."
        case let .invalidCanvas(width, height):
            return "Canvas \(width)×\(height) must be 256...2048 pixels in multiples of 16."
        case let .duplicateValues(parameter):
            return "\(parameter.title) produced duplicate values; reduce or change the values."
        case let .jobLimitExceeded(actual, maximum):
            return "This grid would create \(actual) jobs; the Queue Lab limit is \(maximum)."
        }
    }
}

private extension QueueLab {
    struct Plan {
        let seeds: [UInt64]
        let xValues: [ParameterValue]
        let yValues: [ParameterValue]
        let jobCount: Int
    }

    static func preview(
        for recipe: GenerationRecipe,
        configuration: Configuration,
        context: ExperimentContext
    ) throws -> Preview {
        let plan = try plan(for: recipe, configuration: configuration)
        let xSlots: [ParameterValue?] = plan.xValues.isEmpty
            ? [nil]
            : plan.xValues.map(Optional.some)
        let ySlots: [ParameterValue?] = plan.yValues.isEmpty
            ? [nil]
            : plan.yValues.map(Optional.some)
        var entries: [PreviewEntry] = []
        entries.reserveCapacity(plan.jobCount)

        for (seedIndex, seed) in plan.seeds.enumerated() {
            for (yIndex, yValue) in ySlots.enumerated() {
                for (xIndex, xValue) in xSlots.enumerated() {
                    var output = recipe
                    output.sampler.seed = .fixed(seed)
                    if let xValue { apply(xValue, to: &output) }
                    if let yValue { apply(yValue, to: &output) }
                    do {
                        try output.validate(for: .request)
                    } catch {
                        throw ValidationError.invalidBaseRecipe(String(describing: error))
                    }
                    entries.append(PreviewEntry(
                        index: entries.count,
                        seedIndex: seedIndex,
                        xIndex: xIndex,
                        yIndex: yIndex,
                        seed: seed,
                        xValue: xValue,
                        yValue: yValue,
                        recipe: output))
                }
            }
        }

        return Preview(
            entries: entries,
            seeds: plan.seeds,
            xValues: plan.xValues,
            yValues: plan.yValues,
            context: context)
    }

    static func plan(
        for recipe: GenerationRecipe,
        configuration: Configuration
    ) throws -> Plan {
        do {
            try recipe.validate(for: .request)
        } catch {
            throw ValidationError.invalidBaseRecipe(String(describing: error))
        }
        guard (1 ... maximumJobCount).contains(configuration.seedCount) else {
            throw ValidationError.invalidSeedCount(configuration.seedCount)
        }
        if let x = configuration.xAxis.parameter,
           sameParameter(
               configuration.xAxis,
               configuration.yAxis,
               in: recipe) {
            throw ValidationError.duplicateParameters(x)
        }

        let xValues = try values(for: configuration.xAxis, recipe: recipe)
        let yValues = try values(for: configuration.yAxis, recipe: recipe)
        let xCount = max(1, xValues.count)
        let yCount = max(1, yValues.count)
        let (sweepCount, sweepOverflow) = xCount.multipliedReportingOverflow(by: yCount)
        let (jobCount, jobOverflow) = configuration.seedCount
            .multipliedReportingOverflow(by: sweepCount)
        guard !sweepOverflow, !jobOverflow, jobCount <= maximumJobCount else {
            let actual = sweepOverflow || jobOverflow ? Int.max : jobCount
            throw ValidationError.jobLimitExceeded(
                actual: actual,
                maximum: maximumJobCount)
        }

        var seeds: [UInt64] = []
        seeds.reserveCapacity(configuration.seedCount)
        for offset in 0 ..< configuration.seedCount {
            let (seed, overflow) = configuration.seedStart
                .addingReportingOverflow(UInt64(offset))
            guard !overflow else { throw ValidationError.seedRangeOverflow }
            seeds.append(seed)
        }
        return Plan(
            seeds: seeds,
            xValues: xValues,
            yValues: yValues,
            jobCount: jobCount)
    }

    static func sameParameter(
        _ lhs: Axis,
        _ rhs: Axis,
        in recipe: GenerationRecipe
    ) -> Bool {
        guard lhs.parameter == rhs.parameter, let parameter = lhs.parameter else { return false }
        guard parameter == .firstLoRAScale else { return true }
        return resolvedLoRAID(for: lhs, in: recipe) == resolvedLoRAID(for: rhs, in: recipe)
    }

    static func values(
        for axis: Axis,
        recipe: GenerationRecipe
    ) throws -> [ParameterValue] {
        guard let parameter = axis.parameter else { return [] }
        guard availableParameters(for: recipe).contains(parameter) else {
            throw ValidationError.unavailableParameter(parameter)
        }

        switch parameter {
        case .promptVariants:
            guard axis.promptTemplate.utf8.count <= GenerationRecipe.maximumPromptUTF8Bytes else {
                throw ValidationError.promptTemplateTooLong
            }
            let expansion = expandWildcards(axis.promptTemplate, cap: maximumJobCount)
            if expansion.truncated {
                throw ValidationError.jobLimitExceeded(
                    actual: expansion.totalCombinations,
                    maximum: maximumJobCount)
            }
            for (index, prompt) in expansion.prompts.enumerated()
                where prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.emptyPromptVariant(index)
            }
            let values = expansion.prompts.map(ParameterValue.init(prompt:))
            guard Set(values).count == values.count else {
                throw ValidationError.duplicateValues(parameter)
            }
            return values

        case .canvasSize:
            guard (1 ... maximumJobCount).contains(axis.canvasSizes.count) else {
                throw ValidationError.invalidValueCount(
                    parameter: parameter,
                    count: axis.canvasSizes.count)
            }
            for canvas in axis.canvasSizes {
                guard validDimension(canvas.width), validDimension(canvas.height) else {
                    throw ValidationError.invalidCanvas(
                        width: canvas.width,
                        height: canvas.height)
                }
            }
            let values = axis.canvasSizes.map(ParameterValue.init(canvas:))
            guard Set(values).count == values.count else {
                throw ValidationError.duplicateValues(parameter)
            }
            return values

        case .steps, .guidance, .imageToImageStrength, .firstLoRAScale:
            guard (1 ... maximumJobCount).contains(axis.valueCount) else {
                throw ValidationError.invalidValueCount(
                    parameter: parameter,
                    count: axis.valueCount)
            }
            guard axis.start.isFinite, axis.end.isFinite else {
                throw ValidationError.nonFiniteValue(parameter: parameter)
            }
            try validateEndpoint(axis.start, for: parameter)
            try validateEndpoint(axis.end, for: parameter)

            let loRAID: UUID?
            if parameter == .firstLoRAScale {
                guard let selected = resolvedLoRAID(for: axis, in: recipe),
                      recipe.loras.contains(where: { $0.managedID == selected }) else {
                    throw ValidationError.unavailableLoRA(axis.loRAID ?? UUID.zero)
                }
                loRAID = selected
            } else {
                loRAID = nil
            }

            let values = (0 ..< axis.valueCount).map { index -> ParameterValue in
                let fraction = axis.valueCount == 1
                    ? 0
                    : Double(index) / Double(axis.valueCount - 1)
                let interpolated = axis.start + (axis.end - axis.start) * fraction
                let value: Double
                switch parameter {
                case .steps:
                    value = interpolated.rounded(.toNearestOrAwayFromZero)
                case .guidance, .imageToImageStrength, .firstLoRAScale:
                    value = roundedSweepValue(interpolated)
                case .promptVariants, .canvasSize:
                    preconditionFailure("Discrete Queue Lab parameters do not interpolate")
                }
                return ParameterValue(parameter: parameter, value: value, loRAID: loRAID)
            }
            guard Set(values).count == values.count else {
                throw ValidationError.duplicateValues(parameter)
            }
            for value in values.compactMap(\.value) {
                try validateEndpoint(value, for: parameter)
            }
            return values
        }
    }

    static func validateEndpoint(
        _ value: Double,
        for parameter: Parameter
    ) throws {
        switch parameter {
        case .steps:
            guard value.rounded() == value else {
                throw ValidationError.nonIntegralStepValue(value)
            }
            guard value >= Double(minimumTurboSteps),
                  value <= Double(maximumTurboSteps) else {
                throw ValidationError.outOfBounds(parameter: parameter, value: value)
            }
        case .guidance:
            guard value >= 0, value <= GenerationRecipe.maximumGuidance else {
                throw ValidationError.outOfBounds(parameter: parameter, value: value)
            }
        case .imageToImageStrength:
            guard value >= minimumStrength, value <= 1 else {
                throw ValidationError.outOfBounds(parameter: parameter, value: value)
            }
        case .firstLoRAScale:
            guard value >= minimumStrength, value <= GenerationRecipe.maximumLoRAScale else {
                throw ValidationError.outOfBounds(parameter: parameter, value: value)
            }
        case .promptVariants, .canvasSize:
            break
        }
    }

    static func roundedSweepValue(_ value: Double) -> Double {
        (value * 1_000_000).rounded(.toNearestOrAwayFromZero) / 1_000_000
    }

    static func apply(
        _ value: ParameterValue,
        to recipe: inout GenerationRecipe
    ) {
        switch value.parameter {
        case .promptVariants:
            guard let prompt = value.prompt else { return }
            recipe.prompts.positive = prompt
        case .canvasSize:
            guard let canvas = value.canvas else { return }
            recipe.canvas = canvas
        case .steps:
            guard let numeric = value.value else { return }
            recipe.sampler.steps = Int(numeric)
        case .guidance:
            guard let numeric = value.value else { return }
            recipe.sampler.guidance = numeric
        case .imageToImageStrength:
            guard let numeric = value.value else { return }
            recipe.inputImage?.strength = numeric
        case .firstLoRAScale:
            guard let numeric = value.value,
                  let id = value.loRAID,
                  let index = recipe.loras.firstIndex(where: { $0.managedID == id }) else { return }
            recipe.loras[index].scale = numeric
        }
    }

    static func resolvedLoRAID(
        for axis: Axis,
        in recipe: GenerationRecipe
    ) -> UUID? {
        axis.loRAID ?? recipe.loras.first?.managedID
    }

    static func validDimension(_ value: Int) -> Bool {
        (GenerationRecipe.minimumDimension ... GenerationRecipe.maximumDimension).contains(value)
            && value.isMultiple(of: GenerationRecipe.dimensionMultiple)
    }

    static func unique<T: Hashable>(_ values: some Sequence<T>) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
