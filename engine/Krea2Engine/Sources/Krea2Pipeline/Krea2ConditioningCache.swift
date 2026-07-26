import Foundation
import Krea2Core
import Krea2TextEncoder
import MLX

public enum Krea2HostTensorDType: String, Hashable, Sendable {
    case bfloat16
    case float32
    case int32

    public var bytesPerElement: Int {
        switch self {
        case .bfloat16: 2
        case .float32, .int32: 4
        }
    }

    fileprivate init?(mlxDType: DType) {
        switch mlxDType {
        case .bfloat16: self = .bfloat16
        case .float32: self = .float32
        case .int32: self = .int32
        default: return nil
        }
    }

    fileprivate var mlxDType: DType {
        switch self {
        case .bfloat16: .bfloat16
        case .float32: .float32
        case .int32: .int32
        }
    }
}

public enum Krea2ConditioningCacheError: Error, Equatable, Sendable {
    case unsupportedDType(String)
    case invalidShape([Int])
    case byteCountOverflow
    case byteCountMismatch(expected: Int, actual: Int)
    case invalidEmbeddingsDType(Krea2HostTensorDType)
    case invalidMaskDType(Krea2HostTensorDType)
    case invalidValidTokenCount(Int)
}

/// An owned, contiguous host copy of a tensor. It has no MLX or model lifetime.
public struct Krea2HostTensor: Equatable, Sendable {
    public let data: Data
    public let shape: [Int]
    public let dtype: Krea2HostTensorDType

    /// Copies even when `data` wraps external or no-copy storage.
    public init(data: Data, shape: [Int], dtype: Krea2HostTensorDType) {
        self.data = Self.independentCopy(of: data)
        self.shape = shape
        self.dtype = dtype
    }

    fileprivate init(independentData: Data, shape: [Int], dtype: Krea2HostTensorDType) {
        self.data = independentData
        self.shape = shape
        self.dtype = dtype
    }

    public var isWellFormed: Bool {
        (try? validatedByteCount()) != nil
    }

    /// Validates shape multiplication and the exact contiguous byte count.
    @discardableResult
    public func validatedByteCount() throws -> Int {
        let elements = try validatedElementCount()
        let (expected, overflow) = elements.multipliedReportingOverflow(by: dtype.bytesPerElement)
        guard !overflow else { throw Krea2ConditioningCacheError.byteCountOverflow }
        guard data.count == expected else {
            throw Krea2ConditioningCacheError.byteCountMismatch(
                expected: expected,
                actual: data.count
            )
        }
        return expected
    }

    fileprivate func validatedElementCount() throws -> Int {
        guard shape.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }) else {
            throw Krea2ConditioningCacheError.invalidShape(shape)
        }

        var count = 1
        for dimension in shape {
            let (next, overflow) = count.multipliedReportingOverflow(by: dimension)
            guard !overflow else { throw Krea2ConditioningCacheError.byteCountOverflow }
            count = next
        }
        return count
    }

    private static func independentCopy(of data: Data) -> Data {
        data.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress, !source.isEmpty else { return Data() }
            return Data(bytes: baseAddress, count: source.count)
        }
    }
}

/// Host representation of one text-encoder result.
public struct Krea2HostTextConditioning: Equatable, Sendable {
    public let embeddings: Krea2HostTensor
    public let mask: Krea2HostTensor
    public let validTokenCount: Int

    public init(
        embeddings: Krea2HostTensor,
        mask: Krea2HostTensor,
        validTokenCount: Int
    ) {
        self.embeddings = embeddings
        self.mask = mask
        self.validTokenCount = validTokenCount
    }

    public var isWellFormed: Bool {
        (try? validatedByteCount()) != nil
    }

    @discardableResult
    public func validatedByteCount() throws -> Int {
        guard embeddings.dtype == .bfloat16 || embeddings.dtype == .float32 else {
            throw Krea2ConditioningCacheError.invalidEmbeddingsDType(embeddings.dtype)
        }
        guard mask.dtype == .int32 else {
            throw Krea2ConditioningCacheError.invalidMaskDType(mask.dtype)
        }

        let embeddingsBytes = try embeddings.validatedByteCount()
        let maskBytes = try mask.validatedByteCount()
        let maskElements = try mask.validatedElementCount()
        guard validTokenCount >= 0, validTokenCount <= maskElements else {
            throw Krea2ConditioningCacheError.invalidValidTokenCount(validTokenCount)
        }

        let (total, overflow) = embeddingsBytes.addingReportingOverflow(maskBytes)
        guard !overflow else { throw Krea2ConditioningCacheError.byteCountOverflow }
        return total
    }
}

