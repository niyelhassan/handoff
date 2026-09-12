import AppKit
import ApplicationServices
import CoreServices
import ImageIO
import ScoutCore

@MainActor final class Observer {
    var onEvent: ((Evidence) -> Void)?
    var onInteraction: (() -> Void)?
    var onContext: ((String,String) -> Void)?
    var policy = PrivacyPolicy()
    var runningAutomation = false
    var lastInteraction = Date.distantPast
    var lastCopy = Date.distantPast
    private var timer: Timer?
    private var eventMonitor: Any?
    private var tokens: [NSObjectProtocol] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var stream: FSEventStreamRef?
    private var focusObserver: AXObserver?
    private var lastFocus = ""
    private var lastContext = ""
    private let ax = Accessibility()
    var allowed: Bool { context() != nil }
    func start() {
        guard timer == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseUp,.rightMouseUp,.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.input(event) }
        }
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.activation() } })
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.boundary() } })
        }
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        watchFiles(); activation()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }; tokens = []
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil
        if let focusObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(focusObserver),.defaultMode) }; focusObserver = nil
    }
    struct Context { var app: String; var root: AXUIElement; var window: String; var url: URL; var focused: AXUIElement? }
    func context() -> Context? {
        guard !policy.paused, let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier, bundle != "com.routinescout.app" else { return nil }
        guard policy.permits(app:bundle,domain:"",role:"",window:"") else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let window = axElement(root,kAXFocusedWindowAttribute).map { axString($0,kAXTitleAttribute) } ?? ""
        let focused = axElement(root,kAXFocusedUIElementAttribute)
        let browser = Accessibility.browsers.contains(bundle)
        let url = ax.pageURL(root,browser:browser)
        // Browsers fail closed when the current page cannot be identified.
        if browser, url.scheme == "about" { return nil }
        guard policy.permits(app:bundle,domain:url.host ?? "",role:focused.map { axString($0,kAXRoleAttribute) } ?? "",window:window,protected:focused.map(axProtected) ?? false) else { return nil }
        return Context(app:bundle,root:root,window:window,url:url,focused:focused)
    }
    private func emit(_ kind: String, element: AXUIElement? = nil, extras: [String:String] = [:]) {
        guard let context = context(), element.map({ !axProtected($0) }) ?? true else { return }
        let target = element ?? context.focused
        let role = target.map { axString($0,kAXRoleAttribute) } ?? ""
        let rawLabel = target.map { let title = axString($0,kAXTitleAttribute); return title.isEmpty ? axString($0,kAXDescriptionAttribute) : title } ?? ""
        let semanticLabel = ["AXButton","AXMenuItem","AXTextField","AXTextArea","AXCheckBox","AXPopUpButton"].contains(role) ? rawLabel : role
        var details = extras; details["window"] = context.window; details["url"] = context.url.scheme == "about" ? "" : context.url.absoluteString; details["label"] = rawLabel
        if let target { details["identifier"] = axString(target,kAXIdentifierAttribute); if ["click","paste","copy"].contains(kind) { let value = axString(target,kAXValueAttribute); if value.count <= 4096 { details["value"] = value } } }
        // Tokens contain no window titles, URLs, filenames or field values.
        var event = Event(app:context.app,kind:kind,role:role,label:semanticLabel,context:context.url.host ?? "",instance:digest(context.url.absoluteString+context.window+(details["row"] ?? "")))
        event.selfGenerated = runningAutomation
        onEvent?(Evidence(event,details))
    }
    private func input(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 739201 else { return }
        lastInteraction = Date(); onInteraction?()
        guard !runningAutomation, !policy.paused else { return }
        if event.type == .keyDown {
            guard event.modifierFlags.contains(.command) else { return } // Never read plain typing.
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            guard ["c","v","s","e","o","n","a","z"].contains(key) else { return }
            if key == "c" { lastCopy = Date() }
            if key == "v" { emit("paste",extras:probe()) }
            else if key != "c" { emit(key == "e" ? "export" : "shortcut",extras:["shortcut":"command"+(event.modifierFlags.contains(.shift) ? "+shift" : "")+"+"+key]) }
        } else {
            var element: AXUIElement?; let position = CGEvent(source:nil)?.location ?? .zero
            AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(position.x),Float(position.y),&element)
            if let element {
                let label = axString(element,kAXTitleAttribute).lowercased()
                if label == "copy" { lastCopy = Date() }
                emit(label == "paste" ? "paste" : ["submit","save","update","add record"].contains(label) ? "submit" : label.contains("export") ? "export" : "click",element:element)
            }
        }
    }
    private func tick() {
        let count = NSPasteboard.general.changeCount
        if count != changeCount {
            changeCount = count
            if !runningAutomation, Date().timeIntervalSince(lastCopy) < 3, context() != nil, let text = NSPasteboard.general.string(forType:.string), text.utf8.count <= 16384 { emit("copy",extras:probe().merging(["text":text],uniquingKeysWith: { _,b in b })) }
        }
        guard let c = context() else { lastContext = ""; return }
        let signature = c.app+"|"+c.url.absoluteString
        if signature != lastContext { lastContext = signature; onContext?(c.app,c.url.absoluteString) }
    }
    private func activation() {
        emit("activate")
        if let focusObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(focusObserver),.defaultMode) }; focusObserver = nil
        guard let c = context(), let app = NSRunningApplication.runningApplications(withBundleIdentifier:c.app).first else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _,element,_,ref in
            guard let ref else { return }; let owner = Unmanaged<Observer>.fromOpaque(ref).takeUnretainedValue()
            MainActor.assumeIsolated { owner.emit("focus",element:element) }
        }
        if AXObserverCreate(app.processIdentifier,callback,&observer) == .success, let observer {
            focusObserver = observer; AXObserverAddNotification(observer,c.root,kAXFocusedUIElementChangedNotification as CFString,Unmanaged.passUnretained(self).toOpaque()); CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.defaultMode)
        }
    }
    private func boundary() { guard !policy.paused else { return }; onEvent?(Evidence(Event(app:"system",kind:"boundary"))); onInteraction?() }
    private func probe() -> [String:String] {
        // Only fixed, read-only templates. Failed app permission does not prevent observation.
        guard let c = context(), ["com.apple.iWork.Numbers","com.microsoft.Excel","com.apple.mail"].contains(c.app) else { return [:] }
        return ScriptTemplates.context(app:c.app)
    }
    private func watchFiles() {
        let folders = ["Downloads","Desktop","Documents"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }
        var context = FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        let callback: FSEventStreamCallback = { _,ref,count,paths,flags,_ in
            guard let ref else { return }; let owner = Unmanaged<Observer>.fromOpaque(ref).takeUnretainedValue(); let values = unsafeBitCast(paths,to:NSArray.self) as! [String]
            for i in 0..<count where flags[i] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 && flags[i] & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified) != 0 {
                let path = values[i]; Task { @MainActor in owner.fileChanged(path) }
            }
        }
        stream = FSEventStreamCreate(nil,callback,&context,folders as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),2,FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream { FSEventStreamSetDispatchQueue(stream,DispatchQueue.main); FSEventStreamStart(stream) }
    }
    private var fileSeen: [String:Date] = [:]
    /// Folders whose contents are never treated as user activity (the app's own data and build products).
    var ignoredPaths: [String] = []
    private func fileChanged(_ path: String) {
        guard !runningAutomation, context() != nil, !path.contains("/Library/"), !path.contains("/."), !ignoredPaths.contains(where: { path.hasPrefix($0) }), Date().timeIntervalSince(fileSeen[path] ?? .distantPast) > 3 else { return }
        let url = URL(fileURLWithPath:path); let ext = url.pathExtension.lowercased()
        guard ["csv","png","jpg","jpeg","tiff","heic","pdf","xlsx","numbers"].contains(ext) else { return }
        fileSeen[path] = Date(); if fileSeen.count > 1000 { fileSeen = fileSeen.filter { Date().timeIntervalSince($0.value) < 3600 } }
        var details = ["path":path,"extension":ext,"folder":url.deletingLastPathComponent().path]
        let size = (try? FileManager.default.attributesOfItem(atPath:path))?[.size] as? NSNumber
        if ext == "csv", let size, size.intValue > 0, size.intValue < 65536, let data = try? String(contentsOf:url,encoding:.utf8) { details["csv"] = data }
        // Image dimensions only (no pixels are stored) so a resize can later be recognised.
        if ["png","jpg","jpeg","tiff","heic"].contains(ext), let source = CGImageSourceCreateWithURL(url as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any], let w = properties[kCGImagePropertyPixelWidth as String] as? Int, let h = properties[kCGImagePropertyPixelHeight as String] as? Int { details["pixels"] = "\(w)x\(h)" }
        guard let c = context() else { return }; var event = Event(app:c.app,kind:"file",role:ext,context:c.url.host ?? "",instance:digest(path)); event.selfGenerated = runningAutomation; onEvent?(Evidence(event,details))
    }
}
