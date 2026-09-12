import Foundation
public struct TriggerReceipt: Codable { public var id: String; public var date: Date }
public final class Triggers {
    let memory: Memory
    private var context = ""
    public init(memory: Memory) { self.memory = memory }
    private func claim(_ id: String, now: Date) throws -> Bool {
        let receipts = try memory.all(TriggerReceipt.self,kind:"triggers")
        guard !receipts.contains(where: { $0.id == id }) else { return false }
        try memory.save(TriggerReceipt(id:id,date:now),kind:"triggers",id:id)
        for r in receipts where now.timeIntervalSince(r.date) > 14*86400 { try memory.delete(kind:"triggers",id:r.id) }
        return true
    }
    public func contextMatches(app: String, url: String, automations: [Automation], now: Date = Date()) -> [Automation] {
        let key = app+"|"+url; guard key != context else { return [] }; context = key
        return automations.filter { a in
            guard a.enabled && a.tested, ["context","loop"].contains(a.trigger.kind), a.trigger.app == app else { return false }
            if a.trigger.value.isEmpty { return true }
            guard let actual = URL(string:url), let expected = URL(string:a.trigger.value), expected.host != nil else { return false }
            return actual.host == expected.host && actual.path.hasPrefix(expected.path)
        }
    }
    public func fileAppeared(path: String, automations: [Automation], now: Date = Date()) throws -> [Automation] {
        let url = URL(fileURLWithPath:path).standardizedFileURL
        var result: [Automation] = []
        for a in automations where a.enabled && a.tested && a.trigger.kind == "file" {
            guard url.deletingLastPathComponent().path == URL(fileURLWithPath:a.trigger.value).standardizedFileURL.path, a.trigger.app.isEmpty || url.pathExtension.lowercased() == a.trigger.app.lowercased() else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath:path); let identity = String(describing:attrs?[.systemFileNumber] ?? path)+String(describing:attrs?[.creationDate] ?? "")
            if try claim(a.id+"|file|"+digest(identity),now:now) { result.append(a) }
        }
        return result
    }
    public func scheduled(automations: [Automation], now: Date = Date(), calendar: Calendar = .current) throws -> [Automation] {
        var result: [Automation] = []
        for a in automations where a.enabled && a.tested && a.trigger.kind == "schedule" {
            let parts = a.trigger.value.split(separator:":").compactMap { Int($0) }; guard parts.count == 2, let due = calendar.date(bySettingHour:parts[0],minute:parts[1],second:0,of:now), now >= due else { continue }
            let day = calendar.startOfDay(for:now).timeIntervalSince1970
            if try claim(a.id+"|schedule|"+String(day),now:now) { result.append(a) }
        }
        return result
    }
}
