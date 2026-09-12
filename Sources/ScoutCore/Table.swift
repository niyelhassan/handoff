import Foundation
public struct Table: Codable, Equatable {
    public var columns: [String]
    public var rows: [[String]]
    public init(columns: [String], rows: [[String]]) { self.columns = columns; self.rows = rows }
    public static func parse(_ text: String) throws -> Table {
        var cells: [[String]] = []; var row: [String] = []; var field = ""; var quoted = false; var closed = false
        let chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text); var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i+1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 } else { quoted = false; closed = true } } else { field.append(c) }
            } else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else if c == "," { row.append(field); field = ""; closed = false }
            else if c == "\n" || c == "\r" || c == "\r\n" { row.append(field); cells.append(row); row = []; field = ""; closed = false; if c == "\r" && i+1 < chars.count && chars[i+1] == "\n" { i += 1 } }
            else { guard !closed, c != "\"" else { throw ScoutError.message("This CSV has an unexpected quote.") }; field.append(c) }
            i += 1
        }
        guard !quoted else { throw ScoutError.message("This CSV has an unfinished quoted value.") }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); cells.append(row) }
        guard let header = cells.first, !header.isEmpty, Set(header).count == header.count, header.allSatisfy({ !$0.isEmpty }) else { throw ScoutError.message("The CSV needs distinct, nonempty column headings.") }
        let rows = Array(cells.dropFirst()).filter { $0 != [""] }
        guard rows.allSatisfy({ $0.count == header.count }) else { throw ScoutError.message("A CSV row has a different number of columns.") }
        return Table(columns:header,rows:rows)
    }
    public var csv: String {
        ([columns]+rows).map { $0.map { value in value.contains(where: { ",\"\n\r".contains($0) }) ? "\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\"" : value }.joined(separator:",") }.joined(separator:"\r\n") + "\r\n"
    }
    public func records() -> [[String:String]] { rows.map { Dictionary(uniqueKeysWithValues:zip(columns,$0)) } }
    public mutating func transform(action: String, column: String, value: String) throws {
        func index(_ name: String) throws -> Int { guard let i = columns.firstIndex(of:name) else { throw ScoutError.message("The table has no column named \(name).") }; return i }
        switch action {
        case "skipRows": guard let count = Int(value), count >= 0 else { throw ScoutError.message("Choose a nonnegative number of rows to skip.") }; rows = Array(rows.dropFirst(count))
        case "keepColumns", "dropColumns":
            let names = try JSONDecoder().decode([String].self,from:Data(value.utf8)); let indices = try (action == "keepColumns" ? names : columns.filter { !names.contains($0) }).map(index)
            guard !indices.isEmpty, Set(indices).count == indices.count else { throw ScoutError.message("Keep at least one distinct column.") }
            columns = indices.map { columns[$0] }; rows = rows.map { row in indices.map { row[$0] } }
        case "dropEmptyRows": rows.removeAll { $0.allSatisfy { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } }
        case "renameColumn": let i = try index(column); guard !value.isEmpty, !columns.contains(value) || value == column else { throw ScoutError.message("That column name is already used or empty.") }; columns[i] = value
        case "sort": let i = try index(column); rows = rows.enumerated().sorted { a,b in let x = a.element[i]; let y = b.element[i]; if x == y { return a.offset < b.offset }; let less = (Double(x) != nil && Double(y) != nil) ? Double(x)! < Double(y)! : x.localizedStandardCompare(y) == .orderedAscending; return value == "descending" ? !less : less }.map(\.element)
        case "filter": let i = try index(column); let regex = try NSRegularExpression(pattern:value); rows = rows.filter { regex.firstMatch(in:$0[i],range:NSRange($0[i].startIndex...,in:$0[i])) != nil }
        case "trim": let indices = column.isEmpty ? Array(columns.indices) : [try index(column)]; for r in rows.indices { for c in indices { rows[r][c] = rows[r][c].trimmingCharacters(in:.whitespacesAndNewlines) } }
        case "parseNumbers": let i = try index(column); for r in rows.indices { let old = rows[r][i]; let cleaned = old.replacingOccurrences(of:"[^0-9.\\-]",with:"",options:.regularExpression); guard let number = Double(cleaned), number.isFinite else { throw ScoutError.message("‘\(old)’ is not a number.") }; rows[r][i] = number.rounded() == number ? String(format:"%.0f",number) : String(number) }
        case "formatDates": let i = try index(column); let formats = try JSONDecoder().decode([String:String].self,from:Data(value.utf8)); guard let from = formats["from"], let to = formats["to"] else { throw ScoutError.message("Both date formats are needed.") }; let input = DateFormatter(); input.locale = Locale(identifier:"en_US_POSIX"); input.dateFormat = from; input.isLenient = false; let output = DateFormatter(); output.locale = input.locale; output.dateFormat = to; for r in rows.indices { guard let date = input.date(from:rows[r][i]) else { throw ScoutError.message("A date could not be read.") }; rows[r][i] = output.string(from:date) }
        case "regexExtract": let i = try index(column); let regex = try NSRegularExpression(pattern:value); for r in rows.indices { let s = rows[r][i]; guard let match = regex.firstMatch(in:s,range:NSRange(s.startIndex...,in:s)), let range = Range(match.range(at:match.numberOfRanges > 1 ? 1 : 0),in:s) else { throw ScoutError.message("A value did not match the requested pattern.") }; rows[r][i] = String(s[range]) }
        case "template":
            let records = records(); let i: Int
            if let existing = columns.firstIndex(of:column) { i = existing } else { guard !column.isEmpty else { throw ScoutError.message("The new column needs a name.") }; i = columns.count; columns.append(column); for r in rows.indices { rows[r].append("") } }
            for r in rows.indices { rows[r][i] = try interpolate(value,values:Dictionary(uniqueKeysWithValues:records[r].map { ("row."+$0.key,$0.value) })) }
        case "split":
            let i = try index(column); let spec = try JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any]; guard let sep = spec?["separator"] as? String, !sep.isEmpty, let names = spec?["columns"] as? [String], !names.isEmpty, Set(names).count == names.count, !names.contains(where:columns.contains) else { throw ScoutError.message("Choose a separator and unused column names.") }
            columns.append(contentsOf:names); for r in rows.indices { let parts = rows[r][i].components(separatedBy:sep); guard parts.count == names.count else { throw ScoutError.message("A value has an unexpected number of parts.") }; rows[r].append(contentsOf:parts) }
        default: throw ScoutError.message("This table change is not supported.")
        }
    }
}
public func interpolate(_ text: String, values: [String:String]) throws -> String {
    let re = try NSRegularExpression(pattern:"\\{\\{([^{}]+)\\}\\}"); var result = text
    for match in re.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
        guard let keyRange = Range(match.range(at:1),in:text), let range = Range(match.range,in:result) else { continue }
        let key = String(text[keyRange]); guard let value = values[key] else { throw ScoutError.message("The value ‘\(key)’ is missing.") }; result.replaceSubrange(range,with:value)
    }
    return result
}

// Interpolate JSON string leaves before serializing so quotes/newlines in real data stay data.
public func interpolateArgument(_ text: String, values: [String:String]) throws -> String {
    guard text.hasPrefix("[") || text.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with:Data(text.utf8)) else { return try interpolate(text,values:values) }
    func walk(_ object: Any) throws -> Any {
        if let string = object as? String { return try interpolate(string,values:values) }
        if let array = object as? [Any] { return try array.map(walk) }
        if let dictionary = object as? [String:Any] { return try dictionary.mapValues(walk) }
        return object
    }
    return String(decoding:try JSONSerialization.data(withJSONObject:walk(object),options:[.sortedKeys,.fragmentsAllowed]),as:UTF8.self)
}
