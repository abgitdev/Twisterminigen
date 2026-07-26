import AppKit
import UniformTypeIdentifiers

enum CleanPNGItemProvider {
    static func make(
        suggestedName: String,
        loader: @escaping @Sendable () async throws -> Data
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let data = try await loader()
                    try Task.checkCancellation()
                    progress.completedUnitCount = 1
                    completion(data, nil)
                } catch {
                    completion(nil, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}
