import SwiftUI

struct PermissionsPanel: View {
    @Bindable var permissions: PermissionsManager
    let capture: CaptureCoordinator
    let suggestions: SuggestionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Handoff").font(.headline)

            row("Accessibility", permissions.accessibility) {
                permissions.requestAccessibility()
                if permissions.accessibility != .granted {
                    permissions.openSettings(.accessibility)
                }
            }
            row("Input Monitoring", permissions.inputMonitoring) {
                permissions.requestInputMonitoring()
                if permissions.inputMonitoring != .granted {
                    permissions.openSettings(.listenEvent)
                }
            }

            Divider()

            if capture.tapFailed {
                Label("Event tap could not be created", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                Text("Input Monitoring was likely granted after launch. Relaunch Handoff.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if capture.isRunning {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    stat("events", "\(capture.eventCount)")
                    // Non-zero means the enrich queue fell behind the tap.
                    stat("dropped", "\(capture.droppedCount)",
                         warn: capture.droppedCount > 0)
                    // Climbing means the callback is overrunning its budget.
                    stat("tap revivals", "\(capture.reenableCount)",
                         warn: capture.reenableCount > 3)
                }
                .font(.system(.caption, design: .monospaced))

                Divider()
                detection
            } else {
                Text("Handoff needs both permissions to watch for repeated tasks.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Quit Handoff") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption)
                Spacer()
                // Reproducing a real loop takes a minute of deliberate
                // repetition - a bad way to iterate on the window, and a worse
                // way to discover it is broken.
                Button("Preview") { suggestions.showSample() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 270)
    }

    @ViewBuilder
    private var detection: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            stat("steps seen", "\(capture.atomCount)")
            stat("patterns found", "\(capture.candidateCount)")
            stat("suggested", "\(suggestions.offersMade)")
            stat("not worth it", "\(suggestions.declinedAsWorthless)",
                 warn: suggestions.declinedAsWorthless > 0)
        }
        .font(.system(.caption, design: .monospaced))

        // The whole point of this block: when nothing pops up, say WHY, so a
        // quiet Handoff can be told apart from a broken one.
        Divider()
        if suggestions.isShowing {
            Label("A suggestion is on screen", systemImage: "arrow.up.forward.app")
                .font(.caption).foregroundStyle(.blue)
        } else if let reason = suggestions.lastDeclineReason,
                  suggestions.declinedAsWorthless > 0 {
            Label("Last pattern skipped:", systemImage: "eye.slash")
                .font(.caption).foregroundStyle(.secondary)
            Text(reason)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if capture.candidateCount == 0 {
            Text("Watching. Repeat a task 2+ times and Handoff will offer to finish it.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Watching. \(capture.candidateCount) repeated pattern\(capture.candidateCount == 1 ? "" : "s") seen so far.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // The last few normalized steps, so you can see it IS reading your
        // actions - "Copy", "Switch to Safari", "Click a row" - in real time.
        if !capture.recentAtoms.isEmpty {
            Divider()
            Text("just now").font(.caption2).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(capture.recentAtoms.prefix(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }

        if let top = suggestions.accepted.first {
            Divider()
            Label(top.title, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private func stat(_ label: String, _ value: String, warn: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(warn ? .orange : .primary).bold()
        }
    }

    @ViewBuilder
    private func row(_ title: String,
                     _ state: PermissionsManager.State,
                     action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(state == .granted ? .green : .secondary)
            Text(title).font(.callout)
            Spacer()
            if state != .granted {
                Button("Grant", action: action).controlSize(.small)
            }
        }
    }
}
