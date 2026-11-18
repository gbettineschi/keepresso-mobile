import Foundation

public enum MacAlertWakeState: String, Codable {
    case full, dark, unknown

    public init(systemCapabilities: UInt64?) {
        guard let capabilities = systemCapabilities, capabilities & 0x1 != 0 else {
            self = .unknown
            return
        }
        self = capabilities & 0x6 == 0 ? .dark : .full
    }

    public func corroborated(by kernel: Self) -> Self {
        if self == .dark || kernel == .dark { return .dark }
        return self == .full && kernel == .full ? .full : .unknown
    }
}

public struct MacBrewReading {
    public enum Mode: String, Codable { case manual, automatic, lease, unknown }

    public let startedAt: Date?
    let mode: Mode
    let endsAt: Date?
    let returnsToAutomatic: Bool

    public init(startedAt: Date?, mode: Mode, endsAt: Date?, returnsToAutomatic: Bool) {
        self.startedAt = startedAt
        self.mode = mode
        self.endsAt = endsAt
        self.returnsToAutomatic = returnsToAutomatic
    }

    var description: String {
        switch mode {
        case .automatic:
            return "Kept awake by an Automatic session."
        case .manual:
            guard let endsAt else { return "Kept awake by a Manual session with no end time." }
            let time = endsAt.formatted(date: .omitted, time: .shortened)
            return "Kept awake by a Manual session that ends at \(time)"
                + (returnsToAutomatic ? ", then returns to Automatic." : ".")
        case .lease:
            return "Kept awake by an automation lease."
        case .unknown:
            return "Keepresso is brewing."
        }
    }
}

public enum MacAwakeContext: String, Codable {
    case normal, lidClosed = "lid_closed", screenOff = "screen_off", unknown

    public init(wake: MacAlertWakeState, lidClosed: Bool?, displays: MacDisplayAvailability) {
        guard wake == .full else { self = .unknown; return }
        switch displays {
        case .available: self = .normal
        case .unavailable:
            self = lidClosed.map { $0 ? .lidClosed : .screenOff } ?? .unknown
        case .unknown: self = .unknown
        }
    }
    var nonVisible: Bool { self == .lidClosed || self == .screenOff }
}

public struct MacAwakeReading {
    public let wake: MacAlertWakeState
    public let lidClosed: Bool?
    public let displayAvailability: MacDisplayAvailability
    public let isBrewing: Bool?
    let brew: MacBrewReading?
    let lastUserInputAt: Date?
    public var context: MacAwakeContext { .init(wake: wake, lidClosed: lidClosed, displays: displayAvailability) }

    public init(wake: MacAlertWakeState, lidClosed: Bool?, displayAvailability: MacDisplayAvailability, isBrewing: Bool?,
                brew: MacBrewReading?, lastUserInputAt: Date?) {
        self.wake = wake
        self.lidClosed = lidClosed
        self.displayAvailability = displayAvailability
        self.isBrewing = isBrewing
        self.brew = brew
        self.lastUserInputAt = lastUserInputAt
    }
}

struct AwakeAlerts: Codable {
    private struct UnattendedEpisode: Codable {
        let brewStart: Date
        let since: Date
        var notified = false
    }

    private struct LidIncident: Codable {
        let id: String
        var lastPublishedAt: Date
        var lastBody: String
        var brewedWhileClosed: Bool
        var lastContext: MacAwakeContext? = nil
    }

    private var unattended: UnattendedEpisode?
    private var lidIncident: LidIncident?
    private var continuousAwakeSince: Date?
    private var closedSince: Date?
    private var lastLidClosed: Bool?
    private var closureSoundPending: Bool?
    private var brewedDuringDelay: Bool?

    mutating func consumeLidClosureSound() -> Bool {
        let pending = closureSoundPending == true
        closureSoundPending = false
        return pending
    }

