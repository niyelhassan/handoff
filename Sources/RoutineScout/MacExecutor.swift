import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers
import ScoutCore

@MainActor final class MacExecutor: UIExecuting {
    let ax: Accessibility
    var lastInteraction: () -> Date = { .distantPast }
    var interrupted: () -> Bool = { false }
    init(ax: Accessibility) { self.ax = ax }
    func beforeRun() async throws {
        guard AXIsProcessTrusted() else { throw ScoutError.message("Allow access in System Settings before trying this routine.") }
        for _ in 0..<30 {
            let locked = (CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            if !locked && Date().timeIntervalSince(lastInteraction()) >= 2 { return }
            try await Task.sleep(for:.seconds(1))
        }
        throw ScoutError.message("Unlock your Mac and leave the keyboard and mouse idle for two seconds.")
    }
    func validate(_ step: Step) throws { if let target = step.target, ![.pressShortcut,.readURL].contains(step.operation) { _ = try ax.resolve(target) } }
    private func foreground(_ app: String) async throws {
        guard !interrupted() else { throw ScoutError.message("Stopped because you started using the Mac.") }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier:app).first else { throw ScoutError.message("Open the app used by this routine first.") }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != app {
            // Bring the app forward and give macOS a moment; retry briefly because activation is asynchronous.
            for _ in 0..<6 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != app {
                NSApp.yieldActivation(to:running)
                running.activate()
                try await Task.sleep(for:.milliseconds(250))
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app else { throw ScoutError.message("The expected app is not in front.") }
        guard !interrupted() else { throw ScoutError.message("Stopped because you started using the Mac.") }
    }
    func focus(_ step: Step) async throws { if let target = step.target { try await foreground(target.app) } }
    /// Resolves a target, retrying for a few seconds because pages and windows often finish appearing a moment after they are opened.
    private func locate(_ target: Target, timeout: Double = 3) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do { return try ax.resolve(target) } catch {
                guard Date() < deadline, !interrupted() else { throw error }
                try await Task.sleep(for:.milliseconds(250))
            }
        }
    }
    func execute(_ step: Step, args: [String:String]) async throws -> [String:String] {
        if let target = step.target { try await foreground(target.app) }
        switch step.operation {
        case .openApp:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:args["app"]!) else { throw ScoutError.message("That app is not installed.") }
            _ = try await NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()); return [:]
        case .openURL:
            guard let url = URL(string:args["url"]!), ["https","http"].contains(url.scheme ?? "") else { throw ScoutError.message("That is not a web link.") }
            if let app = step.target?.app, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier:app) { try await NSWorkspace.shared.open([url],withApplicationAt:appURL,configuration:NSWorkspace.OpenConfiguration()) } else { guard NSWorkspace.shared.open(url) else { throw ScoutError.message("The browser could not open the link.") } }; return [:]
        case .waitForElement:
            for _ in 0..<20 { guard !interrupted() else { throw CancellationError() }; if (try? ax.resolve(step.target!)) != nil { return [:] }; try await Task.sleep(for:.milliseconds(500)) }; throw ScoutError.message("The expected item did not appear.")
        case .readText,.copyText:
            let e = try await locate(step.target!); let value = axString(e,kAXValueAttribute); let text = value.isEmpty ? axString(e,kAXTitleAttribute) : value
            guard !text.isEmpty else { throw ScoutError.message("The item has no readable text.") }
            if step.operation == .copyText { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
            return [args["output"]!:text]
        case .readURL:
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:step.target!.app).first else { throw ScoutError.message("Open the browser first.") }; let url = ax.pageURL(AXUIElementCreateApplication(app.processIdentifier)); guard ["https","http"].contains(url.scheme ?? "") else { throw ScoutError.message("The current page address could not be read.") }; return [args["output"]!:url.absoluteString]
        case .setValue,.pasteValue:
            let element = try await locate(step.target!); guard !axProtected(element) else { throw ScoutError.message("Protected fields cannot be filled.") }
            guard AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success else { throw ScoutError.message("The field could not receive focus.") }
            // Prefer a direct field write over changing the user's clipboard.
            guard AXUIElementSetAttributeValue(element,kAXValueAttribute as CFString,args["value"]! as CFString) == .success else { throw ScoutError.message("This field does not allow direct filling. No keystrokes were sent.") }
            try await Task.sleep(for:.milliseconds(150)); guard axString(element,kAXValueAttribute) == args["value"]! else { throw ScoutError.message("The field did not keep the expected value.") }; return [:]
        case .click,.chooseMenu:
            let element = try await locate(step.target!); let before = fingerprint(element)
            guard AXUIElementPerformAction(element,kAXPressAction as CFString) == .success else { throw ScoutError.message("The item could not be pressed.") }
            for _ in 0..<10 { try await Task.sleep(for:.milliseconds(200)); if fingerprint(element) != before || (try? ax.resolve(step.target!)) == nil { return [:] } }
            throw ScoutError.message("The item was pressed, but its result could not be verified. Check the app before continuing.")
        case .pressShortcut:
            let keys: [String:CGKeyCode] = ["s":1,"c":8,"v":9,"a":0,"z":6,"e":14,"o":31,"n":45,"tab":48,"return":36,"escape":53]
            guard let key = keys[args["key"]!.lowercased()] else { throw ScoutError.message("That shortcut is not supported.") }
            let flags = args["modifiers"]!.components(separatedBy:"+"); guard flags.contains("command"), Set(flags).isSubset(of:["command","shift","option","control"]) else { throw ScoutError.message("Only known command shortcuts are allowed.") }
            var modifiers: CGEventFlags = .maskCommand; if flags.contains("shift") { modifiers.insert(.maskShift) }; if flags.contains("option") { modifiers.insert(.maskAlternate) }; if flags.contains("control") { modifiers.insert(.maskControl) }
            guard let down = CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:true), let up = CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:false) else { throw ScoutError.message("Could not send the shortcut.") }
            down.flags = modifiers; up.flags = modifiers; down.setIntegerValueField(.eventSourceUserData,value:739201); up.setIntegerValueField(.eventSourceUserData,value:739201); down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
            // The shortcut's effect cannot be verified generically; it is marked irreversible so automatic mode requires explicit permission.
            try await Task.sleep(for:.milliseconds(400)); return [:]
        case .openFile:
            let url = URL(fileURLWithPath:args["path"]!); guard FileManager.default.fileExists(atPath:url.path), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier:args["app"]!) else { throw ScoutError.message("The file or app could not be found.") }; try await NSWorkspace.shared.open([url],withApplicationAt:app,configuration:NSWorkspace.OpenConfiguration()); return [:]
        case .revealFile: let url = URL(fileURLWithPath:args["path"]!); guard FileManager.default.fileExists(atPath:url.path) else { throw ScoutError.message("The file no longer exists.") }; NSWorkspace.shared.activateFileViewerSelecting([url]); return [:]
        case .numbersAppend,.numbersRead,.excelAppend,.excelRead,.mailRead,.notesAppend,.runShortcut: return try ScriptTemplates.run(step.operation,args:args)
        default: throw ScoutError.message("This action is not available in this app.")
        }
    }
    func prepareUndo(_ step: Step, args: [String:String]) async throws -> FieldUndo? {
        guard [.setValue,.pasteValue].contains(step.operation), let target = step.target else { return nil }
        let element = try await locate(target)
        return FieldUndo(target:target,before:axString(element,kAXValueAttribute),after:args["value"] ?? "",context:contextIdentity(target.app))
    }
    func contextIdentity(_ app: String) -> String {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier:app).first else { return "" }
        let root = AXUIElementCreateApplication(running.processIdentifier)
        // A web page is identified by its address (titles arrive late while a page loads). Other apps use the main window title.
        let url = ax.pageURL(root,browser:Accessibility.browsers.contains(app))
        if ["https","http"].contains(url.scheme ?? "") { return url.absoluteString }
        let window = axElement(root,kAXMainWindowAttribute) ?? axElement(root,kAXFocusedWindowAttribute)
        return window.map { axString($0,kAXTitleAttribute) } ?? ""
    }
    func checkUndo(_ entry: FieldUndo) throws {
        guard contextIdentity(entry.target.app) == entry.context, axString(try ax.resolve(entry.target),kAXValueAttribute) == entry.after else { throw ScoutError.message("The page or field has changed. Undo will not overwrite your edits.") }
    }
    func undo(_ entry: FieldUndo) throws {
        try checkUndo(entry)
        let element = try ax.resolve(entry.target)
        // Web views only accept value writes on the focused field, so focus it first exactly as the fill did.
        _ = AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(element,kAXValueAttribute as CFString,entry.before as CFString) == .success else { throw ScoutError.message("The field could not be restored.") }
        // Web views apply the value asynchronously; give them up to a second before judging.
        for _ in 0..<10 { if axString(element,kAXValueAttribute) == entry.before { return }; Thread.sleep(forTimeInterval:0.1) }
        throw ScoutError.message("The field could not be restored.")
    }
    private func fingerprint(_ element: AXUIElement) -> String {
        let parent = axElement(element,kAXParentAttribute) ?? element
        return axString(element,kAXValueAttribute)+axString(element,kAXTitleAttribute)+String(describing:axValue(element,kAXEnabledAttribute))+axChildren(parent).map { axString($0,kAXTitleAttribute)+axString($0,kAXValueAttribute) }.joined(separator:"|")
    }
}
