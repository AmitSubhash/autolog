import Foundation

/// OpenRouter API client. Hand-rolled using URLSession.
/// Supports any model available on OpenRouter via the /api/v1/chat/completions endpoint.
final class OpenRouterClient: LLMClient, Sendable {
    /// LLM endpoint URL. Configurable via UserDefaults "llmEndpointURL" to point
    /// at a local claude -p proxy instead of OpenRouter.
    private static var endpoint: URL {
        if let custom = UserDefaults.standard.string(forKey: "llmEndpointURL"),
           let url = URL(string: custom) {
            return url
        }
        return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    }

    /// True when using a local proxy (no API key needed).
    static var isUsingProxy: Bool {
        if let custom = UserDefaults.standard.string(forKey: "llmEndpointURL"), !custom.isEmpty {
            return true
        }
        return false
    }

    private let logger = DualLogger(category: "OpenRouterClient")

    /// Maximum number of retry attempts for transient errors.
    private let maxRetries = 3

    // MARK: - API Key (file-based, no Keychain)

    private static let apiKeyFile = "openrouter_api_key"

    /// Read the API key from file storage.
    static func readAPIKey() -> String? {
        KeychainHelper.read(key: apiKeyFile)
    }

    /// Save the API key to file storage.
    static func saveAPIKey(_ key: String) throws {
        try KeychainHelper.save(
            key: apiKeyFile,
            value: key.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Check whether an API key is available (file or proxy).
    /// Returns true in proxy mode (no key needed).
    static func hasAPIKey() -> Bool {
        if isUsingProxy { return true }
        return KeychainHelper.exists(key: apiKeyFile)
    }

    /// Delete the API key.
    static func deleteAPIKey() {
        KeychainHelper.delete(key: apiKeyFile)
    }

    // MARK: - LLMClient Protocol

    /// Convenience: delegates to `completeWithUsage` and returns just the text.
    func complete(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> String {
        let response = try await completeWithUsage(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature,
            responseFormat: responseFormat
        )
        return response.text
    }

    func completeWithUsage(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> LLMResponse {
        // When using a local proxy (claude -p), no API key is needed.
        // Skip keychain access entirely for proxy mode to avoid macOS prompt.
        let apiKey: String? = Self.isUsingProxy ? "" : Self.readAPIKey()
        guard let apiKey else {
            throw LLMError.noAPIKey
        }

        let requestBody = buildRequestBody(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature,
            responseFormat: responseFormat
        )

        var lastError: Error = LLMError.invalidResponse

        for attempt in 0..<maxRetries {
            do {
                let response = try await sendRequestFull(body: requestBody, apiKey: apiKey)
                return response
            } catch LLMError.rateLimited(let retryAfter) {
                let delay = retryAfter ?? Double(pow(2.0, Double(attempt)))
                logger.warning("Rate limited, retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.rateLimited(retryAfter: retryAfter)
            } catch LLMError.httpError(let code, let body) where code >= 500 {
                let delay = Double(pow(2.0, Double(attempt)))
                logger.warning("Server error \(code), retrying in \(delay)s (attempt \(attempt + 1)/\(self.maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.httpError(statusCode: code, body: body)
            } catch {
                throw error
            }
        }

        throw lastError
    }

    // MARK: - Private

    private func buildRequestBody(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) -> [String: Any] {
        // OpenRouter uses the OpenAI chat completions format.
        // The system prompt is a message with role "system".
        var allMessages: [[String: String]] = []

        if let system = systemPrompt {
            allMessages.append(["role": "system", "content": system])
        }

        allMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": allMessages,
        ]

        // Add response_format if requested (e.g., "json_object" for structured output)
        if let format = responseFormat {
            body["response_format"] = ["type": format]
        }

        return body
    }

    private func sendRequestFull(body: [String: Any], apiKey: String) async throws -> LLMResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        switch httpResponse.statusCode {
        case 200:
            return try parseResponseFull(data: data)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: responseBody)
        }
    }

    /// Parse an OpenAI-compatible chat completions response.
    private func parseResponseFull(data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.invalidResponse
        }

        var usage: LLMTokenUsage? = nil
        if let usageDict = json["usage"] as? [String: Any],
           let inputTokens = usageDict["prompt_tokens"] as? Int,
           let outputTokens = usageDict["completion_tokens"] as? Int {
            usage = LLMTokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        }

        return LLMResponse(text: text, usage: usage)
    }
}
