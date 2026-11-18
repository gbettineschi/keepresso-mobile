import Foundation
public enum CompanionError: Error { case invalid, expired, unauthorized, closed, limit, mismatch, unavailable }
public enum WireJSON {
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .custom { decoder in
        let s = try decoder.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
        throw CompanionError.invalid
    }; return d }
    public static func object(_ data: Data) throws -> [String: Any] { guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CompanionError.invalid }; return o }
    public static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    public static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
public struct ReminderSettings: Codable, Equatable {
    public var enabled: Bool; public var intervalSeconds: Int; public var endedAwakeDelaySeconds: Int
    public init(enabled: Bool = true, intervalSeconds: Int = 3600, endedAwakeDelaySeconds: Int = 300) { self.enabled = enabled; self.intervalSeconds = intervalSeconds; self.endedAwakeDelaySeconds = endedAwakeDelaySeconds }
    public func validate() throws { guard [3600,7200].contains(intervalSeconds), [120,300,600].contains(endedAwakeDelaySeconds) else { throw CompanionError.invalid } }
}
public struct CommandRequest: Codable {
    public var type = "request"; public var id: String; public var action: String; public var issuedAt: Date; public var expiresAt: Date
    public var durationMinutes: Int?; public var durationSeconds: Int?; public var reminderSettings: ReminderSettings?
    public var operationId:String?; public var bodyDigest:String?
    public init(id: String, action: String, issuedAt: Date, expiresAt: Date, durationMinutes: Int? = nil, durationSeconds: Int? = nil, reminderSettings: ReminderSettings? = nil, operationId:String? = nil, bodyDigest:String? = nil) { self.operationId=operationId; self.bodyDigest=bodyDigest; self.id=id; self.action=action; self.issuedAt=issuedAt; self.expiresAt=expiresAt; self.durationMinutes=durationMinutes; self.durationSeconds=durationSeconds; self.reminderSettings=reminderSettings }
    public var isMutation: Bool { !["status", "refresh_triggers", "operation_status"].contains(action) }
    public func validate(now: Date) throws {
        guard type == "request", WireCrypto.validID(id), expiresAt > now, expiresAt > issuedAt, expiresAt.timeIntervalSince(issuedAt) <= 30, issuedAt.timeIntervalSince(now) <= 10 else { throw CompanionError.expired }
        guard ["status","refresh_triggers","operation_status","start_manual","stop_manual","pause_triggers","resume_triggers","sleep_now","snooze_reminders","resume_reminders","ack_reminder","set_reminder_settings"].contains(action) else { throw CompanionError.invalid }
        if action == "operation_status" { guard let operationId,WireCrypto.validID(operationId),let bodyDigest else{throw CompanionError.invalid};_ = try WireCrypto.bytes32(bodyDigest) } else if operationId != nil || bodyDigest != nil {throw CompanionError.invalid}
        if action == "start_manual" { guard let n=durationMinutes, (15...10080).contains(n), n % 15 == 0 else { throw CompanionError.invalid } } else if durationMinutes != nil { throw CompanionError.invalid }
        if action == "snooze_reminders" { guard durationSeconds == 21600 else { throw CompanionError.invalid } } else if durationSeconds != nil { throw CompanionError.invalid }
        if action == "set_reminder_settings" { guard let s=reminderSettings else { throw CompanionError.invalid }; try s.validate() } else if reminderSettings != nil { throw CompanionError.invalid }
    }
}
public enum SleepOutcome: String, Codable, Sendable {
    case goingToSleep = "going_to_sleep"
    case couldNotSleep = "could_not_sleep"
    case couldNotRequestSleep = "could_not_request_sleep"

    fileprivate var message: String {
        switch self {
        case .goingToSleep: return "Going to sleep"
        case .couldNotSleep: return "Couldn’t sleep"
        case .couldNotRequestSleep: return "Couldn’t request sleep"
        }
    }
}

public struct CommandResponse: Codable, Equatable {
    public var type = "response"; public var id: String; public var status: String; public var message: String?
    public var operationId:String?; public var operationStatus:String?; public var operationMessage:String?
    public var sleepOutcome: SleepOutcome?

    public init(id: String, status: String, message: String? = nil, operationId: String? = nil,
                operationStatus: String? = nil, operationMessage: String? = nil, sleepOutcome: SleepOutcome? = nil) {
        self.id = id
        self.status = status
        self.message = message
        self.operationId = operationId
        self.operationStatus = operationStatus
        self.operationMessage = operationMessage
        self.sleepOutcome = sleepOutcome
    }

    public static func sleep(id: String, outcome: SleepOutcome, status: String) -> Self {
        Self(id: id, status: status, message: outcome.message, sleepOutcome: outcome)
    }
}
public enum AlertPhase: String, Codable { case active, updated, resolved }

public struct CompanionEvent: Codable {
    public var id = UUID().uuidString.lowercased(); public var kind: String; public var createdAt: Date; public var title: String; public var body: String; public var scheduledEnd: Date?; public var snoozedUntil: Date?
    public var thermalSeverity: ThermalAlertSeverity? = nil
    public var thermalState: MacThermalState? = nil
    public var incidentId: String? = nil
    public var alertPhase: AlertPhase? = nil
    public var awakeContext: MacAwakeContext? = nil
    public var deliveryLifetimeSeconds: Int { thermalSeverity == .critical && alertPhase != .resolved ? 60 : 300 }
    public var deliveryKind: String {
        kind == "thermal" && incidentId != nil && thermalSeverity == .critical ? "critical_episode" : kind
    }
}
public struct TriggerPreview: Codable {
    public var checking: Bool?; public var outdated: Bool?; public var checkError: String?
    public var state: String = "not_checked"; public var checkedAt: Date?; public var combined: Bool?; public var rules: [Rule] = []; public var message: String?
    public init() {}
    /// Failed attempts keep the completed assessment intact; an empty successful
    /// assessment is still a replacement, never a request to reuse old rows.
    public mutating func retainPriorAssessment(_ previous:Self){
        guard checkedAt == nil || !["ready","unknown"].contains(state) else { return }
        let error=checkError ?? message ?? "Couldn't check triggers. Try again."
        self=previous;checking=false;checkError=error
    }
    public struct Detail: Codable { public var label: String; public var active: Bool; public var agent: String?; public init(label: String, active: Bool, agent: String?) { self.label=label; self.active=active; self.agent=agent } }
    public struct Rule: Codable { public var id: String; public var label: String; public var satisfied: Bool?; public var inGrace: Bool; public var graceRemaining: Double?; public var details: [Detail]; public init(id: String,label: String,satisfied: Bool?,inGrace: Bool,graceRemaining: Double?,details: [Detail]) { self.id=id;self.label=label;self.satisfied=satisfied;self.inGrace=inGrace;self.graceRemaining=graceRemaining;self.details=details } }
}
