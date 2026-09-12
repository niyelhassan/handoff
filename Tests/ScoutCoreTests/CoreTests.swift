import Foundation
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
    @MainActor func testRealCSVEndToEndFiveTimesAndUndo() async throws {
        let root = try temporary(); let db = try Memory(path:root.appendingPathComponent("memory.sqlite").path); let runner = Runner(memory:db)
        let source = "Name,Amount,Unused\n Bea ,$20,x\n Ada ,$10,y\n"
        try source.write(to:root.appendingPathComponent("sales.csv"),atomically:true,encoding:.utf8)
        for _ in 0..<5 {
            let run = try await runner.run(Fixtures.cleanup(root:root.path))
            XCTAssertEqual(run.status,"succeeded",run.message)
            XCTAssertEqual(try Table.parse(String(contentsOf:root.appendingPathComponent("clean.csv"))),Table(columns:["Name","Amount"],rows:[["Ada","10"],["Bea","20"]]))
            let undone = try runner.undo(run); XCTAssertEqual(undone.status,"undone"); XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("clean.csv").path))
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("sales.csv")),source)
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
    func testLiveGrokJudgeAndBuild() async throws {
        guard ProcessInfo.processInfo.environment["SCOUT_LIVE_TEST"] == "1" else { throw XCTSkip("Set SCOUT_LIVE_TEST=1 to test the real API using synthetic examples.") }
        let candidate = try XCTUnwrap(PatternFinder().candidates(Fixtures.evidence("transform")).first)
        let ai = AIClient(); ai.onBuild = { a in print("  Live plan operations: "+a.steps.map { $0.operation.rawValue+"("+$0.parameters.map { $0.key }.joined(separator:",")+")" }.joined(separator:", ")) }; let judgment = try await ai.judge(candidate)
        XCTAssertTrue(judgment.isRoutine); XCTAssertTrue(judgment.automatable)
        let a = try await ai.build(candidate); XCTAssertFalse(a.steps.isEmpty); try Catalog.validate(a)
    }
}
