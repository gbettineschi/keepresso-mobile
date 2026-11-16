import Foundation

/// Own one cancellable refresh even when requests arrive from multiple phones.
@MainActor public final class TriggerRefreshOwner {
    private var current: (id: UUID, task: Task<TriggerPreview, Never>)?
    public init() {}
    public var isRunning: Bool { current != nil }
    // Cancellation can suspend while the observer terminates its worker. Keep
    // ownership until run's defer observes completion, so a resumed lifecycle
    // cannot accept another check against the old observer's retained history.
    public func cancel() { current?.task.cancel() }
    public func run(operation: @escaping @MainActor () async -> TriggerPreview) async -> TriggerPreview? {
        guard current == nil else { return nil }
        let id=UUID();let task=Task { await operation() };current=(id,task)
        defer { if current?.id == id { current=nil } }
        let result=await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: { task.cancel() })
        return Task.isCancelled || task.isCancelled ? nil:result
    }
}
