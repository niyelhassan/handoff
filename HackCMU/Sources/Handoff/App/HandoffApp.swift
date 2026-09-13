import SwiftUI

// Phase 1: menu bar host for the capture pipeline.
@main
struct HandoffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PermissionsPanel(permissions: delegate.permissions,
                             capture: delegate.capture,
                             suggestions: delegate.suggestions)
        } label: {
            Image(systemName: delegate.suggestions.isShowing
                  ? "repeat.circle.fill"
                  : (delegate.capture.isRunning ? "repeat.circle" : "repeat"))
        }
        .menuBarExtraStyle(.window)
    }
}
