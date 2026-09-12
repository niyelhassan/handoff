import Foundation
import CoreGraphics
import ImageIO
import ScoutCore

final class CoreTests {
    var cleanups: [() -> Void] = []
    func addTeardownBlock(_ action: @escaping () -> Void) { cleanups.append(action) }
    func cleanup() { for action in cleanups { action() }; cleanups = [] }
    func temporary() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineScoutTests-"+UUID().uuidString); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url }
    func testCSVQuotedUnicodeAndCRLF() throws {
        let source = "Name,Note,Value\r\n\"Zoë, 王\",\"line 1\nline \"\"two\"\"\",42\r\nAda,,0\r\n"
        let table = try Table.parse(source)
        XCTAssertEqual(table.rows[0],["Zoë, 王","line 1\nline \"two\"","42"])
        XCTAssertEqual(try Table.parse(table.csv),table)
        XCTAssertThrowsError(try Table.parse("A,B\n1\n")); XCTAssertThrowsError(try Table.parse("A,A\n1,2")); XCTAssertThrowsError(try Table.parse("A\n\"oops"))
    }
    func testTransforms() throws {
        var t = try Table.parse("Name,Amount,Date,Empty\n Bea ,$20,09/11/2026,\n Ada ,$10,09/10/2026,\n")
        try t.transform(action:"trim",column:"",value:"")
        try t.transform(action:"parseNumbers",column:"Amount",value:"")
        try t.transform(action:"sort",column:"Amount",value:"ascending")
        try t.transform(action:"formatDates",column:"Date",value:"{\"from\":\"MM/dd/yyyy\",\"to\":\"yyyy-MM-dd\"}")
        try t.transform(action:"template",column:"Summary",value:"{{row.Name}}: {{row.Amount}}")
        XCTAssertEqual(t.rows[0],["Ada","10","2026-09-10","","Ada: 10"])
        try t.transform(action:"filter",column:"Name",value:"^A"); XCTAssertEqual(t.rows.count,1)
        try t.transform(action:"dropColumns",column:"",value:"[\"Empty\"]")
        try t.transform(action:"renameColumn",column:"Name",value:"Person"); XCTAssertEqual(t.columns[0],"Person")
    }
    func testLeadPatternsFiveRehearsals() throws {
        for _ in 0..<5 { for shape in ["transform","loop","collect"] {
            let candidates = PatternFinder().candidates(Fixtures.evidence(shape))
            XCTAssertEqual(candidates.count,1,"\(shape)")
            XCTAssertEqual(candidates.first?.count,3,"\(shape)")
            if shape != "collect" { XCTAssertEqual(candidates.first?.shape,shape) }
        } }
    }
    func testNegativePatternsAndDuplicateInstances() {
        let navigation = (0..<50).map { i in Evidence(Event(app:"browser",kind:"click",label:"Tab \(i%4)",instance:"\(i)")) }
        XCTAssertTrue(PatternFinder().candidates(navigation).isEmpty)
        var same = Fixtures.evidence("collect"); for i in same.indices { same[i].event.instance = "same-page" }
        XCTAssertTrue(PatternFinder().candidates(same).isEmpty)
        var selfEvents = Fixtures.evidence("loop"); for i in selfEvents.indices { selfEvents[i].event.selfGenerated = true }
        XCTAssertTrue(PatternFinder().candidates(selfEvents).isEmpty)
    }
    func testPrivacyCanaries() {
        var policy = PrivacyPolicy()
        XCTAssertFalse(policy.permits(app:"com.1password.1password",domain:"",role:"",window:""))
        XCTAssertFalse(policy.permits(app:"browser",domain:"secure.chase.com",role:"",window:""))
        XCTAssertFalse(policy.permits(app:"browser",domain:"example.com",role:"AXSecureTextField",window:""))
        XCTAssertFalse(policy.permits(app:"browser",domain:"example.com",role:"",window:"New Incognito Window"))
        XCTAssertFalse(policy.permits(app:"browser",domain:"example.com",role:"",window:"Private Browsing"))
        XCTAssertTrue(policy.permits(app:"browser",domain:"notchase.com",role:"AXTextField",window:"Normal"))
        policy.pausedUntil = Date().addingTimeInterval(60)
        XCTAssertFalse(policy.permits(app:"browser",domain:"example.com",role:"",window:""))
    }
    func testMemoryRetentionAndDurability() throws {
        let root = try temporary(); let path = root.appendingPathComponent("test.sqlite").path; let now = Date()
        do {
            let db = try Memory(path:path)
            try db.add(Evidence(Event(app:"test",kind:"copy",time:now.addingTimeInterval(-49*3600)),["text":"expired-canary"]))
            try db.add(Evidence(Event(app:"test",kind:"copy",time:now.addingTimeInterval(-15*86400)),["text":"old-canary"]))
            try db.add(Evidence(Event(app:"test",kind:"copy",time:now),["text":"fresh-canary"]))
            try db.prune(now:now)
        }
        let reopened = try Memory(path:path); let records = try reopened.events(now:now)
        XCTAssertEqual(records.count,2); XCTAssertTrue(records[0].details.isEmpty); XCTAssertEqual(records[1].details["text"],"fresh-canary")
        let bytes = try Data(contentsOf:URL(fileURLWithPath:path)); XCTAssertNil(bytes.range(of:Data("expired-canary".utf8))); XCTAssertNil(bytes.range(of:Data("old-canary".utf8)))
        try reopened.erase(); XCTAssertTrue(try reopened.events().isEmpty)
    }
    func testSchemaRejectsUnknownUnsafeAndInvalidLoops() throws {
        let root = try temporary(); try Catalog.validate(Fixtures.cleanup(root:root.path))
        XCTAssertThrowsError(try JSONDecoder().decode(Operation.self,from:Data("\"shell\"".utf8)))
        XCTAssertThrowsError(try Catalog.validate(Automation(name:"bad",description:"",steps:[Step(.openURL,"Open",["url":"file:///etc/passwd"])])))
        XCTAssertThrowsError(try Catalog.validate(Automation(name:"bad",description:"",steps:[Step(.endLoop,"End")])))
        var automatic = Fixtures.form(root:root.path); automatic.mode = "automatic"; automatic.tested = true; automatic.cleanRuns = 3
        XCTAssertThrowsError(try Catalog.validate(automatic))
        automatic.allowIrreversible = true; XCTAssertNoThrow(try Catalog.validate(automatic))
    }
    @MainActor func testClientFoldersDetectedAndCreated() async throws {
        let root = try temporary()
        XCTAssertEqual(PatternFinder().candidates(Fixtures.evidence("folders",root:root.path)).first?.shape,"folders")
        try Fixtures.clientsCSV.write(to:root.appendingPathComponent("clients.csv"),atomically:true,encoding:.utf8)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Clients/Acme Robotics"),withIntermediateDirectories:true)
        let runner = Runner(memory:try Memory(path:":memory:"))
        let plan = Fixtures.clientFolders(root:root.path); XCTAssertNoThrow(try Catalog.validate(plan))
        let run = try await runner.run(plan); XCTAssertEqual(run.status,"succeeded",run.message)
        for client in Fixtures.clients { XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("Clients/\(client)").path),client) }
        // A Grok plan that forgot the row variable is repaired to name folders after the row.
        var sloppy = plan; sloppy.steps[2] = Step(.createFolder,"Make folder",["path":root.path+"/Clients"])
        XCTAssertEqual(AIClient.repair(sloppy).steps[2].args["path"],root.path+"/Clients/{{row.first}}")
    }
    @MainActor func testDriveTimesDetectedAndRunLive() async throws {
        let root = try temporary()
        let candidates = PatternFinder().candidates(Fixtures.evidence("travel",root:root.path))
        XCTAssertEqual(candidates.first?.shape,"travel","address → maps → minutes should be detected as a travel routine")
        try Fixtures.addressesCSV.write(to:root.appendingPathComponent("addresses.csv"),atomically:true,encoding:.utf8)
        let runner = Runner(memory:try Memory(path:root.appendingPathComponent("memory.sqlite").path))
        let plan = Fixtures.driveTimes(root:root.path); XCTAssertNoThrow(try Catalog.validate(plan))
        let started = Date(); let run = try await runner.run(plan)
        XCTAssertEqual(run.status,"succeeded",run.message)
        let table = try Table.parse(String(contentsOf:root.appendingPathComponent("addresses-drive-times.csv")))
        XCTAssertEqual(table.rows.count,Fixtures.addresses.count)
        for row in table.rows { print("   \(row[0]) → \(row[1]) min"); XCTAssertTrue(Int(row[1]).map { $0 > 0 && $0 < 120 } ?? false,"minutes for \(row[0])") }
        print("   \(table.rows.count) real routes in \(Int(Date().timeIntervalSince(started))) s")
    }
    @MainActor func testRealCSVEndToEndFiveTimesAndUndo() async throws {
        let root = try temporary(); let db = try Memory(path:root.appendingPathComponent("memory.sqlite").path); let runner = Runner(memory:db)
        let source = "Name,Amount,Unused\n Bea ,$20,x\n Ada ,$10,y\n"
        try source.write(to:root.appendingPathComponent("sales-0.csv"),atomically:true,encoding:.utf8)
        for _ in 0..<5 {
            let run = try await runner.run(Fixtures.cleanup(root:root.path))
            XCTAssertEqual(run.status,"succeeded",run.message)
            XCTAssertEqual(try Table.parse(String(contentsOf:root.appendingPathComponent("sales-0-clean.csv"))),Table(columns:["Name","Amount"],rows:[["Ada","10"],["Bea","20"]]))
            let undone = try runner.undo(run); XCTAssertEqual(undone.status,"undone"); XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("sales-0-clean.csv").path))
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("sales-0.csv")),source)
        }
    }
    @MainActor func testUndoProtectsEditsAndMoveRoundTrip() async throws {
        let root = try temporary(); let db = try Memory(path:":memory:"); let runner = Runner(memory:db)
        let source = root.appendingPathComponent("source.txt"); let dest = root.appendingPathComponent("moved.txt"); try "original".write(to:source,atomically:true,encoding:.utf8)
        let automation = Automation(name:"Move",description:"",steps:[Step(.moveFile,"Move file",["source":source.path,"destination":dest.path])])
        let run = try await runner.run(automation); XCTAssertEqual(run.status,"succeeded"); XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))
        _ = try runner.undo(run); XCTAssertEqual(try String(contentsOf:source),"original"); XCTAssertFalse(FileManager.default.fileExists(atPath:dest.path))
        let again = try await runner.run(automation); try "user edit".write(to:dest,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try runner.undo(again)); XCTAssertEqual(try String(contentsOf:dest),"user edit")
    }
    @MainActor func testLoopResumeNeverDuplicatesRows() async throws {
        let root = try temporary(); let db = try Memory(path:root.appendingPathComponent("memory.sqlite").path)
        let output = root.appendingPathComponent("result.csv")
        let a = Automation(name:"Loop",description:"",steps:[Step(.forEach,"Each item",["source":"[\"Ada\",\"Bea\",\"Cy\"]","item":"person"]),Step(.appendCSV,"Append",["path":output.path,"columns":"[\"Name\"]","values":"[\"{{person}}\"]"]),Step(.ask,"Continue?",["message":"Continue?"]),Step(.endLoop,"End")])
        let first = Runner(memory:db); var asked = 0
        first.onAsk = { _ in asked += 1; return asked != 2 }
        let stopped = try await first.run(a); XCTAssertEqual(stopped.status,"failed"); XCTAssertNil(stopped.pending)
        XCTAssertEqual(try Table.parse(String(contentsOf:output)).rows.count,2)
        let second = Runner(memory:try Memory(path:root.appendingPathComponent("memory.sqlite").path)); second.onAsk = { _ in true }
        let resumed = try await second.run(a,resume:stopped); XCTAssertEqual(resumed.status,"succeeded",resumed.message)
        XCTAssertEqual(try Table.parse(String(contentsOf:output)).rows,[["Ada"],["Bea"],["Cy"]])
        _ = try second.undo(resumed); XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
    }
    @MainActor func testUncertainActionWillNotRepeat() async throws {
        let runner = Runner(memory:try Memory(path:":memory:")); let a = Automation(name:"Ask",description:"",steps:[Step(.ask,"Ask",["message":"Continue?"])])
        var interrupted = RunRecord(a); interrupted.pending = a.steps[0].id
        do { _ = try await runner.run(a,resume:interrupted); XCTFail("Should refuse an uncertain action") } catch { XCTAssertTrue(error.localizedDescription.contains("uncertain")) }
    }
    func testTriggerDedupAfterRestart() throws {
        let db = try Memory(path:":memory:"); var a = Fixtures.cleanup(root:"/tmp"); a.tested = true; a.enabled = true; a.trigger = RunTrigger("schedule",title:"Daily",value:"09:00")
        let calendar = Calendar(identifier:.gregorian); let now = calendar.date(from:DateComponents(year:2026,month:9,day:12,hour:12))!
        XCTAssertEqual(try Triggers(memory:db).scheduled(automations:[a],now:now,calendar:calendar).count,1)
        XCTAssertEqual(try Triggers(memory:db).scheduled(automations:[a],now:now,calendar:calendar).count,0)
        XCTAssertEqual(try Triggers(memory:db).scheduled(automations:[a],now:now.addingTimeInterval(86400),calendar:calendar).count,1)
    }
    func testAIJSONSchemaSerialization() throws { XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:Catalog.buildSchema)); XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:Catalog.judgeSchema)) }
    func testAllFiveDemoPatternsDetected() throws {
        for shape in Fixtures.shapes {
            let candidates = PatternFinder().candidates(Fixtures.evidence(shape))
            XCTAssertEqual(candidates.count,1,shape); XCTAssertEqual(candidates.first?.shape,shape == "collect" ? candidates.first?.shape : shape,shape); XCTAssertEqual(candidates.first?.count,3,shape)
        }
    }
    @MainActor func testReferencePlansRunForFileCases() async throws {
        let root = try temporary(); try demoFiles(root)
        let db = try Memory(path:":memory:"); let runner = Runner(memory:db)
        for shape in ["transform","pipeline","image"] {
            let plan = Fixtures.plan(shape,root:root.path); try Catalog.validate(plan)
            let run = try await runner.run(plan); XCTAssertEqual(run.status,"succeeded",shape+": "+run.message)
            try verifyOutputs(shape,root:root)
            _ = try runner.undo(run)
        }
    }
    /// Judges, builds, validates and (where no other app is needed) runs all five demo routines through the real Grok API.
    @MainActor func testLiveGrokAllFiveCases() async throws {
        guard ProcessInfo.processInfo.environment["SCOUT_LIVE_TEST"] == "1" else { throw XCTSkip("Set SCOUT_LIVE_TEST=1 to test the real API using synthetic examples.") }
        guard KeyStore.available else { throw ScoutError.message("No Grok API key found (XAI_API_KEY or the key file).") }
        let root = try temporary(); try demoFiles(root)
        let planDirectory = URL(fileURLWithPath:ProcessInfo.processInfo.environment["SCOUT_PLAN_DIR"] ?? FileManager.default.currentDirectoryPath+"/TestResults/grok-plans"); try FileManager.default.createDirectory(at:planDirectory,withIntermediateDirectories:true)
        let ai = AIClient(model:ProcessInfo.processInfo.environment["SCOUT_MODEL"] ?? AIClient.defaultModel)
        let db = try Memory(path:":memory:"); let runner = Runner(memory:db); runner.onAsk = { _ in true }
        var failures: [String] = []
        let only = ProcessInfo.processInfo.environment["SCOUT_LIVE_SHAPES"]?.split(separator:",").map(String.init)
        for shape in Fixtures.shapes where only == nil || only!.contains(shape) {
            let candidate = try XCTUnwrap(PatternFinder().candidates(Fixtures.evidence(shape,root:root.path)).first)
            do {
                let t0 = Date(); let judgment = try await ai.judge(candidate); let judgeTime = Int(Date().timeIntervalSince(t0))
                print("  \(shape) judge (\(judgeTime)s): routine=\(judgment.isRoutine) automatable=\(judgment.automatable) “\(judgment.name)” — \(judgment.reason)")
                guard judgment.isRoutine, judgment.automatable else { failures.append("\(shape): Grok did not consider it automatable (\(judgment.reason))"); continue }
                let t1 = Date(); let plan = try await ai.build(candidate); print("  \(shape) build took \(Int(Date().timeIntervalSince(t1)))s")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                try encoder.encode(plan).write(to:planDirectory.appendingPathComponent(shape+".json"))
                print("  \(shape) plan “\(plan.name)”: "+plan.steps.map { $0.operation.rawValue+($0.target.map { "[\($0.label.isEmpty ? $0.identifier : $0.label)]" } ?? "")+"("+$0.parameters.filter { !$0.value.isEmpty }.map { $0.key+"="+$0.value.prefix(40) }.joined(separator:", ")+")" }.joined(separator:" → "))
                print("  \(shape) triggers: "+plan.suggestedTriggers.map { $0.kind+($0.value.isEmpty ? "" : ":"+$0.value)+($0.app.isEmpty ? "" : "@"+$0.app) }.joined(separator:", "))
                try Catalog.validate(plan)
                switch shape {
                case "transform","pipeline","image":
                    try demoFiles(root)
                    let run = try await runner.run(plan); guard run.status == "succeeded" else { failures.append("\(shape): run \(run.status): \(run.message)"); continue }
                    try verifyOutputs(shape,root:root)
                    XCTAssertTrue(plan.suggestedTriggers.contains { $0.kind == "file" },"\(shape) should suggest a file trigger")
                case "folders":
                    try Fixtures.clientsCSV.write(to:root.appendingPathComponent("clients.csv"),atomically:true,encoding:.utf8)
                    try? FileManager.default.removeItem(at:root.appendingPathComponent("Clients")); try FileManager.default.createDirectory(at:root.appendingPathComponent("Clients/Acme Robotics"),withIntermediateDirectories:true)
                    let run = try await runner.run(plan); guard run.status == "succeeded" else { failures.append("folders: run \(run.status): \(run.message)"); continue }
                    let missing = Fixtures.clients.filter { !FileManager.default.fileExists(atPath:root.appendingPathComponent("Clients/\($0)").path) }
                    guard missing.isEmpty else { failures.append("folders: not created: \(missing)"); continue }
                case "travel":
                    guard plan.steps.contains(where: { $0.operation == .driveTime }), plan.steps.contains(where: { $0.operation == .appendCSV }) else { failures.append("travel: expected driveTime and appendCSV"); continue }
                case "loop":
                    let ops = plan.steps.map(\.operation)
                    guard ops.contains(.forEach), ops.contains(.endLoop), ops.contains(.readCSV) else { failures.append("loop: missing readCSV/forEach"); continue }
                    let labels = plan.steps.filter { [.setValue,.pasteValue].contains($0.operation) }.compactMap { $0.target?.label.lowercased() }
                    guard labels.contains("name"), labels.contains("email") else { failures.append("loop: fills \(labels), expected name and email"); continue }
                    guard let submit = plan.steps.firstIndex(where: { $0.operation == .click }), submit > 0, plan.steps[submit-1].operation == .ask else { failures.append("loop: submit must be preceded by ask"); continue }
                    guard plan.steps.allSatisfy({ $0.target == nil || $0.target?.app == "com.apple.Safari" }) else { failures.append("loop: wrong app"); continue }
                default:
                    let reads = plan.steps.filter { [.readText,.copyText].contains($0.operation) }.compactMap { $0.target?.label.lowercased() }
                    guard reads.contains("listing name"), reads.contains("price") else { failures.append("collect: reads \(reads), expected listing name and price"); continue }
                    guard plan.steps.contains(where: { $0.operation == .readURL }), plan.steps.contains(where: { $0.operation == .appendCSV || $0.operation == .numbersAppend }) else { failures.append("collect: expected readURL and appendCSV"); continue }
                }
            } catch { failures.append("\(shape): \(error.localizedDescription)") }
        }
        XCTAssertTrue(failures.isEmpty,failures.joined(separator:" | "))
    }
    func testPlanRepairGuardrails() throws {
        let sloppy = Automation(name:"x",description:"",steps:[
            Step(.readCSV,"Read destination",["path":"/tmp/out.csv","output":"existing"]),
            Step(.readCSV,"Read people",["path":"/tmp/people.csv","output":"people"]),
            Step(.forEach,"Loop",["source":"{{people}}","item":"row"]),
            Step(.readURL,"Link",["output":"url"]),
            Step(.setValue,"Name",["value":"{{row.Name}}"],target:Target(app:"com.apple.Safari",role:"AXTextField",label:"Name")),
            Step(.click,"Submit",target:Target(app:"com.apple.Safari",role:"AXButton",label:"Submit")),
            Step(.endLoop,"End")
        ])
        let repaired = AIClient.repair(sloppy)
        XCTAssertEqual(repaired.steps.map(\.operation),[.readCSV,.forEach,.readURL,.setValue,.ask,.click,.endLoop])
        XCTAssertEqual(repaired.steps[0].args["output"],"people")
        XCTAssertEqual(repaired.steps[2].target?.app,"com.apple.Safari")
        XCTAssertEqual(Set(repaired.steps.map(\.id)).count,repaired.steps.count)
        // File binding turns the observed input into variables.
        let candidate = try XCTUnwrap(PatternFinder().candidates(Fixtures.evidence("pipeline",root:"/tmp/RS")).first)
        let literal = Automation(name:"y",description:"",steps:[Step(.moveFile,"Move",["source":"/tmp/RS/invoice-8731.pdf","destination":"/tmp/RS/Invoices/\(Runner.dateString(Date()))-invoice-8731.pdf"])])
        let bound = AIClient.bindFiles(literal,candidate:candidate)
        XCTAssertEqual(bound.steps[0].args["source"],"{{file}}"); XCTAssertEqual(bound.steps[0].args["destination"],"{{folder}}/Invoices/{{today}}-{{stem}}.pdf"); XCTAssertEqual(bound.inputs.first?.value,"/tmp/RS/invoice-8731.pdf")
    }
    func demoFiles(_ root: URL) throws {
        for stale in (try? FileManager.default.contentsOfDirectory(atPath:root.path)) ?? [] where stale.hasSuffix("-clean.csv") || stale.hasSuffix("-resized.png") || ["Invoices","Web"].contains(stale) { try? FileManager.default.removeItem(at:root.appendingPathComponent(stale)) }
        try "Name,Amount,Unused\n Bea ,$20,x\n Ada ,$10,y\n".write(to:root.appendingPathComponent("sales-0.csv"),atomically:true,encoding:.utf8)
        try "Name,Price,Link\n".write(to:root.appendingPathComponent("Apartment Search.csv"),atomically:true,encoding:.utf8)
        try "Name,Email\nAda,ada@example.test\nBea,bea@example.test\nCy,cy@example.test\n".write(to:root.appendingPathComponent("people.csv"),atomically:true,encoding:.utf8)
        try Data("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".utf8).write(to:root.appendingPathComponent("invoice-8731.pdf"))
        try samplePNG(width:1440,height:900).write(to:root.appendingPathComponent("Screenshot \(Runner.dateString(Date())) at 10.00.png"))
    }
    func samplePNG(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { throw ScoutError.message("no image") }
        let output = NSMutableData(); guard let writer = CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil) else { throw ScoutError.message("no writer") }
        CGImageDestinationAddImage(writer,image,nil); CGImageDestinationFinalize(writer); return output as Data
    }
    func verifyOutputs(_ shape: String, root: URL) throws {
        let files = (try? FileManager.default.subpathsOfDirectory(atPath:root.path)) ?? []
        switch shape {
        case "transform":
            let clean = files.first { $0.hasSuffix("-clean.csv") }; XCTAssertNotNil(clean,"clean CSV written")
            if let clean { XCTAssertEqual(try Table.parse(String(contentsOf:root.appendingPathComponent(clean),encoding:.utf8)).rows,[["Ada","10"],["Bea","20"]]) }
        case "pipeline":
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("invoice-8731.pdf").path),"invoice moved out of the download folder")
            let filed = files.first { $0.hasPrefix("Invoices/") && $0.hasSuffix(".pdf") && $0.contains("8731") && $0.contains(Runner.dateString(Date())) }
            XCTAssertNotNil(filed,"invoice filed with today's date: \(files)")
        default:
            let web = files.first { $0.lowercased().hasSuffix(".jpg") || $0.lowercased().hasSuffix(".jpeg") }; XCTAssertNotNil(web,"JPEG written: \(files)")
            if let web, let source = CGImageSourceCreateWithURL(root.appendingPathComponent(web) as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] { XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int,1280,"resized to 1280 wide") } else { XCTFail("JPEG unreadable") }
        }
    }
}
func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?,_ message: String = "",file: StaticString = #filePath,line: UInt = #line) { do { if try value() == nil { fail("Expected a value. "+message,file:file,line:line) } } catch { fail(error.localizedDescription,file:file,line:line) } }
