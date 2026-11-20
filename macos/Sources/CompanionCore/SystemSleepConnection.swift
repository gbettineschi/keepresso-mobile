import IOKit
import IOKit.pwr_mgt

/// Discovery only; callers own closing the returned connection.
public enum SystemSleepConnection {
    public static func open(
        using find: (mach_port_t) -> io_connect_t = IOPMFindPowerManagement
    ) -> io_connect_t {
        find(mach_port_t(MACH_PORT_NULL))
    }
}
