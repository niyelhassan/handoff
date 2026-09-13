import AppKit
import CoreGraphics

/// Turns the raw event stream into `Atom`s.
///
/// ENRICH QUEUE ONLY. Never the tap thread: this allocates, resolves process
/// identities, and holds mutable state with no synchronization at all.
///
/// The work is mostly coalescing. A person types "invoice" as one act; the tap
/// sees seven keyDowns, seven keyUps, and possibly an autorepeat storm. A
/// detector fed the raw stream would be matching noise against noise.
final class Normalizer {

    /// A run of typing ends when the typist pauses this long. Chosen above a
    /// fast typist's inter-key gap (~120ms) and below the pause that separates
    /// two deliberate actions.
    var textIdleNS: UInt64 = 900_000_000
    /// A click is held back this long so a second click can upgrade it to a
    /// double-click, which arrives as its own event with clickState 2.
    var clickHoldNS: UInt64 = 350_000_000
    var scrollCoalesceNS: UInt64 = 400_000_000

    private let emit: (Atom) -> Void
    /// Optional trace sink, so a real user run can be diagnosed from disk.
    var trace: ((String) -> Void)?
    /// Numbers seen on each web tab (by URL), captured while that tab was
    /// active. The heart of the tab-based read-and-retype case: a backgrounded
    /// tab is gone from AX, so its value must already be here.
    private var webCache: [String: [ScreenReadout]] = [:]
    private var webCacheApp: [String: (bundle: String, name: String)] = [:]
    private var lastWebSnapshot: UInt64 = 0
    /// Injected rather than constructed here so the detection layer stays
    /// testable headlessly: resolving a target needs a GUI session, an
    /// Accessibility grant, and another app to point at.
    private let resolver: TargetResolver?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private var openText: Atom?
    private var textBuffer = ""
    private var openClick: Atom?
    private var openScroll: Atom?
    private var lastPID: Int32 = 0
    private var appCache: [Int32: (bundle: String, name: String)] = [:]
    /// Apps seen recently, most-recent pid per bundle, so a typed value can be
    /// checked against whatever other windows are around.
    private var recentApps: [(pid: Int32, bundle: String, name: String)] = []

    init(resolver: TargetResolver? = nil, emit: @escaping (Atom) -> Void) {
        self.resolver = resolver
        self.emit = emit
    }

    // MARK: - Intake

    func consume(_ e: RawEvent) {
        // Our own suggestion window is on screen precisely when a pattern is
        // running. Feeding the user's clicks on it back into the detector would
        // let Handoff detect itself.
        guard e.pid != selfPID else { return }

        let (bundle, name) = app(for: e.pid)

        if e.pid != lastPID, lastPID != 0, !bundle.isEmpty {
            flushAll(before: e.hostTime)
            var s = FNV1a()
            s.combine(UInt64(AtomKind.appSwitch.rawValue))
            s.combine(bundle)
            emit(Atom(kind: .appSwitch, bundleID: bundle, appName: name,
                      strictKey: s.value, varyKey: 0,
                      label: name.isEmpty ? "Switch apps" : "Switch to \(name)",
                      detail: nil,
                      start: e.hostTime, end: e.hostTime))
        }
        if e.pid > 0 {
            lastPID = e.pid
            if !bundle.isEmpty {
                recentApps.removeAll { $0.bundle == bundle }
                recentApps.append((e.pid, bundle, name))
                if recentApps.count > 6 { recentApps.removeFirst(recentApps.count - 6) }
            }
        }

        switch e.kind {
        case .keyDown:    key(e, bundle, name)
        case .mouseDown:  mouse(e, bundle, name)
        case .scroll:     scroll(e, bundle, name)
        case .keyUp, .flagsChanged, .mouseUp, .appSwitch, .axNotify:
            // keyUp and flagsChanged carry no information the keyDown did not;
            // mouseUp only matters for drags, which are out of scope.
            break
        }
    }

    /// Called on every drain so idle-terminated atoms close on time rather than
    /// waiting for the user's next input, which might be minutes away.
    private static let browserBundles: Set<String> = ["com.apple.Safari", "com.google.Chrome"]

    func tick(now: UInt64) {
        if let t = openText, now &- t.end > textIdleNS { flushText() }
        if let c = openClick, now &- c.end > clickHoldNS { flushClick() }
        if let s = openScroll, now &- s.end > scrollCoalesceNS { flushScroll() }
        snapshotWebIfDue(now: now)
    }

