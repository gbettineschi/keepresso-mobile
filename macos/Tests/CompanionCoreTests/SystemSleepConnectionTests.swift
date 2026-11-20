import IOKit
import Testing
@testable import CompanionCore

@Test func sleepConnectionUsesTheDefaultIOMasterPort() {
    // IOPMFindPowerManagement expects the I/O primary port, not our task port.
    // Model that API contract without opening a connection or requesting sleep.
    let connection = SystemSleepConnection.open { primaryPort in
        primaryPort == mach_port_t(MACH_PORT_NULL) ? io_connect_t(123) : 0
    }
    #expect(connection == 123)
}

@Test func sleepConnectionPreservesDiscoveryFailure() {
    #expect(SystemSleepConnection.open { _ in 0 } == 0)
}
