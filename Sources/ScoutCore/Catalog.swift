import Foundation

public enum Catalog {
    public static let arguments: [Operation:[String]] = [
        .openApp:["app"], .openURL:["url"], .waitForElement:[], .readText:["output"], .setValue:["value"], .click:[], .chooseMenu:[], .pressShortcut:["key","modifiers"], .readURL:["output"], .copyText:["output"], .pasteValue:["value"],
        .waitForFile:["path"], .renameFile:["source","destination"], .moveFile:["source","destination"], .copyFile:["source","destination"], .openFile:["path","app"], .revealFile:["path"],
        .readCSV:["path","output"], .appendCSV:["path","columns","values"], .transformTable:["table","action","column","value","output"], .writeCSV:["table","path"], .resizeImage:["source","destination","width","height"], .convertImage:["source","destination","format"],
        .numbersAppend:["document","sheet","table","values"], .numbersRead:["document","sheet","table","output"], .excelAppend:["document","sheet","values"], .excelRead:["document","sheet","range","output"], .mailRead:["output"], .notesAppend:["name","value"], .runShortcut:["name"],
        .forEach:["source","item"], .endLoop:[], .ifMatches:["value","pattern"], .endIf:[], .ask:["message"]
    ]
    public static let transformActions = ["keepColumns","dropColumns","renameColumn","sort","filter","dropEmptyRows","parseNumbers","formatDates","trim","split","regexExtract","template","skipRows"]
    public static func validate(_ automation: Automation) throws {
        guard !automation.name.isEmpty, !automation.steps.isEmpty, automation.steps.count <= 100 else { throw ScoutError.message("The routine needs a name and between 1 and 100 steps.") }
        guard Set(automation.steps.map { $0.id }).count == automation.steps.count else { throw ScoutError.message("Each step needs a unique name in the saved plan.") }
        var stack: [Operation] = []
        for step in automation.steps {
            guard !step.title.isEmpty, Set(step.parameters.map { $0.key }).count == step.parameters.count else { throw ScoutError.message("A step has missing or duplicate information.") }
            let keys = Set(step.parameters.map { $0.key }); let allowed = Set(arguments[step.operation] ?? [])
            guard keys == allowed else { throw ScoutError.message("\(step.title): expected \(allowed.sorted().joined(separator:", ")).") }
            if [.readText,.setValue,.click,.chooseMenu,.waitForElement,.copyText,.pasteValue,.pressShortcut,.readURL].contains(step.operation) {
                guard let target = step.target, !target.app.isEmpty else { throw ScoutError.message("\(step.title): choose an app first.") }
                if ![.pressShortcut,.readURL].contains(step.operation), let target = step.target, target.label.isEmpty && target.identifier.isEmpty { throw ScoutError.message("\(step.title): the item needs a name.") }
            }
            if step.operation == .transformTable && !transformActions.contains(step.args["action"] ?? "") { throw ScoutError.message("This table change is not supported.") }
            if step.operation == .openURL, let url = step.args["url"], !url.contains("{{"), !["https","http"].contains(URL(string:url)?.scheme ?? "") { throw ScoutError.message("Only web links can be opened.") }
            if step.operation == .forEach || step.operation == .ifMatches { stack.append(step.operation) }
            if step.operation == .endLoop { guard stack.popLast() == .forEach else { throw ScoutError.message("The repeating steps are not paired correctly.") } }
            if step.operation == .endIf { guard stack.popLast() == .ifMatches else { throw ScoutError.message("The conditional steps are not paired correctly.") } }
        }
        guard stack.isEmpty else { throw ScoutError.message("A group of steps is unfinished.") }
        guard ["ask","automatic"].contains(automation.mode) else { throw ScoutError.message("Unknown run mode.") }
        if automation.mode == "automatic" {
            guard automation.tested && automation.cleanRuns >= 3 else { throw ScoutError.message("Try this successfully three times before enabling automatic runs.") }
            guard automation.allowIrreversible || !automation.steps.contains(where: { $0.operation.irreversible }) else { throw ScoutError.message("This routine includes actions that cannot be undone. Keep it in ask mode or explicitly allow them.") }
        }
        for t in automation.suggestedTriggers + [automation.trigger] {
            guard ["manual","context","file","schedule","loop"].contains(t.kind) else { throw ScoutError.message("This way of starting a routine is not supported.") }
            if t.kind == "schedule" { let parts = t.value.split(separator:":").compactMap { Int($0) }; guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { throw ScoutError.message("Choose a time as HH:mm.") } }
            if ["context","loop"].contains(t.kind), t.app.isEmpty { throw ScoutError.message("Choose the app where this should start.") }
            if t.kind == "file", !t.value.hasPrefix("/") { throw ScoutError.message("Choose a full folder path for new files.") }
        }
    }
    public static var instructions: String {
        "Return only steps from this catalog. Parameters are an object of string values. Fill the keys listed for that operation; set every other schema-required key to the empty string. Use {{variable}} or {{row.Column}} references. JSON arrays for columns/values. forEach source is a named table or a JSON list, item is a variable name, followed by body and endLoop. ifMatches uses a regular expression and ends with endIf. Targets require exact app bundle id plus role and label/identifier and optional ancestor names. Never invent observed paths, mappings, selectors, or transformations; ask for missing evidence. Never return executable code. CSV transform actions: \(transformActions.joined(separator:", ")). split value is JSON {separator,columns}; formatDates value is JSON {from,to}; renameColumn value is new name; filter value is regex; template value is a {{row.Column}} template; regexExtract value is regex; sort value is ascending/descending. skipRows value is an integer count of leading data rows to skip. For a continuation loop, skip the rows already processed, based on observed row indices. Triggers: manual uses empty value and app; context or loop uses app bundle id and value is an https/http URL prefix; file uses value as an absolute folder path (no wildcards), app as file extension without dot; schedule value is HH:mm. Catalog: " + Operation.allCases.map { "\($0.rawValue)(\((arguments[$0] ?? []).joined(separator:",")))" }.joined(separator:"; ")
    }
    private static func object(_ properties: [String:Any]) -> [String:Any] { ["type":"object","properties":properties,"required":properties.keys.sorted(),"additionalProperties":false] }
    public static var targetSchema: [String:Any] { object(["app":["type":"string"],"role":["type":"string"],"label":["type":"string"],"identifier":["type":"string"],"ancestors":["type":"array","items":["type":"string"]],"alternates":["type":"array","items":["type":"string"]]]) }
    public static var stepSchema: [String:Any] {
        let keys = Set(arguments.values.flatMap { $0 }).sorted()
        return object(["id":["type":"string"],"title":["type":"string"],"operation":["type":"string","enum":Operation.allCases.map(\.rawValue)],"parameters":object(Dictionary(uniqueKeysWithValues:keys.map { ($0,["type":"string"] as Any) })),"target":["anyOf":[targetSchema,["type":"null"]]]])
    }
    public static var buildSchema: [String:Any] {
        var schema = object(["name":["type":"string"],"description":["type":"string"],"steps":["type":"array","items":stepSchema],"suggestedTriggers":["type":"array","items":object(["kind":["type":"string","enum":["manual","context","file","schedule","loop"]],"title":["type":"string"],"value":["type":"string"],"app":["type":"string"]])]])
        schema["$defs"] = ["target":targetSchema]; return schema
    }
    public static var judgeSchema: [String:Any] { object(["isRoutine":["type":"boolean"],"name":["type":"string"],"description":["type":"string"],"automatable":["type":"boolean"],"reason":["type":"string"],"inputs":["type":"array","items":["type":"integer"]]]) }
}
