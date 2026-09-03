import Foundation

/// Streams a rewrite from the Anthropic Messages API.
///
/// There is no official Swift SDK, and the surface needed here is small: one streaming request
/// with a cached system prompt and a single user turn. Streaming is what makes the overlay show
/// the compiled prompt while the tail is still being generated.
struct ClaudeGenerator: TextGenerating {
    /// Reads the key at call time, so saving one in the setup window takes effect immediately.
    var apiKey: @Sendable () -> String?
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(apiKey: @escaping @Sendable () -> String? = { try? Keychain.get(.anthropicAPIKey) }) {
        self.apiKey = apiKey
    }

    func generate(
        _ request: GenerationRequest,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw GenerationError.missingAPIKey }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try body(for: request)

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.transport("No response from Anthropic.")
        }
        guard http.statusCode == 200 else {
            var message = ""
            for try await line in bytes.lines { message += line }
            throw GenerationError.http(status: http.statusCode, message: Self.errorMessage(from: message))
        }

        var text = ""
        var stopReason: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }

            // An error can arrive *after* the 200, for instance when the service is
            // overloaded. Ignoring it would return a half-written rewrite as if it were
            // finished, and paste that into the user's document.
            if let failure = Self.streamError(in: payload) {
                throw GenerationError.http(status: 200, message: failure)
            }
            if let reason = Self.stopReason(in: payload) {
                stopReason = reason
            }
            guard let delta = Self.textDelta(in: payload) else { continue }
            text += delta
            onDelta(delta)
        }

        // A response cut off at max_tokens is shorter, not longer, so no length check can
        // catch it. Treat anything but a clean finish as a failure.
        if let stopReason, stopReason != "end_turn", stopReason != "stop_sequence" {
            throw GenerationError.http(status: 200, message: "the model stopped early (\(stopReason))")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenerationError.emptyResponse }
        return trimmed
    }

    // MARK: Request

    func body(for request: GenerationRequest) throws -> Data {
        var payload: [String: Any] = [
            "model": request.model.identifier,
            "max_tokens": request.maxTokens,
            "stream": true,
            // A cache breakpoint on the system prompt. It only engages once the prefix clears
            // the model's minimum cacheable length, which the small models do not always reach,
            // but it costs nothing to ask and saves 90% of the input cost when it does.
            "system": [[
                "type": "text",
                "text": request.system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": request.user]],
        ]
        // Rewriting spoken text is a literal, structural job. Reasoning models over-delete on
        // it, so thinking is off and effort is low wherever the model accepts those fields.
        if request.model.acceptsDisabledThinking {
            payload["thinking"] = ["type": "disabled"]
        }
        if request.model.supportsEffort {
            payload["output_config"] = ["effort": "low"]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: Parsing

    /// Pulls the text out of one `content_block_delta` event.
    static func textDelta(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let type = object["type"] as? String, type == "error" {
            return nil
        }
        guard let delta = object["delta"] as? [String: Any] else { return nil }
        // Only plain text deltas matter; thinking deltas are off and would be ignored anyway.
        guard let type = delta["type"] as? String, type == "text_delta" else { return nil }
        return delta["text"] as? String
    }

    /// An error event delivered inside an otherwise successful stream.
    static func streamError(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "error"
        else { return nil }
        let error = object["error"] as? [String: Any]
        return (error?["message"] as? String) ?? "the model reported an error"
    }

    /// Why generation stopped, carried on the `message_delta` event.
    static func stopReason(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "message_delta",
              let delta = object["delta"] as? [String: Any]
        else { return nil }
        return delta["stop_reason"] as? String
    }

    /// Extracts a readable message from an error body, which may or may not be JSON.
    static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return body.isEmpty ? "no details" : String(body.prefix(200))
        }
        return message
    }
}