    /// At ~2Hz while a browser is frontmost, record the active tab's numbers by
    /// URL. Throttled because it is an AX tree walk; frequent enough to catch a
    /// value that appears DURING the read pause, when no event fires - which is
    /// exactly when Maps finishes computing "24 min".
    private func snapshotWebIfDue(now: UInt64) {
        guard let resolver, now &- lastWebSnapshot > 450_000_000 else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier,
              Self.browserBundles.contains(bundle) else { return }
        lastWebSnapshot = now
        let pid = front.processIdentifier
        let name = front.localizedName ?? bundle
        guard let ctx = resolver.activeBrowserContext(pid: pid, bundleID: bundle, appName: name),
              !ctx.url.isEmpty, !ctx.readouts.isEmpty else { return }
        let key = Self.canonicalURL(ctx.url)
        webCache[key] = ctx.readouts
        webCacheApp[key] = (bundle, name)
        if webCache.count > 5, let oldest = webCache.keys.first { webCache.removeValue(forKey: oldest) }
        trace?("web snapshot url=\(key) numbers=\(ctx.readouts.prefix(6).map(\.text))")
    }

    /// Host + first path segment: enough to tell the Maps tab from the Sheets
    /// tab, stable across the query strings Maps rewrites as you interact.
    static func canonicalURL(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let seg = u.pathComponents.dropFirst().first.map { "/\($0)" } ?? ""
        return host + seg
    }

    func reset() {
        openText = nil; textBuffer = ""; openClick = nil; openScroll = nil
        lastPID = 0
        recentApps.removeAll()
        webCache.removeAll()
        webCacheApp.removeAll()
    }

    // MARK: - Keys

    private static let modifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue

    private func key(_ e: RawEvent, _ bundle: String, _ name: String) {
        // Caps lock, the numeric-pad bit, and the "non-coalesced" bit all ride
        // in `flags`. Hashing them would make ⌘S typed on the keypad a
        // different step from ⌘S typed anywhere else.
        let mods = e.flags & Self.modifierMask
        let hasCmdCtrl = mods & (CGEventFlags.maskCommand.rawValue
                                 | CGEventFlags.maskControl.rawValue) != 0
        let typed = Self.typedString(e)

        if !hasCmdCtrl, let typed, Self.isPrintable(typed) {
            flushClick(); flushScroll()
            appendText(typed, e, bundle, name)
            return
        }

        // Under secure input there are no characters to classify, so the test
        // above cannot fire and the keystroke would be filed as a chord named
        // "key 0". The keycode still tells us whether it was a named key, and
        // anything else in a password field is someone typing.
        if !hasCmdCtrl, e.secureInput, Self.keyNames[e.keyCode] == nil {
            flushClick(); flushScroll()
            appendText("", e, bundle, name)
            return
        }

        flushAll(before: e.hostTime)

        // Autorepeat: holding ⌘Z is one intent, not thirty steps.
        if e.isAutoRepeat { return }

        var s = FNV1a()
        s.combine(UInt64(AtomKind.chord.rawValue))
        s.combine(bundle)
        s.combine(UInt64(e.keyCode))
        s.combine(mods)

        // "Copy" rather than "Press ⌘C": the operation is what the person
        // would say they did, and it is what everything downstream reasons
        // about. The glyph form remains for chords that mean nothing named.
        let label: String
        if let op = SemanticOp.classify(keyCode: e.keyCode, modifiers: mods) {
            label = op.label
        } else {
            label = "Press " + Self.chordLabel(keyCode: e.keyCode, mods: mods, typed: typed)
        }
        var a = Atom(kind: .chord, bundleID: bundle, appName: name,
                     strictKey: s.value, varyKey: 0,
                     label: label, detail: nil,
                     start: e.hostTime, end: e.hostTime)
        a.keyCode = e.keyCode
        a.modifiers = mods
        emit(a)
    }

    private func appendText(_ typed: String, _ e: RawEvent,
                            _ bundle: String, _ name: String) {
        if var t = openText, t.bundleID == bundle,
           e.hostTime &- t.end <= textIdleNS {
            if !e.secureInput { textBuffer += typed }
            t.end = e.hostTime
            t.repeatCount += 1
            openText = t
            return
        }
        flushText()
        textBuffer = e.secureInput ? "" : typed
        openText = Atom(kind: .text, bundleID: bundle, appName: name,
                        strictKey: 0, varyKey: 0, label: "", detail: nil,
                        start: e.hostTime, end: e.hostTime)
        openText?.repeatCount = 1
        openText?.x = e.secureInput ? 1 : 0   // reuse as the "hidden" marker
    }

