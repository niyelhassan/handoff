import Foundation

/// Minimal Messages API client.
///
/// Raw HTTP on purpose: there is no official Anthropic SDK for Swift, and one
/// JSON POST does not justify vendoring a community one.
struct ClaudeClient {

    /// Claude Fable 5.1. Naming a task from a handful of accessibility labels
    /// is a judgement call about intent, which is what this tier is for.
    static let model = "claude-fable-5-1"
    /// If the request is declined by a safety classifier, the API re-runs it on
    /// this model inside the same call rather than returning nothing.
    static let fallbackModel = "claude-opus-4-8"

    enum Failure: Error, CustomStringConvertible {
        case noAPIKey
        case http(Int, String)
        case refused(String)
        case malformed(String)
        case transport(String)

        var description: String {
            switch self {
            case .noAPIKey:          return "no API key configured"
            case .http(let c, let m): return "HTTP \(c): \(m)"
            case .refused(let c):    return "declined by the model (\(c))"
            case .malformed(let m):  return "unexpected response: \(m)"
            case .transport(let m):  return m
            }
        }
    }

    let apiKey: String
    var timeout: TimeInterval = 25

    /// Looked up in this order. Nothing is read from the user's shell profile
    /// and nothing is written anywhere - if none of these is set, the feature
    /// stays off and Handoff never contacts the network at all.
    static func discoverKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in ["LOOPY_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY"] {
            if let v = env[name], !v.isEmpty { return v }
        }
        let path = ("~/.handoff/anthropic-key" as NSString).expandingTildeInPath
        if let v = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// One JSON-shaped answer, constrained by `schema`.
    ///
    /// Notable for this model: `thinking` is omitted entirely - it is always on
    /// for Fable 5.1 and sending any explicit configuration is a 400. Depth is
    /// controlled through `output_config.effort` instead.
    func complete(system: String,
                  user: String,
                  schema: [String: Any],
                  effort: String = "low",
                  completion: @escaping @Sendable (Result<[String: Any], Failure>) -> Void) {

        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "fallbacks": [["model": Self.fallbackModel]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        // Keep the payload deterministic so it is easy to log and diff.
        body["metadata"] = ["user_id": "handoff"]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(.malformed("could not encode request")))
            return
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-06-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = data

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            guard let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                completion(.failure(.malformed("body was not JSON")))
                return
            }
            if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                let msg = ((json["error"] as? [String: Any])?["message"] as? String)
                    ?? String(data: data.prefix(300), encoding: .utf8) ?? "-"
                completion(.failure(.http(code, msg)))
                return
            }
            // Checked BEFORE reading content: a decline is an HTTP 200 whose
            // content block is not the answer that was asked for.
            if json["stop_reason"] as? String == "refusal" {
                let category = (json["stop_details"] as? [String: Any])?["category"]
                    as? String ?? "unspecified"
                completion(.failure(.refused(category)))
                return
            }
            guard let content = json["content"] as? [[String: Any]],
                  let text = content.first(where: { $0["type"] as? String == "text" })?["text"]
                    as? String
            else {
                completion(.failure(.malformed("no text block in response")))
                return
            }
            guard let parsed = (try? JSONSerialization.jsonObject(
                with: Data(text.utf8))) as? [String: Any] else {
                completion(.failure(.malformed("text block was not the JSON object requested")))
                return
            }
            completion(.success(parsed))
        }.resume()
    }
}
