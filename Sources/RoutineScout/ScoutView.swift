import SwiftUI
import ServiceManagement
import ScoutCore

struct ScoutView: View {
    @ObservedObject var model: AppModel
    @State private var words = ""
    @State private var key = ""
    @State private var ignoredApp = ""
    @State private var ignoredSite = ""
    @State private var confirmErase = false
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Image(systemName:"sparkle.magnifyingglass").font(.title).foregroundStyle(.teal)
                VStack(alignment:.leading) { Text("Handoff").font(.title2.bold()); Text(model.status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.policy.paused ? "Resume" : "Pause") { model.pause(model.policy.paused ? 0 : 3600) }
            }.padding(22)
            if model.page != "welcome" {
                HStack { nav("home","Routines"); nav("activity","Activity"); nav("memory","What I remember"); nav("preferences","Preferences") }.padding(.horizontal,20).padding(.bottom,12)
            }
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if !model.error.isEmpty { HStack(alignment:.top) { Image(systemName:"exclamationmark.circle"); Text(model.error).textSelection(.enabled); Spacer(); Button { model.error = "" } label: { Image(systemName:"xmark") } }.padding().background(.orange.opacity(0.12),in:RoundedRectangle(cornerRadius:12)) }
                    if let message = model.askMessage { GroupBox("Ready for the next step") { VStack(alignment:.leading,spacing:12) { Text(message); HStack { Button("Continue") { model.answer(true) }.buttonStyle(.borderedProminent); Button("Skip this one") { model.answer(false) } } }.frame(maxWidth:.infinity,alignment:.leading).padding(8) } }
                    switch model.page {
                    case "welcome": welcome
                    case "review": review
                    case "activity": activity
                    case "preferences": preferences
                    case "memory": memory
                    default: home
                    }
                }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.frame(minWidth:560,minHeight:600).background(Color(nsColor:.windowBackgroundColor))
        .alert("Delete everything?",isPresented:$confirmErase) { Button("Delete",role:.destructive) { model.deleteAll() }; Button("Cancel",role:.cancel) {} } message: { Text("This removes remembered activity, routines, history and the saved API key. Files created by routines remain where they are.") }
    }
    func nav(_ page: String,_ title: String) -> some View { Button(title) { model.page = page }.buttonStyle(.bordered).tint(model.page == page ? .teal : .gray) }
    var welcome: some View {
        VStack(alignment:.leading,spacing:20) {
            Image(systemName:"leaf.circle.fill").font(.system(size:64)).foregroundStyle(.teal)
            Text("Let the small repeats take care of themselves.").font(.largeTitle.bold())
            Text("Handoff notices procedures you repeat and offers to handle them. You review and try every routine before it can run again.")
            Text("Activity stays on your Mac. A few examples of a repeated procedure are shared with Grok to understand and build it. No screenshots or ordinary typing are recorded. You can turn sharing off or pause at any time.").foregroundStyle(.secondary)
            Button("Allow access") { model.allow() }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("macOS will ask you to allow access. Notifications are optional.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical,24)
    }
    var home: some View {
        VStack(alignment:.leading,spacing:20) {
            if !model.access { GroupBox("Allow access to notice routines") { VStack(alignment:.leading,spacing:10) { Text("Turn on Handoff in System Settings → Privacy & Security → Accessibility, then return here."); Button("Open access settings") { model.allow() } }.padding(8) } }
            if let c = model.candidate, let j = model.judgment {
                GroupBox {
                    VStack(alignment:.leading,spacing:14) {
                        Text("You’ve done this \(c.count) times").font(.caption.bold()).foregroundStyle(.teal)
                        Text(j.name).font(.title2.bold()); Text(j.description)
                        HStack { Button("Automate") { model.build() }.buttonStyle(.borderedProminent).disabled(model.busy); Button("Not now") { model.suppress(forever:false) }; Button("Never for this") { model.suppress(forever:true) } }
                        DisclosureGroup("What was shared") { Text(model.disclosure).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }
                    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            ForEach(Array(model.pendingRuns.enumerated()),id:\.element.0.id) { index,pending in
                GroupBox("Ready to \(pending.0.name.lowercased())?") { HStack { Button("Do it") { let item = model.pendingRuns.remove(at:index); model.run(item.0,values:item.1) }.buttonStyle(.borderedProminent); Button("Skip") { model.pendingRuns.remove(at:index) }; Spacer() }.padding(8) }
            }
            Text("Your automations").font(.headline)
            if model.automations.isEmpty { VStack(alignment:.leading,spacing:8) { Text("Nothing to set up.").font(.title3.bold()); Text("Go about your day. When a procedure repeats, you’ll see an offer here.").foregroundStyle(.secondary) }.padding(.vertical,20) }
            ForEach(model.automations) { a in
                GroupBox {
                    VStack(alignment:.leading,spacing:10) {
                        HStack { Text(a.name).font(.headline); Spacer(); Toggle("Enabled",isOn:Binding(get:{ a.enabled },set:{ value in var changed = a; changed.enabled = value; if !changed.tested && value { model.error = "Try this routine successfully before enabling it." } else { model.save(changed) } })).labelsHidden() }
                        Text(a.description).foregroundStyle(.secondary)
                        Text(a.trigger.title).font(.caption)
                        HStack { Button("Run now") { model.run(a) }.disabled(model.busy); Button("Review") { model.review = a; model.page = "review" }; Spacer(); Button("Remove",role:.destructive) { try? model.memory.delete(kind:"automations",id:a.id); model.reload() } }
                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }
    }
    var review: some View {
        VStack(alignment:.leading,spacing:16) {
            if let a = model.review {
                Text(a.name).font(.title.bold()); Text(a.description)
                ForEach(Array(a.steps.enumerated()),id:\.element.id) { i,step in
                    HStack(alignment:.top) { Text("\(i+1)").font(.caption.bold()).frame(width:24,height:24).background(.teal.opacity(0.12),in:Circle()); VStack(alignment:.leading,spacing:4) { Text(step.title); if step.operation.irreversible { Text("This action cannot be undone automatically.").font(.caption).foregroundStyle(.orange) } } }
                }
                DisclosureGroup("Details and information shared") { VStack(alignment:.leading) { Text(model.disclosure.isEmpty ? a.description : model.disclosure).font(.system(.caption,design:.monospaced)).textSelection(.enabled); ForEach(a.steps) { step in Text(step.title+": "+step.parameters.map { $0.key+" = "+$0.value }.joined(separator:"; ")).font(.caption).textSelection(.enabled) } } }
                HStack { TextField("Edit with words…",text:$words); Button("Apply") { model.edit(words); words = "" }.disabled(words.isEmpty || model.busy || model.offline) }
                Button(a.tested ? "Try it again" : "Try it now") { model.run(a) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                if a.tested {
                    Divider(); Text("When should this run?").font(.headline)
                    ForEach(a.suggestedTriggers) { trigger in Button(trigger.title) { model.choose(trigger) } }
                    if a.cleanRuns >= 3 {
                        Toggle("Run without asking",isOn:Binding(get:{ a.mode == "automatic" },set:{ value in var updated = a; updated.mode = value ? "automatic" : "ask"; do { try Catalog.validate(updated); model.review = updated; model.save(updated) } catch { model.error = error.localizedDescription } }))
                        if a.steps.contains(where: { $0.operation.irreversible }) { Toggle("Allow actions that cannot be undone",isOn:Binding(get:{a.allowIrreversible},set:{value in var updated = a; updated.allowIrreversible = value; if !value { updated.mode = "ask" }; model.review = updated; model.save(updated) })) }
                    }
                } else { Text("You’ll choose when it runs after a successful test.").font(.caption).foregroundStyle(.secondary) }
            } else { Text("Choose a routine to review.") }
        }
    }
    var activity: some View {
        VStack(alignment:.leading,spacing:16) {
            if let run = model.currentRun {
                GroupBox(run.automation.name) {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(Array(run.completed.enumerated()),id:\.offset) { _,title in Label(title,systemImage:"checkmark.circle.fill").foregroundStyle(.teal) }
                        if run.status == "running", run.pc < run.automation.steps.count { HStack { ProgressView().controlSize(.small); Text(run.automation.steps[run.pc].title) }; Button("Stop",role:.destructive) { model.stop() } }
                        else { Text(run.message); runActions(run) }
                    }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            Text("Recent activity").font(.headline)
            if model.activity.isEmpty { Text("Completed and interrupted runs will appear here.").foregroundStyle(.secondary) }
            ForEach(model.activity.prefix(40)) { run in
                VStack(alignment:.leading,spacing:6) { HStack { Text(run.automation.name).font(.headline); Spacer(); Text(run.started,style:.date).font(.caption) }; Text(run.message.isEmpty ? run.status.capitalized : run.message).foregroundStyle(.secondary); runActions(run) }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:12))
            }
        }
    }
    @ViewBuilder func runActions(_ run: RunRecord) -> some View {
        HStack {
            if run.canUndo { Button(run.irreversible ? "Undo file changes" : "Undo") { model.undo(run) } }
            if ["stopped","failed","running"].contains(run.status), model.runner.active == nil {
                if run.pending == nil { Button("Continue") { model.run(run.automation,resume:run) } }
                Button("Fix") { model.fix(run) }.disabled(model.busy || model.offline)
            }
        }
    }
    var memory: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("What I remember").font(.title2.bold()); Text("Activity expires after 14 days. Copied text, page addresses, filenames and field values expire after 48 hours. Undo copies expire after one minute.").foregroundStyle(.secondary)
            Text("\(model.events.count) recent events").font(.headline).id(model.memoryVersion)
            ForEach(model.events.reversed().prefix(200),id:\.event.id) { evidence in DisclosureGroup { ForEach(evidence.details.keys.sorted(),id:\.self) { key in Text(key+": "+(evidence.details[key] ?? "")).font(.caption).textSelection(.enabled) } } label: { VStack(alignment:.leading) { Text(evidence.event.kind.capitalized+" · "+(evidence.event.label.isEmpty ? evidence.event.role : evidence.event.label)); Text(evidence.event.app+" · "+evidence.event.time.formatted()).font(.caption).foregroundStyle(.secondary) } } }
        }
    }
    var preferences: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Preferences").font(.title2.bold())
            Toggle("Share repeated examples with Grok",isOn:$model.sharing).onChange(of:model.sharing) { model.savePolicy() }
            Text("Only a few examples of a detected routine are sent. Use What I remember to inspect local activity.").font(.caption).foregroundStyle(.secondary)
            HStack { SecureField("Grok API key",text:$key); Button("Save key") { do { try KeyStore.save(key); key = "" } catch { model.error = error.localizedDescription } }.disabled(key.isEmpty) }
            Text(KeyStore.read() == nil ? "No API key saved." : "API key saved privately on this Mac.").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("Grok model",text:$model.modelName); Button("Save") { model.savePolicy() } }
            Toggle("Start at login",isOn:Binding(get:{ SMAppService.mainApp.status == .enabled },set:{ value in do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { model.error = error.localizedDescription } }))
            Divider(); Text("Apps to ignore").font(.headline)
            ForEach(model.policy.ignoredApps,id:\.self) { app in HStack { Text(app).font(.caption); Spacer(); Button("Remove") { model.policy.ignoredApps.removeAll { $0 == app }; model.savePolicy() } } }
            HStack { TextField("App identifier (for example com.apple.mail)",text:$ignoredApp); Button("Add") { if !ignoredApp.isEmpty { model.policy.ignoredApps.append(ignoredApp.trimmingCharacters(in:.whitespacesAndNewlines)); ignoredApp = ""; model.savePolicy() } } }
            Text("Websites to ignore").font(.headline)
            Text(model.policy.ignoredSites.joined(separator:", ")).font(.caption)
            HStack { TextField("Website, for example example.com",text:$ignoredSite); Button("Add") { let raw = ignoredSite.lowercased().trimmingCharacters(in:.whitespacesAndNewlines); if !raw.isEmpty { model.policy.ignoredSites.append(URL(string:raw.contains("://") ? raw : "https://"+raw)?.host ?? raw); ignoredSite = ""; model.savePolicy() } } }
            Divider(); Text("Try an example").font(.headline)
            Text("Replay three recorded repetitions of a routine: Handoff notices it, asks Grok whether it is worth automating, and offers it just like it would after watching you. Sample files live in Downloads › Handoff Demo; practice web pages run locally in Safari.").font(.caption).foregroundStyle(.secondary)
            Text("Replay a routine being repeated").font(.subheadline)
            HStack { ForEach(Fixtures.shapes,id:\.self) { shape in Button(Fixtures.title(shape)) { model.demo(shape) } } }.disabled(model.busy)
            Text("Open a ready-made routine (skips detection)").font(.subheadline)
            HStack { ForEach(Fixtures.shapes,id:\.self) { shape in Button(Fixtures.title(shape)) { model.practice(shape) } } }.disabled(model.busy)
            Toggle("Use saved offline plans instead of Grok",isOn:$model.offline)
            if !model.aiLog.isEmpty { DisclosureGroup("Recent Grok responses") { ForEach(Array(model.aiLog.reversed().enumerated()),id:\.offset) { _,entry in Text(entry).font(.system(.caption,design:.monospaced)).textSelection(.enabled).padding(.bottom,6) } } }
            Divider(); Button("Delete everything",role:.destructive) { confirmErase = true }
        }
    }
}