    private func flushText() {
        guard var t = openText else { return }
        openText = nil
        let hidden = t.x == 1
        let n = hidden ? t.repeatCount : textBuffer.count

        // The step is "type into this field", NOT "type this exact text": a
        // loop whose typed value changes every pass is still the same loop.
        // That is the whole reason strict and vary are separate keys.
        var s = FNV1a()
        s.combine(UInt64(AtomKind.text.rawValue))
        s.combine(t.bundleID)
        t.strictKey = s.value

        if hidden {
            // Secure input: we did not see the characters, so we cannot know
            // whether they varied. Claiming they did would be a lie either way.
            t.varyKey = 0
            t.label = "Type \(n) characters (hidden)"
            t.detail = nil
        } else {
            var v = FNV1a(); v.combine(textBuffer)
            t.varyKey = v.value
            t.label = "Type \(n) character\(n == 1 ? "" : "s")"
            t.detail = String(textBuffer.prefix(24))
                + (textBuffer.count > 24 ? "…" : "")
            t.fullText = textBuffer
            // Read-and-retype signal: a short value with a digit in it, typed
            // in a pass that also visited another app. Snapshot the numbers on
            // those other windows now, while they are still displayed, so the
            // binding layer can discover it came from one of them.
            if textBuffer.count <= 16, textBuffer.contains(where: \.isNumber) {
                // Cross-app sources (a native sheet + Safari Maps).
                if let resolver, recentApps.count >= 2 {
                    let here = t.bundleID
                    for app in recentApps where app.bundle != here {
                        t.screenCandidates += resolver.numericReadouts(
                            pid: app.pid, bundleID: app.bundle, appName: app.name)
                    }
                }
                // Same-window tab sources (a Sheets tab + a Maps tab). The value
                // was typed in the current tab; the source is any OTHER tab we
                // snapshotted while it was active.
                let hereURL = resolver.flatMap { r -> String? in
                    guard let front = NSWorkspace.shared.frontmostApplication,
                          let b = front.bundleIdentifier, Self.browserBundles.contains(b),
                          let ctx = r.activeBrowserContext(pid: front.processIdentifier,
                                                           bundleID: b,
                                                           appName: front.localizedName ?? b)
                    else { return nil }
                    return Self.canonicalURL(ctx.url)
                }
                for (key, readouts) in webCache where key != hereURL {
                    t.screenCandidates += readouts
                }
                if !t.screenCandidates.isEmpty {
                    trace?("text \"\(textBuffer)\" got \(t.screenCandidates.count) screen candidates from \(webCache.keys.filter { $0 != hereURL })")
                }
            }
        }
        t.x = 0
        textBuffer = ""
        emit(t)
    }

    // MARK: - Mouse

    private func mouse(_ e: RawEvent, _ bundle: String, _ name: String) {
        flushText(); flushScroll()

        let kind: AtomKind
        if e.buttonOrAxis == 1 {
            kind = .contextClick
        } else if e.clickState >= 2 {
            kind = .doubleClick
        } else {
            kind = .click
        }

        // A double-click arrives as click(state 1) then click(state 2). The
        // first one is held back exactly so this second one can replace it
        // instead of the detector seeing two separate steps.
        if kind == .doubleClick, openClick != nil { openClick = nil }
        flushClick()

        let verb = kind == .doubleClick ? "Double-click"
                 : kind == .contextClick ? "Right-click" : "Click"

        let target = resolver?.resolve(pid: e.pid, x: e.x, y: e.y)
        let strict: UInt64, vary: UInt64, structural: UInt64, label: String
        if let target {
            strict = target.strictKey(bundleID: bundle, kind: kind)
            vary = target.varyKey()
            // For a non-enumerable click, the structural key drops the title
            // and the title becomes the value - so a changing readout matches.
            structural = target.structuralKey(bundleID: bundle, kind: kind)
            label = "\(verb) \(target.describe)"
        } else {
            let k = ClickTarget.keys(bundleID: bundle, kind: kind, x: e.x, y: e.y)
            strict = k.strict; vary = k.vary; structural = k.strict
            label = name.isEmpty ? verb : "\(verb) in \(name)"
        }

        var a = Atom(kind: kind, bundleID: bundle, appName: name,
                     strictKey: strict, varyKey: vary,
                     label: label, detail: nil,
                     start: e.hostTime, end: e.hostTime)
        a.structuralKey = structural
        a.x = e.x; a.y = e.y
        a.target = target

        if kind == .doubleClick { emit(a) } else { openClick = a }
    }

