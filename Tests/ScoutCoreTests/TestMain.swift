import Foundation
import ScoutCore
// Portable assertions: this Mac has Command Line Tools but no Xcode XCTest framework.
var assertionFailures = 0
func fail(_ message: String, file: StaticString, line: UInt) { assertionFailures += 1; print("  FAIL \(file):\(line): \(message)") }
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool,_ message: String = "",file: StaticString = #filePath,line: UInt = #line) { do { if try !value() { fail("Expected true. "+message,file:file,line:line) } } catch { fail(error.localizedDescription,file:file,line:line) } }
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool,_ message: String = "",file: StaticString = #filePath,line: UInt = #line) { do { if try value() { fail("Expected false. "+message,file:file,line:line) } } catch { fail(error.localizedDescription,file:file,line:line) } }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T,_ b: @autoclosure () throws -> T,_ message: String = "",file: StaticString = #filePath,line: UInt = #line) { do { let av = try a(); let bv = try b(); if av != bv { fail("\(av) != \(bv). "+message,file:file,line:line) } } catch { fail(error.localizedDescription,file:file,line:line) } }
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?,file: StaticString = #filePath,line: UInt = #line) { do { if try value() != nil { fail("Expected nil",file:file,line:line) } } catch { fail(error.localizedDescription,file:file,line:line) } }
func XCTAssertThrowsError<T>(_ action: @autoclosure () throws -> T,file: StaticString = #filePath,line: UInt = #line) { do { _ = try action(); fail("Expected an error",file:file,line:line) } catch {} }
func XCTAssertNoThrow<T>(_ action: @autoclosure () throws -> T,file: StaticString = #filePath,line: UInt = #line) { do { _ = try action() } catch { fail(error.localizedDescription,file:file,line:line) } }
func XCTFail(_ message: String,file: StaticString = #filePath,line: UInt = #line) { fail(message,file:file,line:line) }
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw ScoutError.message("Expected non-nil value") }; return value }
struct XCTSkip: Error { var message: String; init(_ message: String) { self.message = message } }
@main struct TestMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--store-key") { do { let data = FileHandle.standardInput.readDataToEndOfFile(); try KeyStore.save(String(decoding:data,as:UTF8.self)); print("API key saved.") } catch { print(error.localizedDescription); exit(1) }; return }
        let suite = CoreTests(); var passed = 0; var skipped = 0
        func run(_ name: String,_ body: () async throws -> Void) async { let before = assertionFailures; do { try await body(); if assertionFailures == before { passed += 1; print("PASS \(name)") } } catch let skip as XCTSkip { skipped += 1; print("SKIP \(name): \(skip.message)") } catch { assertionFailures += 1; print("FAIL \(name): \(error)") }; suite.cleanup() }
        await run("CSV quoted Unicode and CRLF") { try suite.testCSVQuotedUnicodeAndCRLF() }
        await run("Table transformations") { try suite.testTransforms() }
        await run("Lead patterns × five rehearsals") { try suite.testLeadPatternsFiveRehearsals() }
        await run("Negative patterns, duplicate identity, self activity") { suite.testNegativePatternsAndDuplicateInstances() }
        await run("Privacy canaries") { suite.testPrivacyCanaries() }
        await run("SQLite retention and reopen") { try suite.testMemoryRetentionAndDurability() }
        await run("Catalog rejection and automatic mode safety") { try suite.testSchemaRejectsUnknownUnsafeAndInvalidLoops() }
        await run("Real CSV end to end × five plus Undo") { try await suite.testRealCSVEndToEndFiveTimesAndUndo() }
        await run("File move round trip and Undo conflict") { try await suite.testUndoProtectsEditsAndMoveRoundTrip() }
        await run("Loop resume across database reopen") { try await suite.testLoopResumeNeverDuplicatesRows() }
        await run("Uncertain action refuses replay") { try await suite.testUncertainActionWillNotRepeat() }
        await run("Schedule catch-up dedup across restart") { try suite.testTriggerDedupAfterRestart() }
        await run("AI JSON schemas") { try suite.testAIJSONSchemaSerialization() }
        await run("All five demo patterns detected") { try suite.testAllFiveDemoPatternsDetected() }
        await run("Reference plans run for file cases") { try await suite.testReferencePlansRunForFileCases() }
        await run("Client folders: detected, created, sloppy plan repaired") { try await suite.testClientFoldersDetectedAndCreated() }
        await run("Drive times: detected and run against live routing") { try await suite.testDriveTimesDetectedAndRunLive() }
        await run("Plan repair guardrails and file binding") { try suite.testPlanRepairGuardrails() }
        await run("Live Grok: all five cases") { try await suite.testLiveGrokAllFiveCases() }
        print("\n\(passed) passed, \(skipped) skipped, \(assertionFailures) assertion failures")
        exit(assertionFailures == 0 ? 0 : 1)
    }
}