/// A complete cache value. Negative conditioning is present only for modes that need it.
public struct Krea2HostConditioning: Equatable, Sendable {
    public let positive: Krea2HostTextConditioning
    public let negative: Krea2HostTextConditioning?

    public init(
        positive: Krea2HostTextConditioning,
        negative: Krea2HostTextConditioning? = nil
    ) {
        self.positive = positive
        self.negative = negative
    }

    public var isWellFormed: Bool {
        (try? validatedByteCount()) != nil
    }

    @discardableResult
    public func validatedByteCount() throws -> Int {
        let positiveBytes = try positive.validatedByteCount()
        guard let negative else { return positiveBytes }
        let negativeBytes = try negative.validatedByteCount()
        let (total, overflow) = positiveBytes.addingReportingOverflow(negativeBytes)
        guard !overflow else { throw Krea2ConditioningCacheError.byteCountOverflow }
        return total
    }
}

/// Exact identity of every input that can change text conditioning.
/// Render-only seed, resolution, and step count are intentionally not representable.
public struct Krea2ConditioningCacheKey: Hashable, Sendable {
    public static let currentSchema: UInt32 = 1

    public enum CFGBranch: String, Hashable, Sendable {
        case positive
        case negative
        case positiveAndNegative
    }

    public enum GuidanceMode: String, Hashable, Sendable {
        case disabled
        case classifierFree
    }

    /// Bbox values are stored by bit pattern so signed zero and every finite value stay exact.
    public struct RegionIdentity: Hashable, Sendable {
        public let prompt: String
        public let x0BitPattern: UInt64
        public let y0BitPattern: UInt64
        public let x1BitPattern: UInt64
        public let y1BitPattern: UInt64

        public init(prompt: String, x0: Double, y0: Double, x1: Double, y1: Double) {
            self.prompt = prompt
            self.x0BitPattern = x0.bitPattern
            self.y0BitPattern = y0.bitPattern
            self.x1BitPattern = x1.bitPattern
            self.y1BitPattern = y1.bitPattern
        }

        public init(prompt: String, bbox: Krea2RegionBBox) {
            self.init(
                prompt: prompt,
                x0: bbox.x0,
                y0: bbox.y0,
                x1: bbox.x1,
                y1: bbox.y1
            )
        }

        public init(region: Krea2Region) {
            self.init(prompt: region.prompt, bbox: region.bbox)
        }
    }

    public let schema: UInt32
    public let verifiedModelIdentity: String
    public let canonicalModelRoot: String
    public let positivePrompt: String
    public let negativePrompt: String?
    public let cfgBranch: CFGBranch
    public let guidanceMode: GuidanceMode
    public let templateIdentity: String
    public let maxLength: Int
    public let selectLayers: [Int]
    public let dtypeIdentity: Krea2HostTensorDType
    /// Ordered identity must include each adapter's verified identity and effective scale.
    public let orderedLoRAIdentity: String
    /// Region order is semantic and is therefore preserved.
    public let regionalPromptBBoxIdentity: [RegionIdentity]

    public init(
        schema: UInt32 = Krea2ConditioningCacheKey.currentSchema,
        verifiedModelIdentity: String,
        canonicalModelRoot: String,
        positivePrompt: String,
        negativePrompt: String?,
        cfgBranch: CFGBranch,
        guidanceMode: GuidanceMode,
        templateIdentity: String,
        maxLength: Int,
        selectLayers: [Int],
        dtypeIdentity: Krea2HostTensorDType,
        orderedLoRAIdentity: String,
        regionalPromptBBoxIdentity: [RegionIdentity]
    ) {
        self.schema = schema
        self.verifiedModelIdentity = verifiedModelIdentity
        self.canonicalModelRoot = Self.canonicalizeModelRoot(canonicalModelRoot)
        self.positivePrompt = positivePrompt
        self.negativePrompt = negativePrompt
        self.cfgBranch = cfgBranch
        self.guidanceMode = guidanceMode
        self.templateIdentity = templateIdentity
        self.maxLength = maxLength
        self.selectLayers = selectLayers
        self.dtypeIdentity = dtypeIdentity
        self.orderedLoRAIdentity = orderedLoRAIdentity
        self.regionalPromptBBoxIdentity = regionalPromptBBoxIdentity
    }

