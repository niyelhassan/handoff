import AppKit
import ApplicationServices
import Observation

/// Tracks the two TCC permissions Handoff cannot function without.
///
/// Accessibility (kTCCServiceAccessibility) - reading other apps' UI trees and
/// performing actions on them. Input Monitoring (kTCCServiceListenEvent) - the
/// global event tap. Neither has an Info.plist usage-description key; the
/// prompts are system-owned.
@MainActor
@Observable
final class PermissionsManager {

    enum State: Equatable { case granted, denied, unknown }

    private(set) var accessibility: State = .unknown
    private(set) var inputMonitoring: State = .unknown

    /// Fired on a false -> true transition so the event tap can be rebuilt.
    /// An existing tap stays permanently dead after an Input Monitoring grant,
    /// so rebuilding is not optional.
    var onAccessibilityGranted: (() -> Void)?
    var onInputMonitoringGranted: (() -> Void)?

    var allGranted: Bool { accessibility == .granted && inputMonitoring == .granted }

    private var timer: Timer?

    // MARK: - Checks (cheap, never prompt)

    func refresh() {
        let axWasGranted = accessibility == .granted
        let imWasGranted = inputMonitoring == .granted

        accessibility = AXIsProcessTrusted() ? .granted : .denied
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied

        if !axWasGranted, accessibility == .granted { onAccessibilityGranted?() }
        if !imWasGranted, inputMonitoring == .granted { onInputMonitoringGranted?() }
    }

    // MARK: - Requests (may prompt)

    /// Prompts only when TCC has no record yet. Once the user has said no, this
    /// returns false silently forever and the only recourse is System Settings.
    @discardableResult
    func requestAccessibility() -> Bool {
        // Deliberately the string literal, not kAXTrustedCheckOptionPrompt:
        // that constant is a non-Sendable `Unmanaged<CFString>` global and is a
        // hard error under Swift 6 strict concurrency.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let ok = AXIsProcessTrustedWithOptions(opts)
        accessibility = ok ? .granted : .denied
        return ok
    }

    @discardableResult
    func requestInputMonitoring() -> Bool {
        if CGPreflightListenEventAccess() {
            inputMonitoring = .granted
            return true
        }
        let ok = CGRequestListenEventAccess()
        inputMonitoring = ok ? .granted : .denied
        return ok
    }

    // MARK: - Deep links

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case listenEvent   = "Privacy_ListenEvent"
    }

    /// This URL scheme is undocumented and Apple has renamed panes across
    /// releases, hence the fallback chain. Worst case we land on the Privacy
    /// root, which is recoverable.
    func openSettings(_ pane: Pane) {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Polling

    /// Accessibility flips live, within ~1s of the toggle. Input Monitoring
    /// reports granted live but leaves any existing tap dead, so the grant
    /// callback must rebuild rather than assume.
    func startPolling(interval: TimeInterval = 1.0) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() { timer?.invalidate(); timer = nil }
}
