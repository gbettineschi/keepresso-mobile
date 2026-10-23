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
    public init(id: String, action: String, issuedAt: Date, expiresAt: Date, durationMinutes: Int? = nil, durationSeconds: Int? = nil, reminderSettings: ReminderSettings? = nil) { self.id=id; self.action=action; self.issuedAt=issuedAt; self.expiresAt=expiresAt; self.durationMinutes=durationMinutes; self.durationSeconds=durationSeconds; self.reminderSettings=reminderSettings }
    public var isMutation: Bool { !["status", "refresh_triggers"].contains(action) }
    public func validate(now: Date) throws {
        guard type == "request", WireCrypto.validID(id), expiresAt > now, expiresAt > issuedAt, expiresAt.timeIntervalSince(issuedAt) <= 30, issuedAt.timeIntervalSince(now) <= 10 else { throw CompanionError.expired }
        guard ["status","refresh_triggers","start_manual","stop_manual","pause_triggers","resume_triggers","sleep_now","snooze_reminders","resume_reminders","ack_reminder","set_reminder_settings"].contains(action) else { throw CompanionError.invalid }
        if action == "start_manual" { guard let n=durationMinutes, (15...10080).contains(n), n % 15 == 0 else { throw CompanionError.invalid } } else if durationMinutes != nil { throw CompanionError.invalid }
        if action == "snooze_reminders" { guard durationSeconds == 21600 else { throw CompanionError.invalid } } else if durationSeconds != nil { throw CompanionError.invalid }
        if action == "set_reminder_settings" { guard let s=reminderSettings else { throw CompanionError.invalid }; try s.validate() } else if reminderSettings != nil { throw CompanionError.invalid }
    }
}
public struct CommandResponse: Codable, Equatable {
    public var type = "response"; public var id: String; public var status: String; public var message: String?
    public init(id: String, status: String, message: String? = nil) { self.id=id; self.status=status; self.message=message }
}
public struct CompanionEvent: Codable {
    public var id = UUID().uuidString.lowercased(); public var kind: String; public var createdAt: Date; public var title: String; public var body: String; public var scheduledEnd: Date?; public var snoozedUntil: Date?
}
public struct TriggerPreview: Codable {
    public var state: String = "not_checked"; public var checkedAt: Date?; public var combined: Bool?; public var rules: [Rule] = []; public var message: String?
    public init() {}
    public struct Detail: Codable { public var label: String; public var active: Bool; public var agent: String?; public init(label: String, active: Bool, agent: String?) { self.label=label; self.active=active; self.agent=agent } }
    public struct Rule: Codable { public var id: String; public var label: String; public var satisfied: Bool?; public var inGrace: Bool; public var graceRemaining: Double?; public var details: [Detail]; public init(id: String,label: String,satisfied: Bool?,inGrace: Bool,graceRemaining: Double?,details: [Detail]) { self.id=id;self.label=label;self.satisfied=satisfied;self.inGrace=inGrace;self.graceRemaining=graceRemaining;self.details=details } }
}