    private func flushClick() {
        guard let c = openClick else { return }
        openClick = nil
        emit(c)
    }

    private func scroll(_ e: RawEvent, _ bundle: String, _ name: String) {
        flushText(); flushClick()
        let dir = e.scrollDelta >= 0 ? 1 : -1
        // Round-trip through the bit pattern, never `Int(someUInt64)`: a
        // downward scroll stores -1, whose bit pattern is UInt64.max, and
        // converting that back with `Int(_:)` traps.
        let dirKey = UInt64(bitPattern: Int64(dir))
        if var s = openScroll, s.bundleID == bundle,
           e.hostTime &- s.end <= scrollCoalesceNS,
           s.varyKey == dirKey {
            s.end = e.hostTime
            s.repeatCount += 1
            openScroll = s
            return
        }
        flushScroll()
        var s = FNV1a()
        s.combine(UInt64(AtomKind.scroll.rawValue))
        s.combine(bundle)
        s.combine(dir)
        var a = Atom(kind: .scroll, bundleID: bundle, appName: name,
                     strictKey: s.value, varyKey: dirKey,
                     label: dir > 0 ? "Scroll up" : "Scroll down", detail: nil,
                     start: e.hostTime, end: e.hostTime)
        a.x = e.x; a.y = e.y
        openScroll = a
    }

    private func flushScroll() {
        guard let s = openScroll else { return }
        openScroll = nil
        emit(s)
    }

    private func flushAll(before _: UInt64) {
        flushText(); flushClick(); flushScroll()
    }

    // MARK: - Identity

    private func app(for pid: Int32) -> (String, String) {
        guard pid > 0 else { return ("", "") }
        if let hit = appCache[pid] { return hit }
        let ra = NSRunningApplication(processIdentifier: pid)
        // The pid placeholder is an IDENTITY, not a name: it keeps two unknown
        // processes from collapsing into one step. The display name stays empty
        // so nothing user-facing ever says "in pid:900".
        let bundle = ra?.bundleIdentifier ?? "pid:\(pid)"
        let name = ra?.localizedName ?? ""
        // Bounded: pids get reused over a long session, and a stale name is
        // cosmetic, but an unbounded cache is not.
        if appCache.count > 256 { appCache.removeAll(keepingCapacity: true) }
        appCache[pid] = (bundle, name)
        return (bundle, name)
    }

    // MARK: - Text helpers

    private static func typedString(_ e: RawEvent) -> String? {
        guard e.charCount > 0, e.charCount <= 4 else { return nil }
        var units = [UInt16]()
        withUnsafeBytes(of: e.chars) { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt16.self)
            for i in 0..<Int(e.charCount) { units.append(p[i]) }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func isPrintable(_ s: String) -> Bool {
        guard let u = s.unicodeScalars.first else { return false }
        // 0xF700-0xF8FF is the private-use block AppKit maps arrows, function
        // keys, Home/End into. They pass a naive "is it >= 0x20" test and would
        // otherwise be silently appended to typed text as invisible garbage.
        if (0xF700...0xF8FF).contains(u.value) { return false }
        return u.value >= 0x20 && u.value != 0x7F
    }

    /// Apple's canonical modifier order is ⌃⌥⇧⌘; matching it means the label
    /// reads the same as the menu item the user is looking at.
    private static func chordLabel(keyCode: UInt16, mods: UInt64,
                                   typed: String?) -> String {
        var out = ""
        if mods & CGEventFlags.maskControl.rawValue   != 0 { out += "⌃" }
        if mods & CGEventFlags.maskAlternate.rawValue != 0 { out += "⌥" }
        if mods & CGEventFlags.maskShift.rawValue     != 0 { out += "⇧" }
        if mods & CGEventFlags.maskCommand.rawValue   != 0 { out += "⌘" }
        if let named = keyNames[keyCode] { return out + named }
        if let t = typed, isPrintable(t) { return out + t.uppercased() }
        return out + "key \(keyCode)"
    }

    private static let keyNames: [UInt16: String] = [
        0x24: "↩", 0x4C: "⌤", 0x30: "⇥", 0x31: "Space", 0x33: "⌫",
        0x75: "⌦", 0x35: "⎋", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16",
        0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]
}
