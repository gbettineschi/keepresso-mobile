import CompanionCore
import SwiftUI

struct CompanionSetupView: View {
    @ObservedObject var setup: CompanionSetup
    var onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(setup.phase == .summary ? "Setup summary" : "Set up Keepresso Mobile")
                .font(.title2.bold())
            switch setup.phase {
            case .welcome:
                Text("Continue to review the access this companion needs. macOS will ask one question at a time. You can decline and keep using the available features.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(setup.steps, id: \.self) { step in
                    Label { VStack(alignment: .leading, spacing: 2) {
                        Text(step.setupTitle)
                        Text(step.setupPurpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } } icon: { Image(systemName: step.setupIcon).frame(width: 22) }
                }
                HStack {
                    Button("Set up later") { setup.deferSetup() }
                    Spacer()
                    Button("Continue") { Task { await setup.start() } }
                        .keyboardShortcut(.defaultAction)
                }
            case .requesting:
                if let current = setup.current {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(current.setupTitle).font(.headline)
                            Text(current.setupPurpose).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(current == .accessibility
                         ? "Accessibility is optional. Enable it in System Settings for Pause/Resume Triggers, or skip it."
                         : "Choose in the macOS dialog. Setup continues automatically after your answer.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Set up later") { setup.deferSetup() }
                        Spacer()
                        if current == .accessibility {
                            Button("Skip this step") { setup.skipCurrent() }
                        }
                    }
                }
            case .summary:
                Text("Available features are ready. Access you declined or skipped stays unavailable until you enable it. You can review setup again in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(setup.steps, id: \.self) { step in
                    HStack(alignment: .top, spacing: 10) {
                        let authorized = setup.outcomes[step] == .authorized
                        Image(systemName: authorized ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(authorized ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.setupTitle).fixedSize(horizontal: false, vertical: true)
                            Text(summary(for: step)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if !authorized {
                            Button("Open Settings…") { setup.openSettings(for: step) }.controlSize(.small)
                        }
                    }
                }
                if setup.restartSuggested {
                    Text("After changing access in System Settings, restart once to check again. macOS may require a new approval after an update.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Restart app") { Task { await setup.restart() } }
                        .disabled(setup.restarting)
                    if setup.restartFailed {
                        Text("Restart could not start. Keepresso Mobile is still running.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Recheck") { Task { await setup.manualRecheck() } }
                        .controlSize(.small).disabled(setup.restarting)
                    Spacer()
                    Button("Finish") {
                        setup.finish()
                        onFinished()
                    }.keyboardShortcut(.defaultAction).disabled(setup.restarting)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(setup.running)
    }

    private func summary(for kind: CompanionSetupKind) -> String {
        switch setup.outcomes[kind] {
        case .authorized: return "Ready"
        case .restricted: return "Restricted by macOS or device policy."
        case .denied: return kind == .accessibility
            ? "macOS hasn’t granted this copy access. Check its entry in Privacy & Security."
            : "Access has not been granted in Privacy & Security."
        case .skipped: return "Skipped. This feature remains unavailable."
        default: return kind == .steam
            ? "Steam preparation could not finish. Check Steam's library folders and review setup again."
            : "Unavailable. Review setup after checking Privacy & Security."
        }
    }
}

private extension CompanionSetupKind {
    var setupTitle: String {
        switch self {
        case .bluetooth: return "Nearby Bluetooth"
        case .location: return "Wi-Fi network name"
        case .calendar: return "Calendar events"
        case .folders: return "Configured download folders"
        case .steam: return "Steam download libraries"
        case .accessibility: return "Remote trigger controls (optional)"
        }
    }
    var setupPurpose: String {
        switch self {
        case .bluetooth: return "Connect your phone nearby and check configured Bluetooth rules."
        case .location: return "Show your current Wi-Fi name and check Wi-Fi rules."
        case .calendar: return "Check the Calendar event rule configured in Keepresso."
        case .folders: return "Check the download folders configured in Keepresso."
        case .steam: return "Prepare the local library access needed for the Steam rule."
        case .accessibility: return "Let your phone use Keepresso's Pause/Resume Triggers controls."
        }
    }
    var setupIcon: String {
        switch self {
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .location: return "wifi"
        case .calendar: return "calendar"
        case .folders, .steam: return "folder"
        case .accessibility: return "hand.point.up.left"
        }
    }
}
