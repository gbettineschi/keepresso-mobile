import Foundation

public enum MacThermalState: String, Codable {
    case nominal, fair, serious, critical, unknown

    public static var current: Self {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    public var legacyStatus: String {
        switch self {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious, .critical: return "hot"
        case .unknown: return "unknown"
        }
    }
}

/// Optional fields in the native status JSON, decoded separately so unsupported
/// thermal metadata cannot invalidate the session fields.
public struct NativeThermalReport: Decodable {
    let thermalState: MacThermalState?
    let thermalGuardActive: Bool?
    let thermalBrewingPaused: Bool?
}

public struct MacThermalReading {
    public let state: MacThermalState
    public let guardActive: Bool?
    public let brewingPaused: Bool?

    init(state: MacThermalState, guardActive: Bool? = nil, brewingPaused: Bool? = nil) {
        self.state = state
        self.guardActive = guardActive
        self.brewingPaused = brewingPaused
    }

    public init(system: MacThermalState, report: NativeThermalReport?, writtenAt: Date?, now: Date) {
        guard let report, let writtenAt, report.thermalState == system, system != .unknown else {
            self.init(state: system)
            return
        }
        // Native Keepresso refreshes affirmative evidence at least every five
        // seconds. An unchanged inactive state is written only on transitions.
        let recent = now.timeIntervalSince(writtenAt) <= 15
        self.init(state: system,
                  guardActive: report.thermalGuardActive == true && !recent ? nil : report.thermalGuardActive,
                  brewingPaused: report.thermalBrewingPaused == true && !recent ? nil : report.thermalBrewingPaused)
    }

    var alertSeverity: ThermalAlertSeverity? {
        if state == .critical { return .critical }
        if guardActive == true, state == .fair || state == .serious { return .serious }
        return nil
    }
}
