import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import ScoutCore

@MainActor final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var automations: [Automation] = []
    @Published var activity: [RunRecord] = []
    /// Recent evidence for the memory page. Deliberately not @Published: it changes on every click anywhere on the Mac,
    /// and republishing it rebuilt the menu bar menu and the window while they were being used. The memory page refreshes itself.
    var events: [Evidence] = []
    @Published var memoryVersion = 0
    @Published var candidate: Candidate?
    @Published var judgment: Judgment?
    @Published var review: Automation?
    @Published var status = "Watching for routines"
    @Published var error = ""
    @Published var busy = false
    @Published var currentRun: RunRecord?
    @Published var pendingRuns: [(Automation,[String:String])] = []
    @Published var access = AXIsProcessTrusted()
    @Published var page = "home"
    @Published var policy = PrivacyPolicy()
    @Published var modelName = AIClient.knownModels.contains(UserDefaults.standard.string(forKey:"model") ?? "") ? UserDefaults.standard.string(forKey:"model")! : AIClient.defaultModel
    @Published var sharing = UserDefaults.standard.bool(forKey:"sharing")
    /// Use saved offline plans instead of Grok. Defaults to on only when no API key is available.
    @Published var offline = !KeyStore.available
    @Published var aiLog: [String] = []
    @Published var disclosure = ""
    @Published var askMessage: String?
    private var askContinuation: CheckedContinuation<Bool,Never>?
    let memory: Memory
    let runner: Runner
    let observer = Observer()
    let ax = Accessibility()
    let executor: MacExecutor
    let ai = AIClient()
    let practiceServer = PracticeServer()
    let triggers: Triggers
    private var timer: Timer?
    private var window: NSWindow?
    private var lastSuggestion = Date.distantPast
    private var judging = Set<String>()
    var dataDirectory: URL
    var selfTest: Bool { CommandLine.arguments.contains("--self-test") }
    override init() {
        if CommandLine.arguments.contains("--store-key") {
            // Setup without the UI: `RoutineScout --store-key < keyfile` stores the Grok key privately and exits.
            do { try KeyStore.save(String(decoding:FileHandle.standardInput.readDataToEndOfFile(),as:UTF8.self)); print("API key saved."); exit(0) } catch { print(error.localizedDescription); exit(1) }
        }
        dataDirectory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RoutineScout")
        if let index = CommandLine.arguments.firstIndex(of:"--self-test"), CommandLine.arguments.count > index+1 { dataDirectory = URL(fileURLWithPath:CommandLine.arguments[index+1]) }
        do { memory = try Memory(path:dataDirectory.appendingPathComponent("memory.sqlite").path) } catch { fatalError("Handoff could not open its local database: \(error.localizedDescription)") }
        runner = Runner(memory:memory); executor = MacExecutor(ax:ax); triggers = Triggers(memory:memory)
        super.init()
        runner.ui = executor
        policy = (try? memory.all(PrivacyPolicy.self,kind:"preferences").first) ?? PrivacyPolicy()
        lastSuggestion = (try? memory.all(Date.self,kind:"lastSuggestion").first) ?? .distantPast
        observer.policy = policy; ax.policy = { [weak self] in self?.policy ?? PrivacyPolicy() }
        observer.ignoredPaths = [dataDirectory.path, Bundle.main.bundleURL.deletingLastPathComponent().path]
        executor.lastInteraction = { [weak self] in self?.observer.lastInteraction ?? .distantPast }
        executor.interrupted = { [weak self] in self?.runner.stopRequested ?? true }
        observer.onEvent = { [weak self] e in self?.receive(e) }
        observer.onInteraction = { [weak self] in guard let self else { return }; if self.runner.active != nil && self.observer.runningAutomation { self.runner.stop() } }
        observer.onContext = { [weak self] app,url in guard let self else { return }; for a in self.triggers.contextMatches(app:app,url:url,automations:self.automations) { self.enqueue(a) } }
        runner.onChange = { [weak self] record in self?.currentRun = record }
        runner.onAsk = { [weak self] message in guard let self else { return false }; return await withCheckedContinuation { continuation in self.askContinuation = continuation; self.askMessage = message; self.show() } }
        UNUserNotificationCenter.current().delegate = self
        let category = UNNotificationCategory(identifier:"routine",actions:[UNNotificationAction(identifier:"run",title:"Do it",options:.foreground),UNNotificationAction(identifier:"skip",title:"Skip")],intentIdentifiers:[])
        let finished = UNNotificationCategory(identifier:"finished",actions:[UNNotificationAction(identifier:"undo",title:"Undo",options:.foreground)],intentIdentifiers:[])
        let suggest = UNNotificationCategory(identifier:"suggest",actions:[UNNotificationAction(identifier:"automate",title:"Automate",options:.foreground),UNNotificationAction(identifier:"later",title:"Not now")],intentIdentifiers:[])
        UNUserNotificationCenter.current().setNotificationCategories([category,finished,suggest])
        ai.onResponse = { [weak self] task,text in Task { @MainActor in guard let self else { return }; self.aiLog.append("[\(Date().formatted(date:.omitted,time:.standard))] \(task.prefix(60))…\n\(text.prefix(4000))"); if self.aiLog.count > 20 { self.aiLog.removeFirst() } } }
        reload()
        if !UserDefaults.standard.bool(forKey:"welcomed") { page = "welcome" }
    }
    /// Everything that touches the window server or event system runs here, from
    /// `applicationDidFinishLaunching`. This object is created inside the SwiftUI `App` initializer,
    /// before AppKit has finished launching; installing event monitors or ordering windows in that
    /// early phase produced a window that was drawn but never received clicks or keystrokes.
    func launch() {
        observer.start()
        // Ask for notification permission up front so the first suggestion can appear as a banner.
        Task { let center = UNUserNotificationCenter.current(); if await center.notificationSettings().authorizationStatus == .notDetermined { _ = try? await center.requestAuthorization(options:[.alert,.sound]) } }
        // A CSV opened in Numbers is an untitled document: find the file by name in the usual folders.
        let demoRoot = self.demoRoot
        AIClient.locateDocument = { name in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let stem = (name as NSString).deletingPathExtension
            for folder in [demoRoot, home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents")] {
                for candidate in [name, stem+".csv", stem+".numbers", stem+".xlsx"] {
                    let path = folder.appendingPathComponent(candidate).path
                    if FileManager.default.fileExists(atPath:path) { return path }
                }
            }
            return nil
        }
        timer = Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        // `--demo <case>` replays one of the five examples right after launch (used for rehearsing the presentation).
        if let index = CommandLine.arguments.firstIndex(of:"--demo"), CommandLine.arguments.count > index+1, Fixtures.shapes.contains(CommandLine.arguments[index+1]) {
            let shape = CommandLine.arguments[index+1]; DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { [weak self] in self?.show("home"); self?.demo(shape) }
        }
        if !CommandLine.arguments.contains("--background") { show() }
        if CommandLine.arguments.contains("--self-test") { sharing = false; policy.pausedUntil = nil; observer.policy = policy; Task { await self.integrationTests() } }
    }
    func show(_ selected: String? = nil) {
        if let selected { page = selected }
        // Agent apps (LSUIElement) never become the frontmost app, so WindowServer lets you drag the
        // title bar but clicks fall through to whatever is behind. Become a normal app first.
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            if let existing = NSApp.windows.first(where: { $0.title == "Handoff" && $0.contentView != nil }) {
                window = existing
            } else {
                let w = ScoutWindow(contentRect:NSRect(x:0,y:0,width:620,height:680),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
                w.title = "Handoff"; w.isReleasedWhenClosed = false; w.ignoresMouseEvents = false
                w.contentView = InteractiveHostingView(rootView:ScoutView(model:self)); w.center(); window = w
            }
        }
        window?.ignoresMouseEvents = false
        window?.makeKeyAndOrderFront(nil)
        window?.makeMain()
        NSApp.activate()
        NSRunningApplication.current.activate(options:[.activateAllWindows,.activateIgnoringOtherApps])
    }
    func allow() {
        sharing = true; UserDefaults.standard.set(true,forKey:"sharing"); UserDefaults.standard.set(true,forKey:"welcomed")
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) }
        page = "home"
    }
    func reload() {
        // Only publish when something actually changed; every publish rebuilds the menu bar menu and the window.
        do {
            try memory.prune(); try runner.pruneRuns()
            let a = try memory.all(Automation.self,kind:"automations").sorted { $0.name < $1.name }; if (try? JSONEncoder().encode(a)) != (try? JSONEncoder().encode(automations)) { automations = a }
            let r = try memory.all(RunRecord.self,kind:"runs").sorted { $0.started > $1.started }; if (try? JSONEncoder().encode(r)) != (try? JSONEncoder().encode(activity)) { activity = r }
            events = try memory.events(limit:500)
        } catch { self.error = error.localizedDescription }
    }
    func receive(_ e: Evidence) {
        guard !policy.paused else { return }
        do { try memory.add(e); if events.count > 500 { events.removeFirst() }; events.append(e); if page == "memory", window?.isVisible == true, e.event.kind != "focus" { memoryVersion += 1 }
            if e.event.kind == "file", let path = e.details["path"] { for a in try triggers.fileAppeared(path:path,automations:automations) { enqueue(a,values:["file":path]) } }
        } catch { self.error = error.localizedDescription }
    }
    func tick() {
        let trusted = AXIsProcessTrusted(); if trusted != access { access = trusted }; observer.policy = policy
        let current = policy.paused ? "Paused" : !access ? "Waiting for access" : runner.active != nil ? "Running a routine" : busy ? status : "Watching for routines"; if current != status { status = current }
        guard !policy.paused else { return }
        reload()
        do { for a in try triggers.scheduled(automations:automations) { enqueue(a) } } catch { self.error = error.localizedDescription }
        guard access, sharing, !busy, candidate == nil, runner.active == nil, Date().timeIntervalSince(observer.lastInteraction) > 5, Date().timeIntervalSince(lastSuggestion) >= 30 else { return }
        // Full-screen windows are treated as presentations; suggestions remain silent.
        if NSApp.currentSystemPresentationOptions.contains(.fullScreen) { return }
        detect()
    }
    func detect(prefer: Set<String> = []) {
        do {
            let suppressions = try memory.all(Suppression.self,kind:"suppression")
            let candidates = PatternFinder().candidates(try memory.events(limit:2000))
            let eligible: (Candidate) -> Bool = { c in !self.judging.contains(c.id) && !suppressions.contains { $0.id == c.id && $0.until > Date() } }
            guard let found = candidates.first(where: { prefer.contains($0.id) && eligible($0) }) ?? candidates.first(where:eligible) else { return }
            judging.insert(found.id); busy = true
            Task {
                defer { busy = false }
                do {
                    ai.model = modelName
                    status = "Asking Grok about a repeated procedure…"
                    let judged: Judgment = offline ? Fixtures.judgment(found.shape) : try await ai.judge(found)
                    status = "Watching for routines"
                    guard !policy.paused else { return }
                    if judged.isRoutine && judged.automatable {
                        candidate = found; judgment = judged; disclosure = try ai.disclosure(found); lastSuggestion = Date(); try memory.save(lastSuggestion,kind:"lastSuggestion",id:"last")
                        // The offer slides in beside the person's work without taking focus from it.
                        SuggestionPanel.present(model:self)
                        if selfTest || window?.isVisible == true { show("home") }
                    } else {
                        // Not a routine (or not automatable): remember that for a week so the same activity is not judged again.
                        try memory.save(Suppression(id:found.id,until:Date().addingTimeInterval(7*86400)),kind:"suppression",id:found.id)
                    }
                } catch { self.error = error.localizedDescription; status = "Watching for routines"; judging.remove(found.id) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func suppress(forever: Bool) {
        guard let candidate else { return }
        do { try memory.save(Suppression(id:candidate.id,until:forever ? .distantFuture : Date().addingTimeInterval(7*86400)),kind:"suppression",id:candidate.id); self.candidate = nil; judgment = nil } catch { self.error = error.localizedDescription }
    }
    func build() {
        guard let candidate else { return }; busy = true
        Task { defer { busy = false }; do {
            ai.model = modelName
            status = offline ? "Preparing the routine…" : "Grok is building the routine…"
            var built: Automation
            if offline { built = Fixtures.plan(candidate.shape,root:try prepareDemo().path) } else { built = try await ai.build(candidate) }
            // Demo evidence points at the demo folder and the local practice pages; make sure both exist so "Try it now" works.
            if replayedShape != nil {
                let root = try prepareDemo().path
                if built.inputs.isEmpty, let reference = Fixtures.plan(candidate.shape,root:root).inputs.first { built.inputs = [reference] }
                if ["loop","collect"].contains(candidate.shape) { try practiceServer.start(); openPractice(candidate.shape == "loop" ? "form" : "listing/0") }
            }
            review = built; status = "Watching for routines"
            show("review")
        } catch { self.error = error.localizedDescription } }
    }
    func save(_ a: Automation) {
        do { try Catalog.validate(a); try memory.save(a,kind:"automations",id:a.id); reload() } catch { self.error = error.localizedDescription }
    }
    func run(_ a: Automation, values: [String:String] = [:], resume: RunRecord? = nil) {
        guard !policy.paused else { error = "Resume watching before running a routine."; return }
        guard runner.active == nil else { error = "Another routine is already running."; return }
        // Demo routines start from sample files; recreate them so "Try it again" always has something to work on.
        if resume == nil, values.isEmpty, a.inputs.contains(where: { $0.value.hasPrefix(demoRoot.path) }) || a.steps.contains(where: { $0.parameters.contains { $0.value.hasPrefix(demoRoot.path) } }) { try? prepareDemo() }
        show("activity"); currentRun = RunRecord(a); busy = true
        Task {
            defer { observer.runningAutomation = false; busy = false; reload() }
            observer.runningAutomation = true
            do {
                let record = try await runner.run(a,values:values,resume:resume); currentRun = record
                if record.status == "succeeded" {
                    var saved = a; saved.tested = true; saved.cleanRuns += 1
                    if review?.id == a.id { review = saved; page = "review" }
                    save(saved)
                    if let candidate { try memory.deleteDetails(eventIDs:candidate.instances.flatMap { $0.map { $0.event.id } }); self.candidate = nil; judgment = nil; disclosure = "" }
                    notify(title:a.name,body:record.message,category:record.canUndo ? "finished" : "",id:record.id)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func choose(_ t: RunTrigger) { guard var a = review, a.tested else { return }; a.trigger = t; a.enabled = true; review = a; save(a); page = "home" }
    func enqueue(_ a: Automation, values: [String:String] = [:]) {
        guard !policy.paused, !pendingRuns.contains(where: { $0.0.id == a.id }), runner.active?.automation.id != a.id else { return }
        if a.mode == "automatic", runner.active == nil { run(a,values:values) }
        else { pendingRuns.append((a,values)); notify(title:"Ready to \(a.name.lowercased())?",body:"Open Handoff to run or skip this one.",category:"routine",id:a.id) }
    }
    func answer(_ yes: Bool) { askContinuation?.resume(returning:yes); askContinuation = nil; askMessage = nil }
    func stop() { runner.stop(); answer(false) }
    func pause(_ duration: TimeInterval) { policy.pausedUntil = duration == 0 ? nil : Date().addingTimeInterval(duration); observer.policy = policy; stop(); savePolicy(); status = policy.paused ? "Paused" : "Watching for routines" }
    func savePolicy() { observer.policy = policy; UserDefaults.standard.set(sharing,forKey:"sharing"); UserDefaults.standard.set(modelName,forKey:"model"); do { try memory.save(policy,kind:"preferences",id:"privacy") } catch { self.error = error.localizedDescription } }
    func undo(_ record: RunRecord) { do { currentRun = try runner.undo(record); reload() } catch { self.error = error.localizedDescription } }
    func edit(_ words: String) { guard let a = review, !words.isEmpty else { return }; busy = true; Task { defer { busy = false }; do { ai.model = modelName; review = try await ai.edit(a,words:words) } catch { self.error = error.localizedDescription } } }
    func fix(_ record: RunRecord) {
        guard record.pc < record.automation.steps.count, let target = record.automation.steps[record.pc].target else { error = "This failure does not involve a page item. Check the file or input named in the message."; return }
        busy = true; Task { defer { busy = false }; do { let snapshot = try ax.snapshot(app:target.app); disclosure = snapshot; let corrected = try await ai.fix(record.automation.steps[record.pc],snapshot:snapshot); var proposed = record.automation; proposed.steps[record.pc] = corrected; proposed.tested = false; proposed.enabled = false; proposed.mode = "ask"; proposed.cleanRuns = 0; review = proposed; page = "review" } catch { self.error = error.localizedDescription } }
    }
    func deleteAll() {
        guard runner.active == nil else { error = "Stop the running routine first."; return }
        do { try memory.erase(); KeyStore.delete(); candidate = nil; review = nil; currentRun = nil; judgment = nil; pendingRuns = []; disclosure = ""; judging = []; sharing = false; policy = PrivacyPolicy(); policy.pausedUntil = .distantFuture; savePolicy(); reload() } catch { self.error = error.localizedDescription }
    }
    /// The demo folder. It lives inside Downloads so file triggers can be shown live, but in its own folder so it never mixes with real files.
    var demoRoot: URL { selfTest ? dataDirectory.appendingPathComponent("Demo") : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Handoff Demo") }
    /// Creates the sample files that the five demo routines start from.
    @discardableResult func prepareDemo() throws -> URL {
        let root = demoRoot; try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        // Reset the outputs of earlier tries so the routines can run again from a clean start.
        for leftover in ["Invoices","Web","sales-0-clean.csv","addresses-drive-times.csv"] { try? FileManager.default.removeItem(at:root.appendingPathComponent(leftover)) }
        try Fixtures.addressesCSV.write(to:root.appendingPathComponent("addresses.csv"),atomically:true,encoding:.utf8)
        for stale in (try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? [] where stale.hasSuffix("-resized.png") { try? FileManager.default.removeItem(at:root.appendingPathComponent(stale)) }
        try "Name,Amount,Unused\n Bea ,$20,x\n Ada ,$10,y\n".write(to:root.appendingPathComponent("sales-0.csv"),atomically:true,encoding:.utf8)
        try "Name,Email\nAda,ada@example.test\nBea,bea@example.test\nCy,cy@example.test\n".write(to:root.appendingPathComponent("people.csv"),atomically:true,encoding:.utf8)
        if !FileManager.default.fileExists(atPath:root.appendingPathComponent("Apartment Search.csv").path) { try "Name,Price,Link\n".write(to:root.appendingPathComponent("Apartment Search.csv"),atomically:true,encoding:.utf8) }
        try DemoFiles.pdf(title:"Invoice 8731").write(to:root.appendingPathComponent("invoice-8731.pdf"))
        try DemoFiles.png(width:1440,height:900).write(to:root.appendingPathComponent("Screenshot \(Runner.dateString(Date())) at 10.00.png"))
        return root
    }
    /// The shape of the demo routine most recently replayed, so the built plan can be pointed at the demo files and pages.
    private(set) var replayedShape: String?
    /// Opens a practice page in Safari (the only browser the practice routines are written for).
    func openPractice(_ path: String) {
        let url = URL(string:PracticeServer.base+"/"+path)!
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Safari") { NSWorkspace.shared.open([url],withApplicationAt:safari,configuration:NSWorkspace.OpenConfiguration()) } else { NSWorkspace.shared.open(url) }
    }
    /// Skips detection and goes straight to a ready-made routine for one of the five demo cases.
    func practice(_ shape: String) {
        do {
            let root = try prepareDemo()
            if ["loop","collect"].contains(shape) { try practiceServer.start(); openPractice(shape == "loop" ? "form" : "listing/0") }
            replayedShape = shape; review = Fixtures.plan(shape,root:root.path); show("review")
        } catch { self.error = error.localizedDescription }
    }
    /// Replays three recorded repetitions of a routine exactly as the observer would have stored them, then runs the normal
    /// detection path: pattern finder → Grok judge → suggestion notification and card → Automate → Grok build → review → Try it.
    func demo(_ shape: String = "transform") {
        do {
            if policy.paused { pause(0) }
            let root = try prepareDemo()
            // Forget earlier replays of this case so the suggestion can appear again.
            let previous = PatternFinder().candidates(Fixtures.evidence(shape,root:root.path)).map(\.id)
            for id in previous { try memory.delete(kind:"suppression",id:id); judging.remove(id) }
            for e in Fixtures.evidence(shape,root:root.path) { try memory.add(e) }
            replayedShape = shape; candidate = nil; judgment = nil; lastSuggestion = .distantPast; reload(); detect(prefer:Set(previous))
            if candidate == nil && !busy { error = "No routine was found in the replayed activity. Try again after a moment." }
        } catch { self.error = error.localizedDescription }
    }
    private func notify(title: String,body: String,category: String,id: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.categoryIdentifier = category; content.userInfo = ["id":id]; content.sound = .default
        let request = UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:nil)
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined { _ = try? await center.requestAuthorization(options:[.alert,.sound]); settings = await center.notificationSettings() }
            if settings.authorizationStatus == .denied { await MainActor.run { self.error = "Turn on notifications for Handoff in System Settings → Notifications to see its banners." } }
            try? await center.add(request)
        }
    }
    /// Show banners even while Handoff is the frontmost app (macOS hides them by default).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner,.list,.sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            let id = response.notification.request.content.userInfo["id"] as? String ?? ""
            if response.actionIdentifier == "undo", let run = self.activity.first(where:{$0.id == id}) { self.undo(run) }
            else if response.notification.request.content.categoryIdentifier == "suggest" {
                if response.actionIdentifier == "later" { self.suppress(forever:false) } else if response.actionIdentifier == "automate" { self.show("home"); self.build() } else { self.show("home") }
            }
            else if let index = self.pendingRuns.firstIndex(where:{$0.0.id == id}) { if response.actionIdentifier == "run" { let pending = self.pendingRuns.remove(at:index); self.run(pending.0,values:pending.1) } else if response.actionIdentifier == "skip" { self.pendingRuns.remove(at:index) } else { self.show() } }
        }
    }
}
