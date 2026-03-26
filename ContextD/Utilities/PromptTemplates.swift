import Foundation
import os.log

/// Default and configurable prompt templates for summarization and enrichment.
/// All templates use simple {placeholder} substitution.
enum PromptTemplates {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AutoLog",
        category: "PromptTemplates"
    )

    // MARK: - Summarization

    static let summarizationSystem = """
        You summarize computer screen activity captured via OCR. The screen data \
        is organized as keyframes (full screen snapshots) and deltas (only text \
        that changed between snapshots).

        For key_topics, REUSE canonical names from this vocabulary when they match:

        Projects: Pigbet, AutoLog, 3Brown1Blue, RAS-Optimize, AutoResearchClaw, \
        Reallms, Deep Variance, GlazerAI, Thehuzz
        Research: Brain-Computer Interface, Neuroimaging, Image Registration, \
        Brain Extraction, Preprocessing, Monte Carlo Photon Transport, Diffuse Optical \
        Tomography, Piglet Neuroimaging
        Tech: Python, Pytorch, Manim, SwiftUI, Vllm, Slurm, Dipy, Emacs, Obsidian, \
        Tableau, Docker, React, Next.js
        Infra: Hpc, Bigred200, Gpu, Cuda
        Career: Job Search, Cv, Portfolio, Professional, Alumni Employment, Hackathon
        Meta: Claude Code, Agent Harness, Browser-Use, Knowledge Graph, \
        Cross-Domain Analogy, Pipeline, Dashboard
        Business: Startup, India Ai, Presentation

        If the activity matches one of the above, use that exact name. Only invent a \
        new topic name if nothing above fits. New names should be Title Case, 1-3 words, \
        and specific (a noun, not a verb or action).

        Extract ONLY:
        - Project names visible on screen
        - Tool/app names ONLY if they are the focus, not just visible \
        (e.g., "Obsidian" if configuring it, NOT "Terminal" just because it was open)
        - Concepts being researched (e.g., "Monte Carlo Photon Transport", NOT "research")
        - People or organizations mentioned
        - Specific technologies being used (e.g., "Pytorch", NOT "code editing")

        NEVER include:
        - Generic descriptions ("Activity Monitoring", "Screen Capture", "Text Editing")
        - Variations of a canonical topic (use the canonical name above instead)
        - Obvious container apps (Terminal, Chrome, Finder, Safari) unless they are \
        the subject of the work
        - Action words as topics ("Debugging", "Browsing", "Coding", "Reading")
        - Terminal tab names, usernames, or directory names as topics
        - The tool "autolog" itself unless the user is actively developing it

        For activity_type, classify as exactly ONE of:
        - "coding" (writing, debugging, building, testing code)
        - "research" (reading docs, browsing Stack Overflow, searching)
        - "writing" (drafting text, notes, emails, papers)
        - "communication" (Slack, email, messaging, video calls)
        - "design" (Figma, visual design, UI work)
        - "admin" (system settings, file management, installations)
        - "review" (code review, PR review, reading diffs)
        - "other" (anything that does not fit the above)

        For files_mentioned, extract file paths or filenames visible on screen.
        For urls_visited, extract URLs visible in browser address bars or links.

        Constraints:
        - Summary: 2-3 sentences maximum, under 100 words
        - Topics: 2-5 maximum. Prefer fewer, more specific topics over many vague ones
        - files_mentioned: actual file paths/names seen, not guesses. Empty array if none.
        - urls_visited: actual URLs seen, not guesses. Empty array if none.
        - Exclude passwords, personal messages, financial account numbers, and \
        other sensitive data from all fields

        Respond ONLY in this JSON format (no markdown, no explanation):
        {"summary": "...", "key_topics": ["topic1"], "activity_type": "coding", \
        "files_mentioned": ["/path/to/file.swift"], "urls_visited": ["https://..."]}
        """

    static let summarizationUser = """
        Summarize this computer activity segment:

        Time: {start_time} to {end_time}
        Duration: {duration}
        Focused Application: {app_name}
        Window Title: {window_title}
        All Visible Windows: {visible_windows}
        Documents Open: {document_paths}
        URLs Visible: {browser_urls}

        Full screen OCR text (everything visible on screen):
        {ocr_samples}
        """

    // MARK: - Enrichment Pass 1: Relevance Judging

    static let enrichmentPass1System = """
        You are a relevance judge for a context enrichment system. The user has written \
        a prompt they want to send to an AI, and you need to identify which of their recent \
        computer activities are relevant to that prompt.

        The user's prompt likely references things they recently saw on their screen. Your job \
        is to find those references.

        Respond ONLY in this JSON format (no markdown, no explanation):
        [{"id": 42, "reason": "brief explanation of relevance"}, ...]

        Example -- given summaries [12], [37], [42] and a prompt about "fix the login bug":
        [{"id": 42, "reason": "Shows the login error traceback in Terminal"}, \
        {"id": 37, "reason": "Has the auth.py file open with the login handler"}]

        If nothing is relevant, respond with an empty array: []
        """

    static let enrichmentPass1User = """
        ## User's Prompt
        {query}

        ## Recent Activity Summaries
        {summaries}

        Which summaries contain information the user might be referring to or that would \
        provide useful context for their prompt?
        """

    // MARK: - Enrichment Pass 2: Context Synthesis

    static let enrichmentPass2System = """
        You are a context enrichment assistant. Given a user's prompt and detailed screen \
        captures from their recent computer activity, produce contextual references that \
        should be appended to the user's prompt to give an AI full context.

        Rules:
        - Only include genuinely relevant information
        - Be concise but specific -- include exact names, values, code snippets, etc.
        - Order by relevance (most relevant first)
        - Maximum 10 references
        - Exclude passwords, tokens, and other credentials

        Format each reference as a structured line:
        - [HH:MM, AppName - WindowTitle] Description of what was on screen...

        Respond ONLY with the reference lines under a heading, nothing else. Example:

        ## Recent Screen Context
        - [14:30, Xcode - main.swift] User was editing the processData function, adding a nil check on line 42
        - [14:25, Chrome - Stack Overflow] User was reading about async/await error handling patterns in Swift
        - [14:20, Terminal - zsh] Build failed with "cannot find type DataProcessor in scope" on line 87
        """

    static let enrichmentPass2User = """
        ## User's Prompt
        {query}

        ## Detailed Screen Activity
        {captures}

        Produce structured context references for the user's prompt.
        """

    // MARK: - Enrichment Single-Pass (merged relevance + synthesis)

    static let enrichmentSinglePassSystem = """
        You are a context enrichment assistant. The user is about to send a prompt to an AI \
        assistant and wants relevant context from their recent computer activity appended to it.

        You receive two types of context:
        1. SUMMARIES: High-level descriptions of activity windows (each covers several minutes). \
           These provide temporal and topical context.
        2. CAPTURES: Detailed OCR text from recent screen snapshots. These provide exact text, \
           code, and content the user was looking at.

        Your task:
        1. Identify which summaries and captures are relevant to the user's prompt.
        2. Produce structured context references from the RELEVANT items only.
        3. Ignore items that are not related to the user's prompt.

        Rules:
        - Only include genuinely relevant information
        - Be concise but specific -- include exact names, values, code snippets, etc.
        - Order by relevance (most relevant first)
        - Maximum 10 references
        - Exclude passwords, tokens, and other credentials
        - Prefer captures (exact text) over summaries (paraphrased) when both cover the same content

        Format each reference as a structured line:
        - [HH:MM, AppName - WindowTitle] Description of what was on screen...

        Respond ONLY with the reference lines under a heading, nothing else. Example:

        ## Recent Screen Context
        - [14:30, Xcode - main.swift] User was editing the processData function, adding a nil check on line 42
        - [14:25, Chrome - Stack Overflow] User was reading about async/await error handling patterns in Swift
        - [14:20, Terminal - zsh] Build failed with "cannot find type DataProcessor in scope" on line 87

        If nothing is relevant, respond with:

        ## Recent Screen Context
        _(No relevant context found.)_
        """

    static let enrichmentSinglePassUser = """
        ## User's Prompt
        {query}

        ## Activity Summaries (high-level)
        {summaries}

        ## Detailed Screen Captures (recent OCR text)
        {captures}

        Identify relevant context and produce structured reference lines for the user's prompt.
        """

    // MARK: - Citation Pass 2 (API / structured JSON output)

    static let citationPass2System = """
        You are a context retrieval system. Given a user's query and detailed screen \
        captures from their recent computer activity, extract structured citations that \
        are relevant to the query.

        Rules:
        - Only include genuinely relevant information
        - Be concise but specific -- include exact names, values, code snippets, etc.
        - Order by relevance (most relevant first)
        - Maximum 10 citations
        - Each citation must include the timestamp, app name, and window title from the capture data
        - Exclude passwords, tokens, and other credentials from citations

        Respond ONLY with a JSON array (no markdown, no explanation). Example:
        [
          {
            "timestamp": "2026-03-12T10:23:45Z",
            "app_name": "Google Chrome",
            "window_title": "Pull Request #482 - GitHub",
            "relevant_text": "Refactored OAuth2 token refresh logic to handle concurrent requests...",
            "relevance_explanation": "This PR review discussed the auth token changes the user is asking about",
            "source": "capture"
          }
        ]

        If nothing is relevant, respond with an empty array: []
        """

    static let citationPass2User = """
        ## User's Query
        {query}

        ## Detailed Screen Activity
        {captures}

        Extract structured JSON citations with relevant context for the user's query.
        """

    // MARK: - Activity Inference

    static let activityInferenceSystem = """
        You group app sessions into logical activities/tasks. Each session represents \
        a contiguous stretch of using one application.

        Group sessions that represent the same logical task, even across different apps. \
        For example, "debugging a build error" might involve Terminal, Xcode, and Safari.

        Rules:
        - Each session must belong to exactly one activity
        - Activity names MUST describe the specific task, not the app or action category
        - Even single sessions MUST get a descriptive name based on their summary text
        - Confidence: 0.9+ for clear groups, 0.5-0.8 for uncertain groupings

        GOOD activity names (specific, describe the task):
        - "Debugging PigBET NIfTI orientation mismatch"
        - "Reviewing alumni employment Tableau dashboard"
        - "Configuring vLLM serving on BigRed200"
        - "Writing BCI explainer video storyboard"
        - "Submitting SLURM job for fp8 training run"

        BAD activity names (generic, describe the app or action):
        - "Terminal command execution"
        - "Python code development and testing"
        - "Safari web browsing session"
        - "Quick Python script execution"
        - "File management and organization"
        - "Coding session"

        For key_topics, reuse canonical names when possible:
        Pigbet, AutoLog, 3Brown1Blue, Neuroimaging, Image Registration, \
        Python, Pytorch, Manim, Vllm, Slurm, Hpc, Bigred200, Gpu, \
        Job Search, Cv, Claude Code, Knowledge Graph, Startup, Dashboard

        Respond ONLY in JSON (no markdown, no explanation):
        {"activities": [
            {"name": "...", "description": "...", "session_ids": [1, 2], \
        "key_topics": ["topic1"], "confidence": 0.9}
        ]}
        """

    static let activityInferenceUser = """
        Group these app sessions into logical activities:

        {sessions}

        Each session has: id, app, window titles, document paths, URLs, time range, \
        and overlapping summary text.
        """

    // MARK: - Template Rendering

    /// Render a template by replacing {placeholder} tokens with values.
    ///
    /// Uses a single-pass scan to avoid double-substitution when replacement
    /// values themselves contain placeholder-like text (e.g., OCR text with "{query}").
    /// Logs a warning for any unreplaced {placeholder} tokens found after substitution.
    static func render(_ template: String, values: [String: String]) -> String {
        var result = ""
        var index = template.startIndex

        while index < template.endIndex {
            if template[index] == "{" {
                // Look for matching closing brace
                if let closeBrace = template[index...].firstIndex(of: "}") {
                    let key = String(template[template.index(after: index)..<closeBrace])
                    if let replacement = values[key] {
                        result += replacement
                        index = template.index(after: closeBrace)
                        continue
                    }
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }

        // Validate: warn about unreplaced placeholders
        let unresolved = findUnresolvedPlaceholders(result)
        if !unresolved.isEmpty {
            logger.warning(
                "Unreplaced placeholders in rendered template: \(unresolved.joined(separator: ", "))"
            )
        }

        return result
    }

    /// Scan text for {placeholder} tokens that were not substituted.
    private static func findUnresolvedPlaceholders(_ text: String) -> [String] {
        var placeholders: [String] = []
        var searchStart = text.startIndex
        while let openBrace = text.range(of: "{", range: searchStart..<text.endIndex) {
            guard let closeBrace = text.range(
                of: "}",
                range: openBrace.upperBound..<text.endIndex
            ) else {
                break
            }
            let name = String(text[openBrace.upperBound..<closeBrace.lowerBound])
            // Only flag simple identifiers (word chars), skip JSON or nested braces
            if name.range(of: #"^\w+$"#, options: .regularExpression) != nil {
                placeholders.append("{\(name)}")
            }
            searchStart = closeBrace.upperBound
        }
        return placeholders
    }
}

// MARK: - UserDefaults Keys for Custom Templates

extension PromptTemplates {
    /// UserDefaults keys for user-customized prompt templates.
    enum SettingsKey: String {
        case summarizationSystem = "prompt_summarization_system"
        case summarizationUser = "prompt_summarization_user"
        case enrichmentPass1System = "prompt_enrichment_pass1_system"
        case enrichmentPass1User = "prompt_enrichment_pass1_user"
        case enrichmentPass2System = "prompt_enrichment_pass2_system"
        case enrichmentPass2User = "prompt_enrichment_pass2_user"
        case citationPass2System = "prompt_citation_pass2_system"
        case citationPass2User = "prompt_citation_pass2_user"
        case enrichmentSinglePassSystem = "prompt_enrichment_single_pass_system"
        case enrichmentSinglePassUser = "prompt_enrichment_single_pass_user"
        case activityInferenceSystem = "prompt_activity_inference_system"
        case activityInferenceUser = "prompt_activity_inference_user"
    }

    /// Get a template, preferring the user's custom version from UserDefaults.
    static func template(for key: SettingsKey) -> String {
        if let custom = UserDefaults.standard.string(forKey: key.rawValue), !custom.isEmpty {
            return custom
        }
        switch key {
        case .summarizationSystem: return summarizationSystem
        case .summarizationUser: return summarizationUser
        case .enrichmentPass1System: return enrichmentPass1System
        case .enrichmentPass1User: return enrichmentPass1User
        case .enrichmentPass2System: return enrichmentPass2System
        case .enrichmentPass2User: return enrichmentPass2User
        case .citationPass2System: return citationPass2System
        case .citationPass2User: return citationPass2User
        case .enrichmentSinglePassSystem: return enrichmentSinglePassSystem
        case .enrichmentSinglePassUser: return enrichmentSinglePassUser
        case .activityInferenceSystem: return activityInferenceSystem
        case .activityInferenceUser: return activityInferenceUser
        }
    }
}

// MARK: - Model Pricing and Cost Estimation

extension PromptTemplates {
    /// Per-million-token pricing for models routed through OpenRouter.
    /// Updated 2026-03. Check https://openrouter.ai/models for current prices.
    struct ModelPricing {
        let inputPerMtok: Double
        let outputPerMtok: Double
    }

    static let pricing: [String: ModelPricing] = [
        "anthropic/claude-haiku-4-5": ModelPricing(inputPerMtok: 0.80, outputPerMtok: 4.00),
        "anthropic/claude-sonnet-4-6": ModelPricing(inputPerMtok: 3.00, outputPerMtok: 15.00),
        "anthropic/claude-opus-4-5": ModelPricing(inputPerMtok: 15.00, outputPerMtok: 75.00),
    ]

    /// Estimate the dollar cost of a single LLM call.
    /// Returns a formatted string like "$0.0023 (1,234 tok)".
    static func estimateCost(
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> String {
        let totalTokens = inputTokens + outputTokens
        guard let price = pricing[model] else {
            return "$?.?? (\(totalTokens.formatted()) tok, unknown model)"
        }
        let cost = Double(inputTokens) / 1_000_000 * price.inputPerMtok
            + Double(outputTokens) / 1_000_000 * price.outputPerMtok
        return "$\(String(format: "%.4f", cost)) (\(totalTokens.formatted()) tok)"
    }
}