    mutating func observe(
        _ reading: MacAwakeReading, now: Date, routineEnabled: Bool
    ) -> [CompanionEvent] {
        closureSoundPending = false
        let context = reading.context
        guard reading.wake == .full, context != .unknown else {
            invalidateContinuity()
            return []
        }
        let lidWasClosed = lastLidClosed
        lastLidClosed = reading.lidClosed
        closureSoundPending = lidWasClosed == false && reading.lidClosed == true && context.nonVisible
        if continuousAwakeSince == nil { continuousAwakeSince = now }
        // The unattended episode survives screen changes. Only its presentation
        // depends on whether a usable screen is currently awake.
        let routine = observeUnattended(reading, now: now, routineEnabled: routineEnabled && context == .normal)
        if context.nonVisible {
            if closedSince == nil { closedSince = now }
            if reading.isBrewing == true { brewedDuringDelay = true }
            guard let closedSince, now.timeIntervalSince(closedSince) >= 60 else { return [] }
            return observeClosedLid(reading, now: now).map { [$0] } ?? []
        }

        closedSince = nil
        brewedDuringDelay = nil
        return (resolveLid(now: now).map { [$0] } ?? []) + (routine.map { [$0] } ?? [])
    }

    private mutating func observeUnattended(
        _ reading: MacAwakeReading, now: Date, routineEnabled: Bool
    ) -> CompanionEvent? {
        if reading.isBrewing == false {
            unattended = nil
            continuousAwakeSince = now
            return nil
        }
        guard let brew = reading.brew, let start = brew.startedAt, start <= now,
              let lastInput = reading.lastUserInputAt, lastInput <= now, let continuousAwakeSince else {
            self.continuousAwakeSince = nil
            return nil
        }
        let since = max(start, lastInput, continuousAwakeSince)
        if unattended?.brewStart != start || lastInput > (unattended?.since ?? .distantPast).addingTimeInterval(2) {
            unattended = UnattendedEpisode(brewStart: start, since: since)
        } else if let previous = unattended, !previous.notified, continuousAwakeSince > previous.since {
            unattended = UnattendedEpisode(brewStart: start, since: since)
        }
        guard let episode = unattended, !episode.notified, routineEnabled,
              now.timeIntervalSince(episode.since) >= 3_600 else { return nil }
        unattended?.notified = true
        let time = episode.since.formatted(date: .omitted, time: .shortened)
        return CompanionEvent(kind: "unattended_brew", createdAt: now,
                              title: "Your Mac has been running unattended since \(time)",
                              body: brew.description, scheduledEnd: brew.endsAt, snoozedUntil: nil)
    }

    private mutating func observeClosedLid(_ reading: MacAwakeReading, now: Date) -> CompanionEvent? {
        let context = reading.context
        let brewed = reading.isBrewing == true || brewedDuringDelay == true || lidIncident?.brewedWhileClosed == true
        let body: String
        if let brew = reading.brew { body = brew.description }
        else if reading.isBrewing == false {
            body = brewed ? "Keepresso is no longer brewing." : "Keepresso is not brewing."
        } else { body = "The Mac is awake. Brewing status is unavailable." }

        let incidentID: String
        let phase: AlertPhase
        if let previous = lidIncident {
            guard body != previous.lastBody || context != previous.lastContext || now.timeIntervalSince(previous.lastPublishedAt) >= 90 else { return nil }
            incidentID = previous.id
            phase = .updated
        } else {
            incidentID = UUID().uuidString.lowercased()
            phase = .active
        }
        lidIncident = LidIncident(id: incidentID, lastPublishedAt: now, lastBody: body, brewedWhileClosed: brewed, lastContext: context)
        return CompanionEvent(kind: "lid_awake", createdAt: now, title: context == .screenOff ? "Your Mac is running with the screen off" : "Your Mac is running with the lid closed",
                              body: body, scheduledEnd: reading.brew?.endsAt, snoozedUntil: nil,
                              incidentId: incidentID, alertPhase: phase, awakeContext: context)
    }

    mutating func resolveLid(now: Date) -> CompanionEvent? {
        guard let incident = lidIncident else { return nil }
        lidIncident = nil
        return CompanionEvent(kind: "lid_awake", createdAt: now, title: "Closed-lid alert ended",
                              body: "", scheduledEnd: nil, snoozedUntil: nil,
                              incidentId: incident.id, alertPhase: .resolved, awakeContext: incident.lastContext ?? .lidClosed)
    }

    mutating func invalidateContinuity() {
        closureSoundPending = false
        brewedDuringDelay = nil
        continuousAwakeSince = nil
        closedSince = nil
        lastLidClosed = nil
    }

    mutating func observedSleep(now: Date) -> CompanionEvent? {
        if unattended?.notified != true { unattended = nil }
        invalidateContinuity()
        return resolveLid(now: now)
    }
}
