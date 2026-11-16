import Foundation

public struct SleepPreparationState {
    /// Nil when the native process/state acknowledgement cannot be verified.
    public var stopped: Bool?
    public var sleepDisabled: Bool?
    public init(stopped: Bool?, sleepDisabled: Bool?) {
        self.stopped = stopped
        self.sleepDisabled = sleepDisabled
    }
}

/// Result of the one system request. An accepted request alone is inconclusive.
public enum SystemSleepEvidence {
    case rejected
    case willSleep
    case stillAwake
    case unconfirmed
}

/// Authorization and observed native state gate every step. The production
/// adapter supplies one fixed sleep request; tests inject all power effects.
@MainActor public enum SafeSleep {
    public static func perform(
        id: String,
        authorized: () -> Bool,
        state: () async -> SleepPreparationState?,
        stop: () async throws -> Void,
        observedWillSleep: () -> Bool = { false },
        requestSleep: () async -> SystemSleepEvidence,
        wait: () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
    ) async -> CommandResponse {
        func cannotRequest(status: String = "error") -> CommandResponse {
            .sleep(id: id, outcome: .couldNotRequestSleep, status: status)
        }
        let goingToSleep = CommandResponse.sleep(id: id, outcome: .goingToSleep, status: "ok")
        guard authorized(), !Task.isCancelled else { return cannotRequest() }
        guard let initial = await state(), initial.sleepDisabled != nil, authorized(), !Task.isCancelled
        else { return cannotRequest() }
        // A verified idle Keepresso cannot release a separate sleep override.
        if initial.stopped == true, initial.sleepDisabled == true { return cannotRequest() }
        do { try await stop() }
        catch { return observedWillSleep() ? goingToSleep : cannotRequest(status: "uncertain") }

        var last: SleepPreparationState?
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        for _ in 0..<32 {
            if observedWillSleep() { return goingToSleep }
            guard authorized(), !Task.isCancelled else { return cannotRequest(status: "uncertain") }
            last = await state()
            if observedWillSleep() { return goingToSleep }
            guard authorized(), !Task.isCancelled else { return cannotRequest(status: "uncertain") }
            if last?.stopped == true, last?.sleepDisabled == false {
                switch await requestSleep() {
                case .willSleep: return goingToSleep
                case .stillAwake: return .sleep(id: id, outcome: .couldNotSleep, status: "error")
                case .rejected: return cannotRequest()
                case .unconfirmed: return cannotRequest(status: "uncertain")
                }
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            await wait()
        }

        if observedWillSleep() { return goingToSleep }
        if last?.stopped == true, last?.sleepDisabled == true { return cannotRequest() }
        return cannotRequest(status: "uncertain")
    }
}
