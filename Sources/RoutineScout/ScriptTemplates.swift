import AppKit
import ScoutCore

enum ScriptTemplates {
    static func quote(_ value: String) -> String { "\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\n",with:"\\n")+"\"" }
    static func execute(_ script: String) throws -> NSAppleEventDescriptor {
        guard let source = NSAppleScript(source:script) else { throw ScoutError.message("Could not prepare the app action.") }
        var error: NSDictionary?; let result = source.executeAndReturnError(&error)
        if let error { let number = error[NSAppleScript.errorNumber] as? Int ?? 0; throw ScoutError.message(number == -1743 ? "Allow Handoff to control this app in System Settings → Privacy & Security → Automation." : "The app could not complete the action. Make sure the named document, sheet and table are open (\(number)).") }
        return result
    }
    static func context(app: String) -> [String:String] {
        let script: String
        switch app {
        case "com.apple.iWork.Numbers": script = "tell application id \"com.apple.iWork.Numbers\"\nif (count of documents) is 0 then return \"\"\nset p to \"\"\ntry\nset p to POSIX path of (file of front document as alias)\nend try\ntell front document\nreturn name & \"|\" & name of active sheet & \"|\" & name of selection range of first table of active sheet & \"|\" & p\nend tell\nend tell"
        case "com.microsoft.Excel": script = "tell application id \"com.microsoft.Excel\"\nset p to \"\"\ntry\nset p to POSIX path of (full name of active workbook)\nend try\nreturn name of active workbook & \"|\" & name of active sheet & \"|\" & (get address of selection) & \"|\" & p\nend tell"
        case "com.apple.mail": script = "tell application id \"com.apple.mail\"\nif (count of selection) is 0 then return \"\"\nset m to item 1 of selection\nreturn sender of m & \"|\" & subject of m\nend tell"
        case "com.apple.finder": script = "tell application id \"com.apple.finder\"\nif (count of Finder windows) is 0 then return \"\"\nreturn POSIX path of (target of front Finder window as alias)\nend tell"
        default: return [:]
        }
        guard let value = try? execute(script).stringValue, !value.isEmpty else { return [:] }
        let parts = value.components(separatedBy:"|")
        if app == "com.apple.finder" { return ["folder":value] }
        if app == "com.apple.mail" { return ["sender":parts[0],"subject":parts.dropFirst().joined(separator:"|")] }
        var result = ["document":parts[0],"sheet":parts.count > 1 ? parts[1] : "","row":parts.count > 2 ? parts[2] : ""]
        if parts.count > 3, parts[3].hasPrefix("/") { result["path"] = parts[3] }
        return result
    }
    static func run(_ operation: ScoutCore.Operation, args: [String:String]) throws -> [String:String] {
        func q(_ key: String) -> String { quote(args[key] ?? "") }
        switch operation {
        case .numbersAppend:
            let values = try JSONDecoder().decode([String].self,from:Data(args["values"]!.utf8)); guard !values.isEmpty else { throw ScoutError.message("There are no values to add.") }
            let assignments = values.enumerated().map { "set value of cell \($0.offset+1) of row rowCount to \(quote($0.element))" }.joined(separator:"\n")
            _ = try execute("tell application id \"com.apple.iWork.Numbers\"\ntell table \(q("table")) of sheet \(q("sheet")) of document \(q("document"))\nif column count < \(values.count) then error \"Missing columns\"\nset oldCount to row count\nadd row below last row\nset rowCount to row count\n\(assignments)\nif row count is not oldCount + 1 then error \"Row not added\"\nend tell\nend tell")
            return [:]
        case .numbersRead:
            let result = try execute("tell application id \"com.apple.iWork.Numbers\" to get value of every cell of every row of table \(q("table")) of sheet \(q("sheet")) of document \(q("document"))")
            return [args["output"]!:try descriptorRows(result)]
        case .excelAppend:
            let values = try JSONDecoder().decode([String].self,from:Data(args["values"]!.utf8))
            let assignments = values.enumerated().map { "set value of cell \($0.offset+1) of row nextRow to \(quote($0.element))" }.joined(separator:"\n")
            _ = try execute("tell application id \"com.microsoft.Excel\"\ntell worksheet \(q("sheet")) of workbook \(q("document"))\nset nextRow to (first row index of used range) + (count of rows of used range)\n\(assignments)\nif (count of rows of used range) < nextRow then error \"Row not added\"\nend tell\nend tell"); return [:]
        case .excelRead:
            let result = try execute("tell application id \"com.microsoft.Excel\" to get value of range \(q("range")) of worksheet \(q("sheet")) of workbook \(q("document"))")
            return [args["output"]!:try descriptorRows(result)]
        case .mailRead:
            let result = try execute("tell application id \"com.apple.mail\"\nif (count of selection) is 0 then error \"Select a message\"\nset m to item 1 of selection\nreturn {sender of m, subject of m, content of m}\nend tell")
            return [args["output"]!+".sender":result.atIndex(1)?.stringValue ?? "",args["output"]!+".subject":result.atIndex(2)?.stringValue ?? "",args["output"]!+".body":String((result.atIndex(3)?.stringValue ?? "").prefix(20000))]
        case .notesAppend:
            let escaped = (args["value"] ?? "").replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\n",with:"<br>")
            _ = try execute("tell application id \"com.apple.Notes\"\nset n to first note whose name is \(q("name"))\nset body of n to (body of n) & \(quote("<div>"+escaped+"</div>"))\nend tell"); return [:]
        case .runShortcut:
            _ = try execute("tell application \"Shortcuts Events\" to run shortcut \(q("name"))"); return [:]
        default: throw ScoutError.message("This app action is not supported.")
        }
    }
    static func descriptorRows(_ result: NSAppleEventDescriptor) throws -> String {
        var rows: [[String]] = []
        if result.numberOfItems > 0 { for i in 1...result.numberOfItems { if let row = result.atIndex(i) { if row.numberOfItems > 0 { rows.append((1...row.numberOfItems).map { row.atIndex($0)?.stringValue ?? "" }) } } } }
        guard let columns = rows.first else { throw ScoutError.message("The selected table is empty.") }
        return Table(columns:columns,rows:Array(rows.dropFirst())).csv
    }
}