    public static func canonicalModelRoot(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func canonicalizeModelRoot(_ path: String) -> String {
        canonicalModelRoot(for: URL(fileURLWithPath: path))
    }
}

/// Live MLX values returned only to the serialized inference task.
public struct Krea2InferenceTextConditioning {
    public let embeddings: MLXArray
    public let mask: MLXArray
    public let validTokenCount: Int
}

/// Live positive/negative MLX values returned only to the serialized inference task.
public struct Krea2InferenceConditioning {
    public let positive: Krea2InferenceTextConditioning
    public let negative: Krea2InferenceTextConditioning?
}

/// Synchronous transfer helpers for use inside the serialized inference task only.
/// The cache actor must receive the host result, never either MLX-bearing input or output.
public enum Krea2ConditioningHostTransfer {
    public static func copyFromInferenceTask(
        _ conditioning: Krea2InferenceTextConditioning
    ) throws -> Krea2HostTextConditioning {
        try Task.checkCancellation()
        let embeddings = try copyToHost(conditioning.embeddings)
        try Task.checkCancellation()
        let mask = try copyToHost(conditioning.mask)
        try Task.checkCancellation()

        let host = Krea2HostTextConditioning(
            embeddings: embeddings,
            mask: mask,
            validTokenCount: conditioning.validTokenCount)
        _ = try host.validatedByteCount()
        return host
    }

    public static func copyFromInferenceTask(
        _ conditioning: Krea2TextConditioning
    ) throws -> Krea2HostTextConditioning {
        try Task.checkCancellation()
        let embeddings = try copyToHost(conditioning.embeddings)
        try Task.checkCancellation()
        let mask = try copyToHost(conditioning.mask)
        try Task.checkCancellation()

        let host = Krea2HostTextConditioning(
            embeddings: embeddings,
            mask: mask,
            validTokenCount: conditioning.validTokenCount
        )
        _ = try host.validatedByteCount()
        return host
    }

    public static func copyFromInferenceTask(
        positive: Krea2TextConditioning,
        negative: Krea2TextConditioning? = nil
    ) throws -> Krea2HostConditioning {
        let positiveHost = try copyFromInferenceTask(positive)
        let negativeHost = try negative.map { try copyFromInferenceTask($0) }
        try Task.checkCancellation()

        let host = Krea2HostConditioning(positive: positiveHost, negative: negativeHost)
        _ = try host.validatedByteCount()
        return host
    }

    public static func copyFromInferenceTask(
        positive: Krea2InferenceTextConditioning,
        negative: Krea2InferenceTextConditioning? = nil
    ) throws -> Krea2HostConditioning {
        let positiveHost = try copyFromInferenceTask(positive)
        let negativeHost = try negative.map { try copyFromInferenceTask($0) }
        try Task.checkCancellation()

        let host = Krea2HostConditioning(positive: positiveHost, negative: negativeHost)
        _ = try host.validatedByteCount()
        return host
    }

    /// Every call constructs new MLX arrays after revalidating shape and byte count.
    public static func restoreForInferenceTask(
        _ host: Krea2HostTextConditioning
    ) throws -> Krea2InferenceTextConditioning {
        _ = try host.validatedByteCount()
        try Task.checkCancellation()
        let embeddings = MLXArray(
            host.embeddings.data,
            host.embeddings.shape,
            dtype: host.embeddings.dtype.mlxDType
        )
        try Task.checkCancellation()
        let mask = MLXArray(host.mask.data, host.mask.shape, dtype: host.mask.dtype.mlxDType)
        try Task.checkCancellation()
        return Krea2InferenceTextConditioning(
            embeddings: embeddings,
            mask: mask,
            validTokenCount: host.validTokenCount
        )
    }

    /// Every call constructs a fresh positive/negative MLX object graph.
    public static func restoreForInferenceTask(
        _ host: Krea2HostConditioning
    ) throws -> Krea2InferenceConditioning {
        _ = try host.validatedByteCount()
        let positive = try restoreForInferenceTask(host.positive)
        let negative = try host.negative.map { try restoreForInferenceTask($0) }
        try Task.checkCancellation()
        return Krea2InferenceConditioning(positive: positive, negative: negative)
    }

