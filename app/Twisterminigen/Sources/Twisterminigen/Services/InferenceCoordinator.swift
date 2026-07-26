import Foundation
import Observation

/// Process-wide ownership and UI state for memory-heavy MLX work.
///
/// Every inference entry point must hold a lease until its detached task has fully stopped. A
/// lease id prevents a late callback from an old task from releasing or changing a newer run.
@MainActor
@Observable
final class InferenceCoordinator {
    enum Operation: String, Equatable, Sendable {
        case generate
        case queue
        case enhance
        case upscale
        case describe

        var title: String {
            switch self {
            case .generate: return "generation"
            case .queue: return "queue"
            case .enhance: return "prompt enhancement"
            case .upscale: return "local 4× upscaling"
            case .describe: return "image description"
            }
        }
    }

    enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case enhancing
        case describing
        case encodingPrompt
        case encodingImage
        case loadingTransformer
        case denoising(step: Int, total: Int)
        case decoding
        case saving
        case stopping
        case failed(String)
    }

    struct Lease: Equatable, Sendable {
        fileprivate let id: UUID
        let operation: Operation
    }

    struct ModelMutationLease: Equatable, Sendable {
        fileprivate let id: UUID
        let key: String
    }

    struct WorkItem: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let leaseID: UUID
    }

    private(set) var phase: Phase = .idle
    private(set) var activeOperation: Operation?
    private var activeLeaseID: UUID?
    private var activeWorkItemID: UUID?
    private var modelMutations: [UUID: String] = [:]
    private var modelChangeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var isTerminationRequested = false

    var isBusy: Bool { activeLeaseID != nil }
    var isChangingModels: Bool { !modelMutations.isEmpty }
    /// Graceful process teardown must wait until both MLX work and transactional file mutations
    /// have released their leases.
    var blocksApplicationTermination: Bool { isBusy || isChangingModels }
    var canStartInference: Bool { !isTerminationRequested && !isBusy && !isChangingModels }
    var canChangeModels: Bool { !isTerminationRequested && !isBusy }

    var statusText: String {
        switch phase {
        case .idle: return "ready"
        case .preparing: return "preparing..."
        case .enhancing: return "enhancing prompt..."
        case .describing: return "reading image..."
        case .encodingPrompt: return "encoding prompt..."
        case .encodingImage: return "encoding source..."
        case .loadingTransformer: return "loading transformer..."
        case let .denoising(step, total):
            return total > 0 ? "step \(step)/\(total)" : "starting denoise..."
        case .decoding: return "decoding image..."
        case .saving: return "saving..."
        case .stopping: return "stopping after current Metal operation..."
        case .failed: return "failed"
        }
    }

    @discardableResult
    func begin(_ operation: Operation) -> Lease? {
        guard canStartInference else { return nil }
        let lease = Lease(id: UUID(), operation: operation)
        activeLeaseID = lease.id
        activeOperation = operation
        switch operation {
        case .enhance: phase = .enhancing
        case .describe: phase = .describing
        case .generate, .queue, .upscale: phase = .preparing
        }
        return lease
    }

    /// Closes admission before cooperative cancellation starts. Existing leases may finish at a
    /// safe boundary, but no render, enhancement, download, import, or model mutation can race the
    /// pending process termination.
    func requestApplicationTermination() {
        isTerminationRequested = true
        resumeModelChangeWaiters()
    }

    /// Used only if an outer AppKit termination attempt is cancelled before teardown begins.
    func cancelApplicationTerminationRequest() {
        isTerminationRequested = false
        resumeModelChangeWaiters()
    }

    func isActive(_ lease: Lease) -> Bool {
        activeLeaseID == lease.id
    }

    func isActive(_ workItem: WorkItem, lease: Lease) -> Bool {
        isActive(lease) && workItem.leaseID == lease.id && activeWorkItemID == workItem.id
    }

    func beginWorkItem(_ lease: Lease) -> WorkItem? {
        guard isActive(lease), phase != .stopping else { return nil }
        let item = WorkItem(id: UUID(), leaseID: lease.id)
        activeWorkItemID = item.id
        phase = .preparing
        return item
    }

    /// Retires one completed item without releasing the enclosing Queue/Generate lease. Late
    /// unstructured progress callbacks from that item are rejected before another item begins.
    func finishWorkItem(_ workItem: WorkItem, lease: Lease) {
        guard isActive(workItem, lease: lease) else { return }
        activeWorkItemID = nil
    }

    func transition(to phase: Phase, lease: Lease, workItem: WorkItem) {
        guard isActive(workItem, lease: lease) else { return }
        guard self.phase != .stopping else { return }
        guard Self.stage(of: phase) >= Self.stage(of: self.phase) else { return }
        if case let .denoising(currentStep, _) = self.phase,
           case let .denoising(nextStep, _) = phase,
           nextStep < currentStep {
            return
        }
        self.phase = phase
    }

    /// Planned sessions reuse one lease for several resident-sequential images. A new image may
    /// legitimately restart denoising at step zero after the prior image reached its final step.
    func beginDenoisingItem(
        total: Int,
        lease: Lease,
        workItem: WorkItem
    ) {
        guard isActive(workItem, lease: lease), phase != .stopping else { return }
        phase = .denoising(step: 0, total: max(0, total))
    }

    func markStopping(_ lease: Lease) {
        guard isActive(lease) else { return }
        phase = .stopping
    }

    func finish(_ lease: Lease) {
        guard isActive(lease) else { return }
        activeLeaseID = nil
        activeWorkItemID = nil
        activeOperation = nil
        phase = .idle
        resumeModelChangeWaiters()
    }

    func fail(_ message: String, lease: Lease) {
        guard isActive(lease) else { return }
        activeLeaseID = nil
        activeWorkItemID = nil
        activeOperation = nil
        phase = .failed(message)
        resumeModelChangeWaiters()
    }

    /// Suspends a user-requested file mutation without polling while inference owns the process.
    /// The caller must still acquire a model-mutation lease immediately after this returns.
    /// A pending application termination cancels the request instead of racing process teardown.
    func waitUntilModelChangesAreAllowed() async -> Bool {
        while isBusy {
            guard !isTerminationRequested else { return false }
            let waiterID = UUID()
            await withCheckedContinuation { continuation in
                modelChangeWaiters[waiterID] = continuation
            }
        }
        return !isTerminationRequested
    }

    @discardableResult
    func beginModelMutation(key: String) -> ModelMutationLease? {
        guard canChangeModels, !modelMutations.values.contains(key) else { return nil }
        let lease = ModelMutationLease(id: UUID(), key: key)
        modelMutations[lease.id] = key
        return lease
    }

    func finishModelMutation(_ lease: ModelMutationLease) {
        guard modelMutations[lease.id] == lease.key else { return }
        modelMutations[lease.id] = nil
    }

    func busyMessage(for requested: Operation) -> String {
        if isTerminationRequested {
            return "Can't start \(requested.title) while Twisterminigen is preparing to quit."
        }
        if isChangingModels {
            return "Can't start \(requested.title) while model files are changing."
        }
        let current = activeOperation?.title ?? "another MLX operation"
        return "Can't start \(requested.title) while \(current) is still running."
    }

    private func resumeModelChangeWaiters() {
        let continuations = Array(modelChangeWaiters.values)
        modelChangeWaiters.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }

    private static func stage(of phase: Phase) -> Int {
        switch phase {
        case .idle, .failed: return 0
        case .preparing, .enhancing, .describing: return 1
        case .encodingPrompt: return 2
        case .encodingImage: return 3
        case .loadingTransformer: return 4
        case .denoising: return 5
        case .decoding: return 6
        case .saving: return 7
        case .stopping: return 8
        }
    }
}
