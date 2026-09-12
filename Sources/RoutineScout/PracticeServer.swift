import Foundation
import Network
import ScoutCore

/// Tiny local web server that serves the practice form and listing pages used by "Try a local example" and the native self-test.
/// It binds to 127.0.0.1 only, keeps its state in memory, and never touches files outside the app.
final class PracticeServer {
    static let port: UInt16 = 8790
    static var base: String { "http://127.0.0.1:\(port)" }
    private var listener: NWListener?
    private let queue = DispatchQueue(label:"com.routinescout.practice")
    private var submissions: [[String:String]] = []
    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:Self.port)!)
        let listener = try NWListener(using:parameters)
        // NWListener reports bind failures (for example, another program already using the port) asynchronously; wait for a verdict.
        let ready = DispatchSemaphore(value:0); var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in connection.start(queue:self?.queue ?? .main); self?.receive(connection,buffer:Data()) }
        listener.start(queue:queue)
        guard ready.wait(timeout:.now()+3) == .success, failure == nil, listener.state == .ready else {
            listener.cancel()
            throw ScoutError.message("The practice pages could not start on port \(Self.port). Quit any other program using that port and try again.")
        }
        self.listener = listener
    }
    func stop() { listener?.cancel(); listener = nil }
    var submissionCount: Int { queue.sync { submissions.count } }
    func reset() { queue.sync { submissions = [] } }
    private func receive(_ connection: NWConnection,buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,complete,error in
            guard let self else { return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 65536 else { connection.cancel(); return }
            guard let text = String(data:buffer,encoding:.utf8), let end = text.range(of:"\r\n\r\n") else { if !complete && error == nil { self.receive(connection,buffer:buffer) } else { connection.cancel() }; return }
            let headers = String(text[..<end.lowerBound]); let body = String(text[end.upperBound...])
            let length = headers.components(separatedBy:"\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap { Int($0.split(separator:":").last!.trimmingCharacters(in:.whitespaces)) } ?? 0
            guard body.utf8.count >= length else { self.receive(connection,buffer:buffer); return }
            let line = headers.components(separatedBy:"\r\n")[0].split(separator:" "); let method = line.first.map(String.init) ?? "GET"; let path = line.count > 1 ? String(line[1]) : "/form"
            var response: String; var type = "text/html; charset=utf-8"
            if path == "/status" { response = String(decoding:(try? JSONSerialization.data(withJSONObject:self.submissions)) ?? Data("[]".utf8),as:UTF8.self); type = "application/json" }
            else {
                if method == "POST" && path == "/submit" {
                    let pairs = body.split(separator:"&").map { $0.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false).map(String.init) }
                    let values = Dictionary(pairs.compactMap { p -> (String,String)? in guard p.count == 2 else { return nil }; return (p[0],p[1].replacingOccurrences(of:"+",with:" ").removingPercentEncoding ?? p[1]) },uniquingKeysWith: { _,b in b })
                    self.submissions.append(values)
                }
                if path.hasPrefix("/listing") {
                    let n = Int(path.split(separator:"/").last ?? "0") ?? 0
                    let names = ["Maple Loft · 2BR near Union Square","Oak Studio · sunny top floor","Pine House · 3BR with garden"]; let streets = ["214 Maple St, Somerville","88 Oak Ave, Cambridge","5 Pine Rd, Brookline"]; let beds = ["2 bed · 1 bath · 860 sq ft","Studio · 1 bath · 420 sq ft","3 bed · 2 bath · 1,240 sq ft"]
                    response = self.page("Listing \(n+1) · Brookline Rentals",content:"<div class='brand'>Brookline Rentals</div><div class='photo'></div><h1>\(names[n%3])</h1><p class='meta'>\(beds[n%3]) · Available Oct 1</p><label for='listing-name'>Listing name</label><input id='listing-name' aria-label='Listing name' value='\(names[n%3])' readonly><label for='price'>Price</label><input id='price' aria-label='Price' value='\(1200+n*100)' readonly><label for='address'>Address</label><input id='address' aria-label='Address' value='\(streets[n%3])' readonly><a href='/listing/\((n+1)%3)'>Next listing</a>")
                }
                else { response = self.page("New hire · Northwind HR",content:"<div class='brand'>Northwind HR</div><h1>Add a new hire</h1><p id='status' role='status'>\(self.submissions.count) people added this session</p><form method='POST' action='/submit'><label for='name'>Name</label><input id='name' aria-label='Name' name='Name' required placeholder='Full name'><label for='email'>Email</label><input id='email' aria-label='Email' name='Email' type='email' required placeholder='name@company.com'><button type='submit'>Submit</button></form><p>Local practice page. Nothing leaves this Mac.</p>") }
            }
            let data = Data(response.utf8); let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content:Data(head.utf8)+data,completion:.contentProcessed { _ in connection.cancel() })
        }
    }
    private func page(_ title: String,content: String) -> String { "<!doctype html><html lang='en'><head><meta charset='utf-8'><title>\(title)</title><style>body{font:18px -apple-system;max-width:600px;margin:70px auto;color:#183c39;background:#f2f7f4}label{display:block;margin-top:24px}input{display:block;font:inherit;padding:12px;width:95%;border:1px solid #779b94;border-radius:8px}button,a{display:inline-block;font:inherit;padding:12px 20px;margin-top:24px;background:#196c5c;color:white;border:0;border-radius:8px}p{color:#4d6561}.brand{font-size:14px;letter-spacing:.12em;text-transform:uppercase;color:#196c5c;font-weight:600}.photo{height:180px;border-radius:12px;background:linear-gradient(135deg,#9fc9bd,#3f7f72);margin:16px 0}.meta{margin-top:-8px}</style></head><body>\(content)</body></html>" }
}
