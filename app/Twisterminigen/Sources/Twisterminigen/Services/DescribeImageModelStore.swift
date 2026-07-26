import Foundation

protocol DescribeImageModelManaging: Sendable {
    func status() async -> ComponentStatus
    func install(onProgress: @escaping ModelDownloadProgress) async throws
    func remove() async -> Int64
}

enum DescribeImageModelStoreError: LocalizedError {
    case invalidCatalog

    var errorDescription: String? {
        "The Describe Image model catalog is invalid."
    }
}

/// A narrow facade over the existing verified/resumable model store. Keeping this as a separate
/// actor prevents the optional assistant from being mistaken for a required render component.
actor DescribeImageModelStore: DescribeImageModelManaging {
    private let store: ModelStore

    init(
        catalog: ModelCatalog = DescribeImageModel.catalog(),
        downloader: @escaping ModelDownloadOperation = { component, onProgress in
            try await ResumableDownloader.download(component: component, onProgress: onProgress)
        },
        capacityLookup: @escaping ModelDiskCapacityLookup = {
            ModelDiskCapacity.importantUsageCapacity(for: $0)
        },
        diskSafetyMarginBytes: Int64 = ModelStore.defaultDiskSafetyMarginBytes
    ) {
        store = ModelStore(
            catalog: catalog,
            downloader: downloader,
            capacityLookup: capacityLookup,
            diskSafetyMarginBytes: diskSafetyMarginBytes)
    }

    func status() async -> ComponentStatus {
        if let status = await store.status(id: DescribeImageModel.componentID) {
            return status
        }
        return ComponentStatus(
            id: DescribeImageModel.componentID,
            title: DescribeImageModel.title,
            subtitle: "Invalid local catalog",
            icon: "exclamationmark.triangle",
            expectedBytes: 0,
            onDiskBytes: 0,
            state: .corrupted)
    }

    func install(onProgress: @escaping ModelDownloadProgress) async throws {
        try await store.download(id: DescribeImageModel.componentID, onProgress: onProgress)
    }

    func remove() async -> Int64 {
        await store.delete(id: DescribeImageModel.componentID)
    }
}
