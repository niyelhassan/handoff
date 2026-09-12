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
                if path.hasPrefix("/listing") { let n = Int(path.split(separator:"/").last ?? "0") ?? 0; response = self.page("Listing \(n+1)",content:"<h1>Apartment listing</h1><label for='listing-name'>Listing name</label><input id='listing-name' aria-label='Listing name' value='\(["Maple Loft","Oak Studio","Pine House"][n%3])' readonly><label for='price'>Price</label><input id='price' aria-label='Price' value='\(1200+n*100)' readonly><a href='/listing/\((n+1)%3)'>Next listing</a>") }
                else { response = self.page("Routine Scout practice form",content:"<h1>Add a person</h1><p id='status' role='status'>\(self.submissions.count) people added</p><form method='POST' action='/submit'><label for='name'>Name</label><input id='name' aria-label='Name' name='Name' required><label for='email'>Email</label><input id='email' aria-label='Email' name='Email' type='email' required><button type='submit'>Submit</button></form><p>Local practice only. Nothing is sent outside this Mac.</p>") }
            }
            let data = Data(response.utf8); let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content:Data(head.utf8)+data,completion:.contentProcessed { _ in connection.cancel() })
        }
    }
    private func page(_ title: String,content: String) -> String { "<!doctype html><html lang='en'><head><meta charset='utf-8'><title>\(title)</title><style>body{font:18px -apple-system;max-width:600px;margin:70px auto;color:#183c39;background:#f2f7f4}label{display:block;margin-top:24px}input{display:block;font:inherit;padding:12px;width:95%;border:1px solid #779b94;border-radius:8px}button,a{display:inline-block;font:inherit;padding:12px 20px;margin-top:24px;background:#196c5c;color:white;border:0;border-radius:8px}p{color:#4d6561}</style></head><body>\(content)</body></html>" }
}
