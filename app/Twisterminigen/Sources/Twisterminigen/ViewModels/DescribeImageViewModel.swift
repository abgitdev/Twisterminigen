import Foundation
import Observation

@MainActor
@Observable
final class DescribeImageViewModel {
    enum Activity: Equatable {
        case idle
        case installing
        case removing
        case describing
    }

    private(set) var modelStatus: ComponentStatus?
    private(set) var activity: Activity = .idle
    private(set) var progressFraction: Double?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    /// Editable draft: Describe proposes text, but the user remains in control before applying it.
    var descriptionText = ""
    var selectedImageURL: URL? {
        didSet {
            guard selectedImageURL != oldValue else { return }
            descriptionText = ""
            errorMessage = nil
            statusMessage = nil
        }
    }

    @ObservationIgnored private let coordinator: InferenceCoordinator
    @ObservationIgnored private let service: DescribeImageService
    @ObservationIgnored private let modelManager: any DescribeImageModelManaging
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?

    init(
        coordinator: InferenceCoordinator,
        backend: any DescribeImageBackend = MLXDescribeImageBackend(),
        modelManager: any DescribeImageModelManaging = DescribeImageModelStore()
    ) {
        self.coordinator = coordinator
        self.service = DescribeImageService(coordinator: coordinator, backend: backend)
        self.modelManager = modelManager
    }

    var modelIsInstalled: Bool { modelStatus?.state == .downloaded }
    var isBusy: Bool { activity != .idle }
    var canDescribe: Bool {
        activity == .idle && modelIsInstalled && selectedImageURL != nil
            && coordinator.canStartInference
    }

    func refreshModelStatus() async {
        modelStatus = await modelManager.status()
    }

    func selectImage(_ url: URL) {
        guard activity == .idle else { return }
        selectedImageURL = url
    }

    func startInstall() {
        start(.installing) { [weak self] id in
            await self?.performInstall(operationID: id)
        }
    }

    func startRemove() {
        start(.removing) { [weak self] id in
            await self?.performRemove(operationID: id)
        }
    }

    func startDescribe() {
        start(.describing) { [weak self] id in
            await self?.performDescribe(operationID: id)
        }
    }

    func cancel() {
        guard activity != .idle else { return }
        if activity == .describing { service.cancel() }
        task?.cancel()
        statusMessage = "Stopping…"
    }

    /// Async entry points make the orchestration deterministic in tests. Production UI normally
    /// calls the `start…` wrappers so Cancel owns the task.
    func installAndWait() async {
        guard activity == .idle else { return }
        let id = begin(.installing)
        await performInstall(operationID: id)
    }

    func removeAndWait() async {
        guard activity == .idle else { return }
        let id = begin(.removing)
        await performRemove(operationID: id)
    }

    func describeAndWait() async {
        guard activity == .idle else { return }
        let id = begin(.describing)
        await performDescribe(operationID: id)
    }

    private func start(
        _ requestedActivity: Activity,
        operation: @escaping @MainActor (UUID) async -> Void
    ) {
        guard activity == .idle else { return }
        let id = begin(requestedActivity)
        task = Task { [weak self] in
            await operation(id)
            guard let self, self.operationID == id else { return }
            self.task = nil
        }
    }

    private func begin(_ requestedActivity: Activity) -> UUID {
        let id = UUID()
        operationID = id
        activity = requestedActivity
        progressFraction = nil
        statusMessage = nil
        errorMessage = nil
        return id
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        activity = .idle
        progressFraction = nil
        task = nil
    }

    private func performInstall(operationID id: UUID) async {
        guard let lease = coordinator.beginModelMutation(key: DescribeImageModel.componentID) else {
            errorMessage = modelMutationBusyMessage()
            finish(id)
            return
        }
        defer { coordinator.finishModelMutation(lease) }
        statusMessage = "Preparing download…"
        do {
            try await modelManager.install { [weak self] fraction, message in
                Task { @MainActor in
                    guard let self, self.operationID == id else { return }
                    self.progressFraction = min(1, max(0, fraction))
                    self.statusMessage = message
                }
            }
            modelStatus = await modelManager.status()
            statusMessage = "Installed"
        } catch is CancellationError {
            modelStatus = await modelManager.status()
            statusMessage = "Download paused"
        } catch {
            modelStatus = await modelManager.status()
            errorMessage = error.localizedDescription
        }
        finish(id)
    }

    private func performRemove(operationID id: UUID) async {
        guard let lease = coordinator.beginModelMutation(key: DescribeImageModel.componentID) else {
            errorMessage = modelMutationBusyMessage()
            finish(id)
            return
        }
        defer { coordinator.finishModelMutation(lease) }
        statusMessage = "Removing model…"
        _ = await modelManager.remove()
        modelStatus = await modelManager.status()
        descriptionText = ""
        finish(id)
    }

    private func performDescribe(operationID id: UUID) async {
        guard let imageURL = selectedImageURL else {
            errorMessage = "Choose an image first."
            finish(id)
            return
        }
        guard modelIsInstalled else {
            errorMessage = DescribeImageError.modelNotInstalled.localizedDescription
            finish(id)
            return
        }

        do {
            let result = try await service.describe(imageURL: imageURL) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.operationID == id else { return }
                    self.statusMessage = progress.message
                }
            }
            guard operationID == id else { return }
            descriptionText = result
            statusMessage = "Description ready"
        } catch is CancellationError {
            statusMessage = "Cancelled"
        } catch {
            errorMessage = error.localizedDescription
        }
        finish(id)
    }

    private func modelMutationBusyMessage() -> String {
        if coordinator.isTerminationRequested {
            return "Can't change the Describe Image model while Twisterminigen is preparing to quit."
        }
        return "Can't change the Describe Image model while another model or inference operation is active."
    }
}
