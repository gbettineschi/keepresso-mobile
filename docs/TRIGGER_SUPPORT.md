# Trigger assessment and permissions

Keepresso Mobile reads the native saved rule set. All 20 trigger types in the pinned Keepresso **1.30.0** pass through its unchanged factory and matching algorithms, with companion adapters that distinguish verified readings from missing input. Unsupported app or settings versions disable assessment.

The engine runs only after **Check** on Android: six samples, 850 ms apart, under an eight-second engine watchdog and twelve-second parent bound. Ordinary dashboard updates do not run it. A completed check, including partial unknown results, is retained until another explicit check succeeds. Failed attempts retain the prior result and timestamp.

| Native trigger | Read-only input | Permission or important uncertainty |
| --- | --- | --- |
| Power source | IOKit power snapshot | Unknown provider/read failure stays unknown |
| External display | CoreGraphics display list | Enumeration failure stays unknown |
| Wi-Fi SSID | Current CoreWLAN association | Location; redacted name with radio on is unknown |
| Application | AppKit running bundle IDs | Complete snapshot can establish absence |
| Process | Bounded asynchronous process listing | Cold, failed or malformed listing is unknown |
| Time window | Current local clock | Uses native time-window matching |
| Mounted volume | Mounted volume names | Failed or missing metadata is unknown |
| CPU load | Native delta CPU reader | Needs a warm delta; native smoothing is retained |
| Camera/microphone in use | HAL device activity | No capture or recording permission; failed sweep is unknown unless direct activity suffices |
| Microphone used by app | HAL capturer list and native app matching | No recording; unreadable active capturer data is unknown |
| Audio playing | HAL output activity | Failed reads stay unknown; native release grace is retained |
| VPN connected | Bounded asynchronous native VPN probe | Cold, failed or expired cache is unknown |
| Bluetooth device | Connected paired device names | Bluetooth; incomplete matching data stays unknown unless a direct match suffices |
| Calendar event | Native EventKit event-window helper | Full Calendar access; cold/denied input is unknown |
| Gaming | Running application metadata | Uses native game-category, Steam-path and cloud-game matching; unreadable relevant metadata is unknown |
| Network throughput | Native interface delta reader | Needs a warm delta; native smoothing is retained |
| Download in folder | Shallow partial-download names and modification dates | Exact configured folders must be prepared locally; no downloaded contents read |
| AI agent activity | Validated disposable hook copies and native process/session matching | Honors a saved per-rule CPU fallback override on builds that provide it. Incomplete negatives can remain unknown within the bound. |
| Controller connected | GameController and read-only HID enumeration | No device opening or input reports; missing classification metadata is unknown |
| Steam download | Native Steam configuration/manifest/recency helpers | Locally prepared libraries and matching configuration/code proof; incomplete absence is unknown |

A logically sufficient direct positive may survive an incomplete sibling read—for example a freshly written partial download or a verified active audio device. An incomplete negative does not become inactive, and an old grace hold is not direct positive proof. Agent/session details are not sent to the phone.

This is an **independent assessment**, not the running Keepresso app's private status. Its CPU baseline, smoothing and grace history can differ. A match or grace-only result cannot guarantee that resuming native triggers will keep the Mac awake. Automated coverage exercises all 20 cases with fake active/inactive inputs and missing-input regressions; it is not physical-device acceptance of every rule or parameter variant.

## Setup

The automatically presented foreground setup requests the relevant native permission categories and companion feature access. Bluetooth supports the nearby transport; Location supports the Wi-Fi dashboard even without a Wi-Fi rule; Accessibility is optional for supported remote trigger controls. Calendar, folder and Steam preparation depend on configured rules. macOS still owns every authorization choice. See [guided setup](BUILDING.md#guided-mac-setup).

Folder/Steam preparation is tied to this executable and exact configured roots. Missing, malformed or mismatched proof defaults to no access. Changed Steam library configuration invalidates library reads until local preparation is repeated. Cancelled preparation cannot save a late approval or continue to another folder. No phone request, hidden startup or ordinary telemetry performs an unapproved folder probe.

The companion requests no microphone/camera recording, Input Monitoring, Full Disk Access or Mac notification grant. It does not inherit official Keepresso's permissions, alter its settings or patch its source. Future upstream trigger additions require a companion compatibility update.
