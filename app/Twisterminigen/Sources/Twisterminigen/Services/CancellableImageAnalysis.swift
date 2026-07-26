import Foundation

/// Bridges synchronous image frameworks onto a detached worker while preserving structured
/// cancellation from the owning SwiftUI task.
enum CancellableImageAnalysis {
    static func run<Value: Sendable>(
        priority: TaskPriority? = .userInitiated,
        operation: @escaping @Sendable () throws -> Value,
        onCancel: @escaping @Sendable () -> Void = {}
    ) async throws -> Value {
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            // Framework cancellation first, then Swift task cancellation. For Vision this calls
            // VNRequest.cancel(), which can interrupt an in-flight `perform` rather than merely
            // ignoring its eventual result after the sheet has closed.
            onCancel()
            worker.cancel()
        }
    }
}
