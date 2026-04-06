import Foundation

/// Executes `claude -p` as a subprocess for each LLM request.
/// No API key required. Uses the authenticated Claude Code CLI session.
final class ClaudeShellClient: LLMClient, @unchecked Sendable {

    private let logger = DualLogger(category: "ClaudeShellClient")

    // MARK: - Model alias mapping

    /// Maps OpenRouter-style model IDs to `claude --model` aliases.
    private static let aliases: [String: String] = [
        "anthropic/claude-haiku-4-5": "haiku",
        "anthropic/claude-haiku-4-5-20251001": "haiku",
        "anthropic/claude-sonnet-4-6": "sonnet",
        "anthropic/claude-sonnet-4-5": "sonnet",
        "anthropic/claude-opus-4-6": "opus",
        "anthropic/claude-opus-4-5": "opus",
    ]

    private static func alias(for model: String) -> String {
        if let known = aliases[model] {
            return known
        }
        if model.hasPrefix("anthropic/") {
            return String(model.dropFirst(10))
        }
        return model
    }

    // MARK: - CLI discovery

    /// Returns the absolute path to the `claude` binary, or nil if not found.
    static func findPath() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which claude 2>/dev/null"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let found = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? nil : found
    }

    /// Returns true if the `claude` CLI binary is accessible.
    static func isAvailable() -> Bool {
        findPath() != nil
    }

    // MARK: - LLMClient

    func complete(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> String {
        try await completeWithUsage(
            messages: messages,
            model: model,
            maxTokens: maxTokens,
            systemPrompt: systemPrompt,
            temperature: temperature,
            responseFormat: responseFormat
        ).text
    }

    func completeWithUsage(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> LLMResponse {
        guard let claudePath = Self.findPath() else {
            throw LLMError.cliNotFound
        }

        let systemParts = ([systemPrompt] + messages.filter { $0.role == "system" }.map {
            Optional($0.content)
        })
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        let userContent = messages
            .filter { $0.role != "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        let alias = Self.alias(for: model)

        var args = ["-p", "--model", alias, "--output-format", "json", "--max-turns", "1"]
        if !systemParts.isEmpty {
            args += ["--system-prompt", systemParts.joined(separator: "\n\n")]
        }

        logger.debug("claude \(args.prefix(4).joined(separator: " ")) ...")

        let raw = try await runProcess(path: claudePath, args: args, stdin: userContent)

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse claude output: \(raw.prefix(300))")
            throw LLMError.invalidResponse
        }

        if let isError = json["is_error"] as? Bool, isError {
            let msg = json["result"] as? String ?? "Unknown error from claude"
            throw LLMError.httpError(statusCode: 1, body: msg)
        }

        guard let text = json["result"] as? String else {
            logger.error("No 'result' field in claude output: \(raw.prefix(300))")
            throw LLMError.invalidResponse
        }

        return LLMResponse(text: text, usage: nil)
    }

    // MARK: - Subprocess execution

    private func runProcess(path: String, args: [String], stdin: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            proc.terminationHandler = { process in
                let out = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let err = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let body = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: LLMError.httpError(
                        statusCode: Int(process.terminationStatus),
                        body: body.isEmpty
                            ? "claude exited with status \(process.terminationStatus)"
                            : body
                    ))
                }
            }

            do {
                try proc.run()
                stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                proc.terminationHandler = nil
                continuation.resume(throwing: LLMError.networkError(error))
            }
        }
    }
}
