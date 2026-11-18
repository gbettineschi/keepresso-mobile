import CoreGraphics

public struct MacDisplaySample: Sendable {
    public let isBuiltIn: Bool
    public let isAsleep: Bool?
    public init(isBuiltIn: Bool, isAsleep: Bool?) { self.isBuiltIn = isBuiltIn; self.isAsleep = isAsleep }
}

public enum MacDisplayAvailability: String, Codable, Sendable {
    case available, unavailable, unknown
    public static func assess(lidClosed: Bool?, displays: [MacDisplaySample]?) -> Self {
        guard let displays, !displays.isEmpty || lidClosed == true else { return .unknown }
        var uncertain = false
        for display in displays {
            if display.isBuiltIn {
                if lidClosed == true { continue }
                if lidClosed == nil {
                    if display.isAsleep != true { uncertain = true }
                    continue
                }
            }
            if display.isAsleep == false { return .available }
            if display.isAsleep == nil { uncertain = true }
        }
        return uncertain ? .unknown : .unavailable
    }
}

public struct MacDisplayAvailabilityReader {
    private let readOnlineDisplays: () -> [MacDisplaySample]?
    public init() { self.init(readOnlineDisplays: Self.onlineDisplays) }
    public init(readOnlineDisplays: @escaping () -> [MacDisplaySample]?) { self.readOnlineDisplays = readOnlineDisplays }
    public func read(lidClosed: Bool?) -> MacDisplayAvailability { .assess(lidClosed: lidClosed, displays: readOnlineDisplays()) }

    private static func onlineIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count <= 256 else { return nil }
        if count == 0 { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    private static func onlineDisplays() -> [MacDisplaySample]? {
        guard let ids = onlineIDs(), ids.allSatisfy({ CGDisplayIsOnline($0) != 0 }) else { return nil }
        let samples = ids.map { MacDisplaySample(isBuiltIn: CGDisplayIsBuiltin($0) != 0, isAsleep: CGDisplayIsAsleep($0) != 0) }
        // A topology change is uncertainty, not evidence that the last screen went off.
        guard let after = onlineIDs(), Set(ids) == Set(after), ids.allSatisfy({ CGDisplayIsOnline($0) != 0 }) else { return nil }
        return samples
    }
}
