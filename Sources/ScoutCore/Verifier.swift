import Foundation
public enum EvidenceVerifier {
    // Replay data steps entirely in memory against captured input/output pairs.
    // No AI-selected file path is opened or written during this verification.
    public static func verify(_ automation: Automation, candidate: Candidate) throws -> Int {
        guard candidate.shape == "transform" else { return 0 }
        let supported: Set<Operation> = [.waitForFile,.readCSV,.transformTable,.writeCSV]
        guard automation.steps.allSatisfy({ supported.contains($0.operation) }) else { throw ScoutError.message("The CSV cleanup must use table steps so it can be checked against the original exports.") }
        var verified = 0
        for instance in candidate.instances {
            let files = instance.filter { $0.details["csv"] != nil }
            guard files.count >= 2, let original = files.first?.details["csv"], let exported = files.last?.details["csv"] else { throw ScoutError.message("The original CSV and its exported result are needed to check this cleanup.") }
            var tables: [String:Table] = [:]; var result: Table?
            for step in automation.steps {
                let args = step.args
                switch step.operation {
                case .readCSV: tables[args["output"]!] = try Table.parse(original)
                case .transformTable:
                    guard var table = tables[args["table"]!] else { throw ScoutError.message("The cleanup changes a table before reading it.") }
                    try table.transform(action:args["action"]!,column:args["column"]!,value:args["value"]!); tables[args["output"]!] = table
                case .writeCSV: result = tables[args["table"]!]
                default: break
                }
            }
            guard result == (try Table.parse(exported)) else { throw ScoutError.message("The proposed cleanup did not reproduce your exported table.") }
            verified += 1
        }
        return verified
    }
}
