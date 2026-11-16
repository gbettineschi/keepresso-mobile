import Foundation

public enum ThermalAlertSeverity: String, Codable {
    case serious, critical
}

public struct ReminderMachine: Codable {
    public var settings = ReminderSettings()
    public private(set) var snoozedUntil: Date?
    private var awakeAlerts: AwakeAlerts?
    private var critical: CriticalIncident?
    private var lastSeriousWarningAt: Date?
    private var noncriticalActive: Bool?

    private struct CriticalIncident: Codable {
        let id: String
        var lastPublishedAt: Date
    }

    public var noncriticalHeatActive: Bool { noncriticalActive == true }

    public init() {}

    public mutating func observeAwake(_ reading: MacAwakeReading, now: Date) -> [CompanionEvent] {
        if awakeAlerts == nil { awakeAlerts = AwakeAlerts() }
        let routineEnabled = settings.enabled && (snoozedUntil.map { now >= $0 } ?? true)
        return awakeAlerts?.observe(reading, now: now, routineEnabled: routineEnabled) ?? []
    }

    public mutating func observeHeat(_ reading: MacThermalReading, now: Date) -> CompanionEvent? {
        switch reading.state {
        case .unknown:
            noncriticalActive = false
            return nil
        case .critical:
            noncriticalActive = false
            let phase: AlertPhase
            if let ongoing = critical {
                guard now.timeIntervalSince(ongoing.lastPublishedAt) >= 30 else { return nil }
                critical?.lastPublishedAt = now
                phase = .updated
            } else {
                critical = CriticalIncident(id: UUID().uuidString.lowercased(), lastPublishedAt: now)
                phase = .active
            }
            let body = reading.brewingPaused == true ? "macOS reports Critical. Keepresso paused brewing." : "macOS reports Critical."
            return CompanionEvent(kind: "thermal", createdAt: now, title: "Your Mac is critically hot",
                                  body: body, scheduledEnd: nil, snoozedUntil: nil, thermalSeverity: .critical,
                                  thermalState: .critical, incidentId: critical?.id, alertPhase: phase)
        case .nominal, .fair, .serious:
            if let incident = critical {
                critical = nil
                return CompanionEvent(kind: "thermal", createdAt: now, title: "Your Mac has been critically hot",
                                      body: "Now at \(reading.state.rawValue.capitalized).", scheduledEnd: nil,
                                      snoozedUntil: nil, thermalSeverity: .critical, thermalState: reading.state,
                                      incidentId: incident.id, alertPhase: .resolved)
            }
        }

        let active = reading.alertSeverity == .serious
        noncriticalActive = active
        guard active, lastSeriousWarningAt.map({ now.timeIntervalSince($0) >= 300 }) ?? true else { return nil }
        lastSeriousWarningAt = now
        let detail = reading.brewingPaused == true ? "Keepresso paused brewing." : "Check your Mac’s ventilation."
        return CompanionEvent(kind: "thermal", createdAt: now, title: "Keepresso thermal guard active",
                              body: "macOS reports \(reading.state.rawValue.capitalized). \(detail)",
                              scheduledEnd: nil, snoozedUntil: nil, thermalSeverity: .serious, thermalState: reading.state)
    }

    public mutating func acknowledge() {} // An acknowledgement leaves the reminder schedule as it is.
    public mutating func snooze(now: Date) { snoozedUntil = now.addingTimeInterval(21_600) }
    public mutating func resume() { snoozedUntil = nil }

    @discardableResult public mutating func observedSleep(now: Date = Date()) -> CompanionEvent? {
        noncriticalActive = false
        return awakeAlerts?.observedSleep(now: now)
    }

    public mutating func update(settings: ReminderSettings) throws {
        try settings.validate()
        self.settings = settings
    }

    public mutating func resumedAfterUnknownInterval() {
        awakeAlerts?.invalidateContinuity()
        noncriticalActive = false
    }
}
