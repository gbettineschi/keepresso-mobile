import Foundation

/// Own one cancellable refresh even when requests arrive from multiple phones.
@MainActor public final class TriggerRefreshOwner {
    private var current: (id: UUID, task: Task<TriggerPreview, Never>)?
    public init() {}
    public var isRunning: Bool { current != nil }
    public func cancel() { current?.task.cancel(); current=nil }
    public func run(operation: @escaping @MainActor () async -> TriggerPreview) async -> TriggerPreview? {
        guard current == nil else { return nil }
        let id=UUID();let task=Task { await operation() };current=(id,task)
        defer { if current?.id == id { current=nil } }
        let result=await task.value
        return task.isCancelled ? nil:result
    }
}
