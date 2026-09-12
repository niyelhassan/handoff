import Foundation
import AppKit
import ScoutCore

/// Native rehearsal launched with `RoutineScout --self-test <directory>`.
/// It drives real Safari pages served locally, real Accessibility reads/writes, and real files, and writes `integration-report.txt`.
extension AppModel {
    func integrationTests() async {
        var report: [String] = []
        func log(_ text: String) { report.append(text); print(text); try? report.joined(separator:"\n").write(to:dataDirectory.appendingPathComponent("integration-report.txt"),atomically:true,encoding:.utf8) }
        log("Native integration test started. Accessibility: \(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else { log("BLOCKED: Accessibility permission is not available to this build. Allow Routine Scout in System Settings → Privacy & Security → Accessibility, then rerun."); finish(); return }
        do {
            let root = try prepareDemo()
            try practiceServer.start(); practiceServer.reset()
            guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Safari") else { throw ScoutError.message("Safari is unavailable.") }
            func openPage(_ path: String) async throws {
                let url = URL(string:PracticeServer.base+"/"+path)!
                try await NSWorkspace.shared.open([url],withApplicationAt:safari,configuration:NSWorkspace.OpenConfiguration())
                // Wait until the page is really exposed through Accessibility rather than sleeping a fixed time.
                for _ in 0..<20 { if (try? ax.snapshot(app:"com.apple.Safari"))?.contains(path.hasPrefix("form") ? "AXTextField | Name" : "AXTextField | Listing name") == true { return }; try await Task.sleep(for:.milliseconds(250)) }
                throw ScoutError.message("Safari did not show the practice page \(path).")
            }
            runner.onAsk = { _ in true }
            try await openPage("form")
            // The snapshot contains only the local synthetic practice page, never another app.
            try ax.snapshot(app:"com.apple.Safari").write(to:dataDirectory.appendingPathComponent("practice-form-structure.txt"),atomically:true,encoding:.utf8)
            for rehearsal in 1...5 {
                observer.runningAutomation = true
                let result = try await runner.run(Fixtures.form(root:root.path))
                observer.runningAutomation = false
                log("Form rehearsal \(rehearsal): \(result.status). \(result.message)")
                guard result.status == "succeeded" else { try? ax.snapshot(app:"com.apple.Safari").write(to:dataDirectory.appendingPathComponent("failure-structure.txt"),atomically:true,encoding:.utf8); throw ScoutError.message(result.message) }
                let (data,_) = try await URLSession.shared.data(from:URL(string:PracticeServer.base+"/status")!)
                let submitted = try JSONDecoder().decode([[String:String]].self,from:data)
                guard submitted.count == rehearsal*3, submitted.last?["Name"] == "Cy", submitted.last?["Email"] == "cy@example.test" else { throw ScoutError.message("The server did not receive exactly three correct new rows (has \(submitted.count)).") }
                log("Verified server has \(submitted.count) correct submissions.")
            }
            for rehearsal in 1...5 {
                try await openPage("listing/\((rehearsal-1)%3)")
                observer.runningAutomation = true
                let result = try await runner.run(Fixtures.collector(root:root.path))
                observer.runningAutomation = false
                log("Collector rehearsal \(rehearsal): \(result.status). \(result.message)")
                guard result.status == "succeeded" else { throw ScoutError.message(result.message) }
                let table = try Table.parse(String(contentsOf:root.appendingPathComponent("Apartment Search.csv"),encoding:.utf8))
                let expected = ["Maple Loft","Oak Studio","Pine House"][(rehearsal-1)%3]
                guard table.rows.last?[0].hasPrefix(expected) == true, table.rows.last?[1] == "\(1200+((rehearsal-1)%3)*100)", table.rows.last?[2].hasPrefix(PracticeServer.base) == true else { throw ScoutError.message("The collected values did not match the visible listing: \(table.rows.last ?? [])") }
                _ = try runner.undo(result); log("Verified collected values and exact Undo.")
            }
            for rehearsal in 1...5 {
                let result = try await runner.run(Fixtures.cleanup(root:root.path))
                log("CSV rehearsal \(rehearsal): \(result.status)")
                guard result.status == "succeeded", try Table.parse(String(contentsOf:root.appendingPathComponent("sales-0-clean.csv"),encoding:.utf8)).rows == [["Ada","10"],["Bea","20"]] else { throw ScoutError.message("CSV output did not match the expected table.") }
                _ = try runner.undo(result)
            }
            // Field Undo: fill the form without submitting, then restore the original (empty) values.
            try await openPage("form")
            let fillOnly = Automation(name:"Fill only",description:"",steps:Array(Fixtures.form(root:root.path).steps.dropFirst().filter { [.setValue].contains($0.operation) }).map { step in var s = step; s.parameters = s.parameters.map { $0.key == "value" ? Parameter("value",step.title.contains("name") ? "Undo Test" : "undo@example.test") : $0 }; return s })
            observer.runningAutomation = true
            let filled = try await runner.run(fillOnly)
            observer.runningAutomation = false
            guard filled.status == "succeeded" else { throw ScoutError.message("Field fill failed: \(filled.message)") }
            guard axString(try ax.resolve(Target(app:"com.apple.Safari",role:"AXTextField",label:"Name")),kAXValueAttribute) == "Undo Test" else { throw ScoutError.message("The field was not filled.") }
            do { _ = try runner.undo(filled) } catch {
                let now = executor.contextIdentity("com.apple.Safari")
                log("Field Undo diagnostics: stored contexts \(filled.fieldUndo.map { $0.context }), current \(now); values \(filled.fieldUndo.map { axString((try? ax.resolve($0.target)) ?? AXUIElementCreateSystemWide(),kAXValueAttribute) }) expected \(filled.fieldUndo.map(\.after))")
                throw error
            }
            guard axString(try ax.resolve(Target(app:"com.apple.Safari",role:"AXTextField",label:"Name")),kAXValueAttribute).isEmpty else { throw ScoutError.message("Field Undo did not restore the empty field.") }
            log("Verified field fill and field Undo.")
            // Grok-built routines for the two web cases, run for real against the practice pages.
            var grokRuns = 0
            if KeyStore.available && !CommandLine.arguments.contains("--offline") {
                ai.model = modelName
                for shape in ["loop","collect"] {
                    guard let candidate = PatternFinder().candidates(Fixtures.evidence(shape,root:root.path)).first else { throw ScoutError.message("No candidate for \(shape).") }
                    let judged = try await ai.judge(candidate); guard judged.isRoutine, judged.automatable else { throw ScoutError.message("Grok rejected \(shape): \(judged.reason)") }
                    var plan = try await ai.build(candidate)
                    // The demo table lives in the demo folder; point any CSV path there.
                    plan.inputs = plan.inputs.map { $0.key == "file" && !$0.value.hasPrefix(root.path) ? Parameter("file",root.appendingPathComponent(URL(fileURLWithPath:$0.value).lastPathComponent).path) : $0 }
                    for i in plan.steps.indices where [.readCSV,.appendCSV].contains(plan.steps[i].operation) { plan.steps[i].parameters = plan.steps[i].parameters.map { $0.key == "path" && $0.value.hasPrefix("/") && !$0.value.hasPrefix(root.path) ? Parameter("path",root.appendingPathComponent(URL(fileURLWithPath:$0.value).lastPathComponent).path) : $0 } }
                    log("Grok plan for \(shape): "+plan.steps.map { $0.operation.rawValue+($0.target.map { "[\($0.label)]" } ?? "") }.joined(separator:" → "))
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; try? encoder.encode(plan).write(to:dataDirectory.appendingPathComponent("grok-\(shape).json"))
                    let before = practiceServer.submissionCount
                    try await openPage(shape == "loop" ? "form" : "listing/1")
                    observer.runningAutomation = true
                    let result = try await runner.run(plan)
                    observer.runningAutomation = false
                    log("Grok-built \(shape): \(result.status). \(result.message)")
                    guard result.status == "succeeded" else { throw ScoutError.message("Grok-built \(shape) failed: \(result.message)") }
                    if shape == "loop" { guard practiceServer.submissionCount == before+3 else { throw ScoutError.message("Grok-built form loop submitted \(practiceServer.submissionCount-before) forms, expected 3.") } }
                    else {
                        let csv = plan.steps.first { $0.operation == .appendCSV }?.args["path"].map { $0.replacingOccurrences(of:"{{file}}",with:plan.inputs.first { $0.key == "file" }?.value ?? "") }
                        guard let csv, let table = try? Table.parse(String(contentsOf:URL(fileURLWithPath:csv),encoding:.utf8)), let last = table.rows.last, last.contains { $0.contains("Oak Studio") }, last.contains("1300") else { throw ScoutError.message("Grok-built collector did not record the listing.") }
                    }
                    grokRuns += 1
                }
            } else { log("Grok-built routines skipped (no API key or --offline).") }
            log("PASS: \(16+grokRuns) native rehearsals; form server submissions, listing CSV values and Undo, CSV golden outputs and Undo, field Undo verified\(grokRuns > 0 ? ", plus \(grokRuns) Grok-built routines run live" : "").")
        } catch {
            let idle = Date().timeIntervalSince(observer.lastInteraction)
            if idle < 30 { log("INTERRUPTED: you used the keyboard or mouse \(Int(idle)) s ago, so the rehearsal stopped as designed. Rerun while leaving the Mac idle.") }
            log("FAIL: "+error.localizedDescription)
        }
        finish()
    }
    private func finish() {
        observer.runningAutomation = false; policy.pausedUntil = .distantFuture; observer.policy = policy
        currentRun = runner.active; reload(); show("activity")
        if CommandLine.arguments.contains("--exit-after-test") { DispatchQueue.main.asyncAfter(deadline:.now()+1) { NSApp.terminate(nil) } }
    }
}
