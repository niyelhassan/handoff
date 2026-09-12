import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

public struct UndoEntry: Codable {
    public var path: String
    public var before: Data?
    public var afterHash: String?
    public init(path: String, before: Data?, after: Data?) { self.path = path; self.before = before; self.afterHash = after.map { digest($0.base64EncodedString()) } }
}
public struct FieldUndo: Codable {
    public var target: Target
    public var before: String
    public var after: String
    public var context: String
    public init(target: Target, before: String, after: String, context: String) { self.target = target; self.before = before; self.after = after; self.context = context }
}
public struct LoopFrame: Codable {
    public var start: Int
    public var end: Int
    public var item: String
    public var rows: [[String:String]]
    public var index: Int
}
public struct RunRecord: Codable, Identifiable {
    public var id = UUID().uuidString
    public var automation: Automation
    public var started = Date()
    public var updated = Date()
    public var status = "running"
    public var message = ""
    public var pc = 0
    public var completed: [String] = []
    public var pending: String?
    public var values: [String:String] = [:]
    public var tables: [String:Table] = [:]
    public var loops: [LoopFrame] = []
    public var undo: [UndoEntry] = []
    public var irreversible = false
    public var fieldUndo: [FieldUndo] = []
    public init(_ automation: Automation, values: [String:String] = [:]) { self.automation = automation; self.values = values }
    public var canUndo: Bool { (!undo.isEmpty || !fieldUndo.isEmpty) && Date().timeIntervalSince(updated) <= 60 && status != "undone" && status != "running" }
}
@MainActor public protocol UIExecuting: AnyObject {
    func execute(_ step: Step, args: [String:String]) async throws -> [String:String]
    func beforeRun() async throws
    /// Bring the step's app forward before undo state is captured or the action runs.
    func focus(_ step: Step) async throws
    func validate(_ step: Step) throws
    func prepareUndo(_ step: Step, args: [String:String]) async throws -> FieldUndo?
    func checkUndo(_ entry: FieldUndo) throws
    func undo(_ entry: FieldUndo) throws
}
public extension UIExecuting {
    func focus(_ step: Step) async throws {}
    func prepareUndo(_ step: Step, args: [String:String]) async throws -> FieldUndo? { nil }
    func checkUndo(_ entry: FieldUndo) throws { throw ScoutError.message("Field Undo is unavailable.") }
    func undo(_ entry: FieldUndo) throws { throw ScoutError.message("Field Undo is unavailable.") }
}
@MainActor public final class Runner {
    public let memory: Memory
    public weak var ui: UIExecuting?
    public var onChange: ((RunRecord) -> Void)?
    public var onAsk: ((String) async -> Bool)?
    public private(set) var active: RunRecord?
    public var stopRequested = false
    public init(memory: Memory, ui: UIExecuting? = nil) { self.memory = memory; self.ui = ui }
    public func stop() { stopRequested = true }
    /// yyyy-MM-dd in the user's calendar; the value of {{today}}.
    public nonisolated static func dateString(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from:date) }
    private func save(_ record: inout RunRecord) throws { record.updated = Date(); try memory.save(record,kind:"runs",id:record.id); active = record; onChange?(record) }
    public func run(_ automation: Automation, values: [String:String] = [:], resume: RunRecord? = nil) async throws -> RunRecord {
        guard active == nil else { throw ScoutError.message("Another routine is already running.") }
        try Catalog.validate(automation)
        var initial = Dictionary(automation.inputs.map { ($0.key,$0.value) },uniquingKeysWith: { _,b in b }); initial.merge(values,uniquingKeysWith: { _,b in b })
        if let path = initial["file"] { let url = URL(fileURLWithPath:path); initial["folder"] = url.deletingLastPathComponent().path; initial["stem"] = url.deletingPathExtension().lastPathComponent; initial["filename"] = url.lastPathComponent; initial["ext"] = url.pathExtension }
        initial["today"] = initial["today"] ?? Self.dateString(Date())
        initial["home"] = FileManager.default.homeDirectoryForCurrentUser.path
        var record = resume ?? RunRecord(automation,values:initial)
        guard record.pending == nil else { throw ScoutError.message("The app stopped during an action. Inspect its result before retrying; it will not repeat an uncertain action.") }
        guard Date().timeIntervalSince(record.started) < 48*3600 else { throw ScoutError.message("This run is too old to resume. Its temporary inputs have expired.") }
        record.status = "running"; stopRequested = false
        try save(&record)
        defer { active = nil }
        do {
            if automation.steps.contains(where:{ $0.operation.touchesUI }) { guard let ui else { throw ScoutError.message("This action needs access to the other app.") }; try await ui.beforeRun() }
            var budget = 10000
            while record.pc < automation.steps.count {
                try Task.checkCancellation(); guard !stopRequested else { throw ScoutError.message("Stopped. Completed steps are saved.") }
                budget -= 1; guard budget > 0 else { throw ScoutError.message("This run reached its 10,000-step limit.") }
                let step = automation.steps[record.pc]
                let args = try step.args.mapValues { try interpolateArgument($0,values:record.values) }
                if step.operation == .forEach {
                    let end = try matchingEnd(automation.steps,start:record.pc,opening:.forEach,closing:.endLoop)
                    // The source is a table name (written plainly or as {{name}}) or a JSON list.
                    var name = (step.args["source"] ?? "").trimmingCharacters(in:.whitespaces); let rows: [[String:String]]
                    if name.hasPrefix("{{"), name.hasSuffix("}}") { name = String(name.dropFirst(2).dropLast(2)).trimmingCharacters(in:.whitespaces) }
                    if let table = record.tables[name] ?? record.tables[args["source"] ?? ""] ?? (record.tables.count == 1 && !name.hasPrefix("[") ? record.tables.values.first : nil) { rows = table.records() } else {
                        guard let list = try? JSONDecoder().decode([String].self,from:Data((args["source"] ?? "").utf8)) else { throw ScoutError.message("The loop needs a table read earlier (‘\(name)’ was not found) or a list of values.") }
                        rows = list.map { ["value":$0] }
                    }
                    guard rows.count <= 1000 else { throw ScoutError.message("A run can process at most 1,000 items.") }
                    if rows.isEmpty { record.pc = end+1 } else { let frame = LoopFrame(start:record.pc,end:end,item:args["item"]!,rows:rows,index:0); record.loops.append(frame); bind(frame,&record); record.pc += 1 }
                    try save(&record); continue
                }
                if step.operation == .endLoop {
                    guard var frame = record.loops.popLast() else { throw ScoutError.message("The repeating steps lost their place.") }
                    frame.index += 1
                    if frame.index < frame.rows.count { bind(frame,&record); record.loops.append(frame); record.pc = frame.start+1 } else { record.pc += 1 }
                    try save(&record); continue
                }
                if step.operation == .ifMatches {
                    let re = try NSRegularExpression(pattern:args["pattern"]!); let value = args["value"]!
                    record.pc = re.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) == nil ? try matchingEnd(automation.steps,start:record.pc,opening:.ifMatches,closing:.endIf)+1 : record.pc+1
                    try save(&record); continue
                }
                if step.operation == .endIf { record.pc += 1; try save(&record); continue }
                record.pending = step.id; try save(&record)
                do { try await execute(step,args:args,record:&record) }
                catch { // Read-only failures are safe to retry. Writes remain uncertain unless prepared atomically below.
                    if [.readCSV,.transformTable,.readText,.readURL,.waitForElement,.waitForFile,.ask,.numbersRead,.excelRead,.mailRead].contains(step.operation) { record.pending = nil }
                    throw error
                }
                record.completed.append(step.title); record.pending = nil; record.pc += 1; try save(&record)
                await Task.yield()
            }
            record.status = "succeeded"; record.message = "Finished \(record.completed.count) steps."
            try save(&record); return record
        } catch {
            record.status = stopRequested || error is CancellationError ? "stopped" : "failed"
            record.message = error.localizedDescription; try save(&record); return record
        }
    }
    private func bind(_ frame: LoopFrame, _ record: inout RunRecord) {
        record.values = record.values.filter { !$0.key.hasPrefix(frame.item+".") }
        for (key,value) in frame.rows[frame.index] { record.values[frame.item+"."+key] = value }
        record.values[frame.item+".index"] = String(frame.index)
        if let value = frame.rows[frame.index]["value"] { record.values[frame.item] = value }
    }
    private func matchingEnd(_ steps: [Step], start: Int, opening: Operation, closing: Operation) throws -> Int {
        var depth = 0
        for i in start..<steps.count { if steps[i].operation == opening { depth += 1 }; if steps[i].operation == closing { depth -= 1; if depth == 0 { return i } } }
        throw ScoutError.message("A group of steps is unfinished.")
    }
    private func file(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ScoutError.message("A file needs a full local path.") }
        return URL(fileURLWithPath:path).standardizedFileURL
    }
    private func read(_ url: URL) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 20_000_000 else { throw ScoutError.message("This file is larger than the 20 MB limit.") }
        return try Data(contentsOf:url)
    }
    private func write(_ data: Data, to url: URL, record: inout RunRecord, allowExisting: Bool) throws {
        let exists = FileManager.default.fileExists(atPath:url.path)
        guard allowExisting || !exists else { throw ScoutError.message("A file already exists at \(url.lastPathComponent). Choose another name.") }
        let before = exists ? try read(url) : nil
        record.undo.append(UndoEntry(path:url.path,before:before,after:data)); try save(&record)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
        guard try read(url) == data else { throw ScoutError.message("The saved file did not match the intended result.") }
    }
    private func execute(_ step: Step, args: [String:String], record: inout RunRecord) async throws {
        switch step.operation {
        case .readCSV: record.tables[args["output"]!] = try Table.parse(String(decoding:read(file(args["path"]!)),as:UTF8.self))
        case .transformTable:
            guard var table = record.tables[args["table"]!] else { throw ScoutError.message("Read the table before changing it.") }
            try table.transform(action:args["action"]!,column:args["column"]!,value:args["value"]!); record.tables[args["output"]!] = table
        case .writeCSV:
            guard let table = record.tables[args["table"]!] else { throw ScoutError.message("The table has not been read yet.") }
            try write(Data(table.csv.utf8),to:file(args["path"]!),record:&record,allowExisting:false)
        case .driveTime:
            let minutes = try await TravelTime.minutes(from:args["origin"]!,to:args["destination"]!)
            record.values[args["output"]!] = minutes
        case .appendCSV:
            let url = try file(args["path"]!); let columns = try JSONDecoder().decode([String].self,from:Data(args["columns"]!.utf8)); let values = try JSONDecoder().decode([String].self,from:Data(args["values"]!.utf8))
            guard columns.count == values.count, !columns.isEmpty, Set(columns).count == columns.count else { throw ScoutError.message("Each column needs exactly one value.") }
            var table = FileManager.default.fileExists(atPath:url.path) ? try Table.parse(String(decoding:read(url),as:UTF8.self)) : Table(columns:columns,rows:[])
            guard table.columns == columns else { throw ScoutError.message("The destination columns have changed.") }
            table.rows.append(values); try write(Data(table.csv.utf8),to:url,record:&record,allowExisting:true)
        case .copyFile,.moveFile,.renameFile:
            let source = try file(args["source"]!); let destination = try file(args["destination"]!); let data = try read(source)
            guard source != destination else { throw ScoutError.message("The source and destination are the same.") }
            try write(data,to:destination,record:&record,allowExisting:false)
            if step.operation != .copyFile { record.undo.append(UndoEntry(path:source.path,before:data,after:nil)); try save(&record); try FileManager.default.removeItem(at:source); guard !FileManager.default.fileExists(atPath:source.path) else { throw ScoutError.message("The original file could not be moved.") } }
        case .waitForFile:
            var url = try file(args["path"]!); var last: Data?
            // Waiting on a folder means "wait for the file that started this run"; if there is none, there is nothing to wait for.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory), isDirectory.boolValue { guard let started = record.values["file"] else { return }; url = try file(started) }
            for _ in 0..<30 { guard !stopRequested else { throw CancellationError() }; if let data = try? read(url), data == last { return }; last = try? read(url); try await Task.sleep(for:.seconds(1)) }
            throw ScoutError.message("The file did not finish arriving within 30 seconds.")
        case .resizeImage,.convertImage:
            let source = try file(args["source"]!); let destination = try file(args["destination"]!)
            let data = try read(source)
            guard let imageSource = CGImageSourceCreateWithData(data as CFData,nil), var image = CGImageSourceCreateImageAtIndex(imageSource,0,nil) else { throw ScoutError.message("This image could not be read.") }
            if step.operation == .resizeImage {
                guard let width = Int(args["width"]!), let height = Int(args["height"]!), (1...8192).contains(width), (1...8192).contains(height) else { throw ScoutError.message("Choose image dimensions between 1 and 8,192 pixels.") }
                let ratio = min(Double(width)/Double(image.width),Double(height)/Double(image.height))
                let w = max(1,Int(Double(image.width)*ratio)); let h = max(1,Int(Double(image.height)*ratio))
                guard let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScoutError.message("The resized image could not be created.") }
                context.interpolationQuality = .high; context.draw(image,in:CGRect(x:0,y:0,width:w,height:h)); guard let resized = context.makeImage() else { throw ScoutError.message("The resized image could not be created.") }; image = resized
            }
            let format = (args["format"] ?? destination.pathExtension).lowercased()
            guard ["png","jpg","jpeg","tiff"].contains(format) else { throw ScoutError.message("Choose PNG, JPEG or TIFF.") }
            let type = format == "png" ? UTType.png : format == "tiff" ? UTType.tiff : UTType.jpeg
            let output = NSMutableData()
            guard let writer = CGImageDestinationCreateWithData(output,type.identifier as CFString,1,nil) else { throw ScoutError.message("This image format could not be written.") }
            CGImageDestinationAddImage(writer,image,nil); guard CGImageDestinationFinalize(writer) else { throw ScoutError.message("The image could not be saved.") }
            try write(output as Data,to:destination,record:&record,allowExisting:false)
        case .ask:
            guard let onAsk, await onAsk(args["message"]!) else { throw ScoutError.message("You skipped this action.") }
        default:
            guard let ui else { throw ScoutError.message("This action needs the macOS app.") }
            if step.operation.irreversible { record.irreversible = true; record.fieldUndo = []; try save(&record) }
            try await ui.focus(step)
            if let undo = try await ui.prepareUndo(step,args:args) {
                if let index = record.fieldUndo.firstIndex(where: { $0.target == undo.target && $0.context == undo.context }) { record.fieldUndo[index].after = undo.after } else { record.fieldUndo.append(undo) }; try save(&record)
            }
            let values = try await ui.execute(step,args:args); record.values.merge(values,uniquingKeysWith:{ _,b in b })
            if [.numbersRead,.excelRead].contains(step.operation), let output = args["output"], let csv = values[output] { record.tables[output] = try Table.parse(csv) }
        }
    }
    public func undo(_ original: RunRecord) throws -> RunRecord {
        guard active == nil, original.canUndo else { throw ScoutError.message("Undo is no longer available.") }
        for entry in original.fieldUndo.reversed() { guard let ui else { throw ScoutError.message("Field Undo needs access to the other app.") }; try ui.checkUndo(entry) }
        // Preflight every path, including chains that touched the same file more than once.
        var simulated: [String:Data] = [:]; var absent = Set<String>()
        for entry in original.undo.reversed() {
            let current: Data?
            if absent.contains(entry.path) { current = nil } else if let saved = simulated[entry.path] { current = saved } else { let url = URL(fileURLWithPath:entry.path); current = FileManager.default.fileExists(atPath:entry.path) ? try read(url) : nil }
            guard current.map({ digest($0.base64EncodedString()) }) == entry.afterHash else { throw ScoutError.message("\(URL(fileURLWithPath:entry.path).lastPathComponent) changed after this run. Undo will not overwrite your edits.") }
            if let before = entry.before { simulated[entry.path] = before; absent.remove(entry.path) } else { simulated.removeValue(forKey:entry.path); absent.insert(entry.path) }
        }
        for entry in original.undo.reversed() { let url = URL(fileURLWithPath:entry.path); if let before = entry.before { try before.write(to:url,options:.atomic) } else if FileManager.default.fileExists(atPath:entry.path) { try FileManager.default.removeItem(at:url) } }
        for entry in original.fieldUndo.reversed() { try ui?.undo(entry) }
        var record = original; record.fieldUndo = []; record.status = "undone"; record.message = original.irreversible ? "Reversed file changes. Other actions could not be undone." : "Changes undone."; record.undo = []; try memory.save(record,kind:"runs",id:record.id); return record
    }
    public func pruneRuns(now: Date = Date()) throws {
        for var run in try memory.all(RunRecord.self,kind:"runs") {
            if now.timeIntervalSince(run.updated) > 60 { run.undo = []; run.fieldUndo = [] }
            if now.timeIntervalSince(run.started) > 48*3600 { run.values = [:]; run.tables = [:]; run.loops = []; if ["running","stopped","failed"].contains(run.status) { run.status = "expired" } }
            try memory.save(run,kind:"runs",id:run.id)
        }
    }
}
