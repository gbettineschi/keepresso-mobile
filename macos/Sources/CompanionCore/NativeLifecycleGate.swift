import Foundation

/// An application identity includes its launch, not just its reusable PID.
/// A changed generation invalidates work started by the previous native app.
public struct NativeLifecycleGate {
    public enum Action: Equatable { case stop, start }
    public private(set) var generation: UInt64 = 0
    public private(set) var applicationToken: String?
    public var isActive: Bool { applicationToken != nil }
    public init() {}
    public mutating func update(applicationToken next: String?) -> [Action] {
        guard next != applicationToken else { return [] }
        var actions: [Action] = []
        if isActive { actions.append(.stop) }
        generation &+= 1
        applicationToken = next
        if next != nil { actions.append(.start) }
        return actions
    }
    public func accepts(generation candidate: UInt64) -> Bool {
        isActive && candidate == generation
    }
}
