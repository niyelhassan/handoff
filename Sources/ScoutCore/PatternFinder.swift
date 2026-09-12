import Foundation

public struct PatternFinder {
    public init() {}
    public func candidates(_ evidence: [Evidence]) -> [Candidate] {
        let clean = evidence.filter { !$0.event.selfGenerated && !["focus","activate"].contains($0.event.kind) }.suffix(2000)
        var episodes: [[Evidence]] = []; var current: [Evidence] = []
        for e in clean {
            if let last = current.last, e.event.time.timeIntervalSince(last.event.time) > 90 || e.event.kind == "boundary" { if !current.isEmpty { episodes.append(current) }; current = [] }
            if e.event.kind != "boundary" { current.append(e) }
        }
        if !current.isEmpty { episodes.append(current) }
        struct Window { var episode: Int; var start: Int; var length: Int }
        var buckets: [String:[Window]] = [:]
        for (ei,episode) in episodes.enumerated() where episode.count >= 3 {
            for length in 3...min(30,episode.count) {
                for start in 0...(episode.count-length) {
                    let items = Array(episode[start..<(start+length)])
                    // Require a meaningful action and a destination, not mere browsing or app switching.
                    guard items.contains(where: { ["paste","file","export","submit"].contains($0.event.kind) }), Set(items.map { $0.event.token }).count >= 3 else { continue }
                    let key = items.map { $0.event.token }.joined(separator: "\n")
                    buckets[key,default:[]].append(Window(episode:ei,start:start,length:length))
                }
            }
        }
        var found: [Candidate] = []
        for (key,windows) in buckets where windows.count >= 2 {
            var accepted: [Window] = []; var identities = Set<String>()
            for w in windows {
                let windowItems = Array(episodes[w.episode][w.start..<(w.start+w.length)])
                let identity = windowItems.map { $0.event.instance }.filter { !$0.isEmpty }.joined(separator: "|")
                guard !identity.isEmpty, identities.insert(identity).inserted else { continue }
                guard !accepted.contains(where: { $0.episode == w.episode && abs($0.start-w.start) < max($0.length,w.length) }) else { continue }
                accepted.append(w)
            }
            guard accepted.count >= 2 else { continue }
            let first = accepted[0]
            let items = Array(episodes[first.episode][first.start..<(first.start+first.length)])
            let kinds = items.map { $0.event.kind }
            let apps = Set(items.map { $0.event.app })
            let loop = Set(accepted.map { $0.episode }).count == 1 && kinds.contains("submit")
            let files = items.filter { $0.event.kind == "file" }
            let csvFiles = files.filter { $0.event.role.lowercased() == "csv" }.count
            let imageFiles = files.filter { ["png","jpg","jpeg","tiff","heic"].contains($0.event.role.lowercased()) }.count
            // Shapes: transform = a table went in and a table came out; image = a picture went in and a picture came out;
            // pipeline = a file moved through more than one app; loop = repeated submissions in one sitting; transfer/collect = copy and paste flows.
            // travel = an address pasted into a maps site each time (the drive time is read off the screen and typed back).
            let maps = items.contains { ($0.event.kind == "paste" || $0.event.kind == "activate") && (($0.details["url"] ?? "") + $0.event.context).lowercased().contains("maps") }
            let shape = csvFiles >= 2 && kinds.contains("export") ? "transform" : loop ? "loop" : imageFiles >= 2 ? "image" : maps && kinds.contains("paste") && apps.count > 1 ? "travel" : kinds.contains("file") && apps.count > 1 ? "pipeline" : kinds.filter { $0 == "paste" }.count >= 2 ? "transfer" : "collect"
            guard accepted.count >= (["loop","transform"].contains(shape) ? 2 : 3) else { continue }
            found.append(Candidate(id:digest(key),shape:shape,instances:accepted.map { Array(episodes[$0.episode][$0.start..<($0.start+$0.length)]) },score:Double(accepted.count*items.count)))
        }
        // Prefer complete routines; suppress overlapping subwindows and shifted copies.
        found.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        var used = Set<String>(); var result: [Candidate] = []
        for candidate in found {
            let ids = Set(candidate.instances.flatMap { $0.map { $0.event.id } })
            guard Double(ids.intersection(used).count) / Double(ids.count) < 0.3 else { continue }
            result.append(candidate); used.formUnion(ids)
        }
        return result
    }
    public static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var row = Array(repeating:0,count:b.count+1)
        for x in a { var next = row; for (j,y) in b.enumerated() { next[j+1] = x == y ? row[j]+1 : max(row[j+1],next[j]) }; row = next }
        return Double(2*row[b.count])/Double(a.count+b.count)
    }
}
