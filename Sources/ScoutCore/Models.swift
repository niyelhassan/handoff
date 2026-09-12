import Foundation
import CryptoKit

public enum ScoutError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
public struct Event: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var time = Date()
    public var app: String
    public var kind: String
    public var role: String
    public var label: String
    public var context: String
    public var instance: String
    public var selfGenerated = false
    public init(app: String, kind: String, role: String = "", label: String = "", context: String = "", instance: String = "", time: Date = Date()) {
        self.app = app; self.kind = kind; self.role = role; self.label = label; self.context = context; self.instance = instance; self.time = time
    }
    public var token: String { [app, kind, role, label.lowercased(), context].joined(separator: "|") }
}
public struct Evidence: Codable {
    public var event: Event
    public var details: [String:String]
    public init(_ event: Event, _ details: [String:String] = [:]) { self.event = event; self.details = details }
}
public struct Candidate: Codable, Identifiable {
    public var id: String
    public var shape: String
    public var instances: [[Evidence]]
    public var score: Double
    public var count: Int { instances.count }
}
public struct Judgment: Codable {
    public var isRoutine: Bool
    public var name: String
    public var description: String
    public var automatable: Bool
    public var reason: String
    public var inputs: [Int]
    public init(isRoutine: Bool, name: String, description: String, automatable: Bool, reason: String, inputs: [Int]) {
        self.isRoutine = isRoutine; self.name = name; self.description = description; self.automatable = automatable; self.reason = reason; self.inputs = inputs
    }
}
public enum Operation: String, Codable, CaseIterable {
    case openApp, openURL, waitForElement, readText, setValue, click, chooseMenu, pressShortcut, readURL, copyText, pasteValue
    case waitForFile, renameFile, moveFile, copyFile, openFile, revealFile
    case readCSV, appendCSV, transformTable, writeCSV, resizeImage, convertImage, driveTime
    case numbersAppend, numbersRead, excelAppend, excelRead, mailRead, notesAppend, runShortcut
    case forEach, endLoop, ifMatches, endIf, ask
    public var touchesUI: Bool { ![.waitForFile,.renameFile,.moveFile,.copyFile,.readCSV,.appendCSV,.transformTable,.writeCSV,.resizeImage,.convertImage,.driveTime,.forEach,.endLoop,.ifMatches,.endIf,.ask].contains(self) }
    public var irreversible: Bool { [.click,.chooseMenu,.pressShortcut,.pasteValue,.numbersAppend,.excelAppend,.notesAppend,.runShortcut,.openURL].contains(self) }
}
public struct Parameter: Codable, Equatable {
    public var key: String
    public var value: String
    public init(_ key: String, _ value: String) { self.key = key; self.value = value }
}
public struct Target: Codable, Equatable {
    public var app: String
    public var role: String
    public var label: String
    public var identifier: String
    public var ancestors: [String]
    public var alternates: [String]
    public init(app: String, role: String = "", label: String = "", identifier: String = "", ancestors: [String] = [], alternates: [String] = []) {
        self.app = app; self.role = role; self.label = label; self.identifier = identifier; self.ancestors = ancestors; self.alternates = alternates
    }
}
public struct Step: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var operation: Operation
    public var parameters: [Parameter]
    public var target: Target?
    public init(_ operation: Operation, _ title: String, _ args: [String:String] = [:], target: Target? = nil, id: String = UUID().uuidString) {
        self.id = id; self.operation = operation; self.title = title; self.parameters = args.sorted { $0.key < $1.key }.map { Parameter($0.key,$0.value) }; self.target = target
    }
    enum CodingKeys: String, CodingKey { case id, title, operation, parameters, target }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(String.self,forKey:.id); title = try c.decode(String.self,forKey:.title); operation = try c.decode(Operation.self,forKey:.operation); target = try c.decodeIfPresent(Target.self,forKey:.target)
        let allowed = Catalog.arguments[operation] ?? []
        if let pairs = try? c.decode([Parameter].self,forKey:.parameters) { parameters = pairs } else { parameters = try c.decode([String:String].self,forKey:.parameters).filter { allowed.contains($0.key) }.sorted { $0.key < $1.key }.map { Parameter($0.key,$0.value) } }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(id,forKey:.id); try c.encode(title,forKey:.title); try c.encode(operation,forKey:.operation); try c.encode(args,forKey:.parameters); try c.encode(target,forKey:.target)
    }
    public var args: [String:String] { Dictionary(parameters.map { ($0.key,$0.value) }, uniquingKeysWith: { a,_ in a }) }
}
public struct RunTrigger: Codable, Equatable, Identifiable {
    public var id: String { kind + value + app }
    public var kind: String
    public var title: String
    public var value: String
    public var app: String
    public init(_ kind: String = "manual", title: String = "Only when I ask", value: String = "", app: String = "") { self.kind = kind; self.title = title; self.value = value; self.app = app }
}
public struct Automation: Codable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var steps: [Step]
    public var inputs: [Parameter] = []
    public var suggestedTriggers: [RunTrigger]
    public var trigger: RunTrigger
    public var mode: String
    public var enabled: Bool
    public var cleanRuns: Int
    public var tested: Bool
    public var allowIrreversible: Bool
    public init(name: String, description: String, steps: [Step], id: String = UUID().uuidString) {
        self.id = id; self.name = name; self.description = description; self.steps = steps; self.suggestedTriggers = [RunTrigger()]; self.trigger = RunTrigger(); self.mode = "ask"; self.enabled = false; self.cleanRuns = 0; self.tested = false; self.allowIrreversible = false
    }
}
public struct BuiltRoutine: Codable {
    public var name: String
    public var description: String
    public var steps: [Step]
    public var suggestedTriggers: [RunTrigger]
    public func automation() -> Automation { var a = Automation(name: name, description: description, steps: steps); a.suggestedTriggers = suggestedTriggers; return a }
}
public struct PrivacyPolicy: Codable {
    public var ignoredApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.bitwarden.desktop", "com.lastpass.LastPass", "com.apple.Passwords"]
    public var ignoredSites = ["chase.com", "bankofamerica.com", "wellsfargo.com", "capitalone.com", "citi.com", "paypal.com"]
    public var pausedUntil: Date?
    public init() {}
    public var paused: Bool { (pausedUntil ?? .distantPast) > Date() }
    public func permits(app: String, domain: String, role: String, window: String, protected: Bool = false) -> Bool {
        !paused && !protected && !ignoredApps.contains(app) && !role.lowercased().contains("secure") && !["incognito","private browsing","inprivate","private window"].contains(where: { window.lowercased().contains($0) }) && !ignoredSites.contains(where: { domain == $0 || domain.hasSuffix("." + $0) })
    }
}