    private static func copyToHost(_ array: MLXArray) throws -> Krea2HostTensor {
        let copied = array.asData(access: .copy)
        guard let dtype = Krea2HostTensorDType(mlxDType: copied.dType) else {
            throw Krea2ConditioningCacheError.unsupportedDType(String(describing: copied.dType))
        }
        let host = Krea2HostTensor(
            independentData: copied.data,
            shape: copied.shape,
            dtype: dtype
        )
        _ = try host.validatedByteCount()
        return host
    }
}

/// Actor-isolated, byte- and count-bounded LRU containing host values only.
public actor Krea2ConditioningCache {
    public static let defaultByteBudget = 128 * 1_024 * 1_024
    public static let defaultMaxEntries = 4

    public enum PressurePolicy: String, Equatable, Sendable {
        case normal
        case amber
        case red
    }

    public enum InsertionResult: Equatable, Sendable {
        case inserted
        case replaced
        case insertionSuspended
        case exceedsByteBudget
    }

    public struct Snapshot: Equatable, Sendable {
        public let count: Int
        public let byteCount: Int
        public let byteBudget: Int
        public let maxEntries: Int
        public let pressure: PressurePolicy
        public let insertionSuspended: Bool
    }

    private struct Entry: Sendable {
        let value: Krea2HostConditioning
        let byteCount: Int
    }

    public nonisolated let byteBudget: Int
    public nonisolated let maxEntries: Int

    private var entries: [Krea2ConditioningCacheKey: Entry] = [:]
    private var lruOrder: [Krea2ConditioningCacheKey] = []
    private var totalByteCount = 0
    private var pressure: PressurePolicy = .normal

    public init(
        byteBudget: Int = Krea2ConditioningCache.defaultByteBudget,
        maxEntries: Int = Krea2ConditioningCache.defaultMaxEntries
    ) {
        precondition(byteBudget >= 0, "Conditioning cache byte budget must not be negative")
        precondition(maxEntries > 0, "Conditioning cache must allow at least one entry")
        self.byteBudget = byteBudget
        self.maxEntries = maxEntries
    }

    public var count: Int { entries.count }
    public var byteCount: Int { totalByteCount }
    public var pressurePolicy: PressurePolicy { pressure }
    public var insertionSuspended: Bool { pressure != .normal }

    /// Returns and promotes a validated host value. Corrupt entries are removed, never returned.
    public func value(for key: Krea2ConditioningCacheKey) -> Krea2HostConditioning? {
        guard let entry = entries[key] else { return nil }
        do {
            let validatedBytes = try entry.value.validatedByteCount()
            guard validatedBytes == entry.byteCount else {
                removeEntry(for: key)
                return nil
            }
        } catch {
            removeEntry(for: key)
            return nil
        }

        promote(key)
        return entry.value
    }

    /// A cancelled or malformed task throws before mutation. Oversized/suspended writes are no-ops.
    @discardableResult
    public func insert(
        _ value: Krea2HostConditioning,
        for key: Krea2ConditioningCacheKey
    ) throws -> InsertionResult {
        try Task.checkCancellation()
        let newByteCount = try value.validatedByteCount()
        try Task.checkCancellation()

        guard pressure == .normal else { return .insertionSuspended }
        guard newByteCount <= byteBudget else { return .exceedsByteBudget }

        let replaced = removeEntry(for: key) != nil
        entries[key] = Entry(value: value, byteCount: newByteCount)
        lruOrder.append(key)
        totalByteCount += newByteCount
        trimToLimits()
        return replaced ? .replaced : .inserted
    }

    /// Amber keeps only the most recently used entry; red removes every entry.
    /// Both suspend insertion until policy returns to normal.
    public func setPressure(_ newPressure: PressurePolicy) {
        pressure = newPressure
        switch newPressure {
        case .normal:
            break
        case .amber:
            trim(toCount: 1)
        case .red:
            invalidateAll()
        }
    }

    public func invalidateAll() {
        entries.removeAll(keepingCapacity: true)
        lruOrder.removeAll(keepingCapacity: true)
        totalByteCount = 0
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            count: entries.count,
            byteCount: totalByteCount,
            byteBudget: byteBudget,
            maxEntries: maxEntries,
            pressure: pressure,
            insertionSuspended: pressure != .normal
        )
    }

    private func promote(_ key: Krea2ConditioningCacheKey) {
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    @discardableResult
    private func removeEntry(for key: Krea2ConditioningCacheKey) -> Entry? {
        guard let removed = entries.removeValue(forKey: key) else { return nil }
        lruOrder.removeAll { $0 == key }
        totalByteCount -= removed.byteCount
        return removed
    }

    private func trimToLimits() {
        while entries.count > maxEntries || totalByteCount > byteBudget {
            guard let leastRecent = lruOrder.first else {
                invalidateAll()
                return
            }
            removeEntry(for: leastRecent)
        }
    }

    private func trim(toCount targetCount: Int) {
        while entries.count > targetCount {
            guard let leastRecent = lruOrder.first else {
                invalidateAll()
                return
            }
            removeEntry(for: leastRecent)
        }
    }
}
