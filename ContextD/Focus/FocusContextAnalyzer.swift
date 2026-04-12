import Foundation

struct StudyCoverage: Codable, Sendable, Equatable {
    let resource: String?
    let sections: [String]
    let concepts: [String]
}

enum FocusAlignment: String, Codable, Sendable {
    case onTask = "on_task"
    case taskAdjacent = "task_adjacent"
    case offTask = "off_task"
    case recovered = "recovered"
}

enum FocusContextAnalyzer {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "at", "by", "for", "from", "full", "i", "in",
        "is", "it", "learn", "of", "on", "please", "read", "the", "through",
        "to", "with",
    ]

    private static let offTaskTerms: [String] = [
        "amazon", "facebook", "instagram", "shopping", "checkout", "delivery",
        "hair conditioner", "nizoral", "curly hair",
    ]

    private static let adjacentTerms: [String] = [
        "benchmark", "codex", "diagnostic", "evo", "experiment", "finder",
        "git", "memory", "monitoring", "terminal", "training",
    ]

    private static let browserApps: Set<String> = [
        "Arc", "Brave Browser", "Firefox", "Google Chrome", "Safari",
    ]

    private static let conceptSignals: [(label: String, patterns: [String])] = [
        ("DDPM", ["ddpm", "denoising diffusion probabilistic models"]),
        ("Flow Matching", ["flow matching"]),
        ("SDE", ["sde", "stochastic differential equation", "stochastic differential equations"]),
        ("Score-Based Models", ["score-based", "score function", "score-based generation"]),
        ("Optimal Transport", ["optimal transport", "transport between gaussians"]),
        ("Noise Schedules", ["noise schedule", "noise schedules"]),
        ("Forward Diffusion", ["forward diffusion"]),
        ("Reverse Diffusion", ["reverse diffusion"]),
        ("Langevin Dynamics", ["langevin dynamics"]),
    ]

    static func analyze(
        focusBlock: AutoLogFocusBlock?,
        appNames: [String],
        windowTitles: [String],
        urls: [String],
        text: String,
        previousAlignment: String?
    ) -> (focusAlignment: String?, studyCoverageJSON: String?) {
        guard let focusBlock else { return (nil, nil) }

        let baseAlignment = classifyBaseAlignment(
            focusBlock: focusBlock,
            appNames: appNames,
            windowTitles: windowTitles,
            urls: urls,
            text: text
        )

        let alignment: FocusAlignment
        if previousAlignment == FocusAlignment.offTask.rawValue,
           baseAlignment == .onTask || baseAlignment == .taskAdjacent {
            alignment = .recovered
        } else {
            alignment = baseAlignment
        }

        let coverage = buildStudyCoverage(
            focusBlock: focusBlock,
            windowTitles: windowTitles,
            urls: urls,
            text: text
        )

        return (
            focusAlignment: alignment.rawValue,
            studyCoverageJSON: encodeStudyCoverage(coverage)
        )
    }

    static func aggregateFocusAlignment(summaryAlignments: [String]) -> String? {
        let valid = summaryAlignments.compactMap(FocusAlignment.init(rawValue:))
        guard !valid.isEmpty else { return nil }

        if valid.contains(.recovered) { return FocusAlignment.recovered.rawValue }

        let counts = Dictionary(grouping: valid, by: { $0 }).mapValues(\.count)
        if (counts[.offTask] ?? 0) > (counts[.onTask] ?? 0) {
            return FocusAlignment.offTask.rawValue
        }
        if (counts[.onTask] ?? 0) >= (counts[.taskAdjacent] ?? 0) {
            return FocusAlignment.onTask.rawValue
        }
        return FocusAlignment.taskAdjacent.rawValue
    }

    static func aggregateStudyCoverage(_ coverages: [StudyCoverage]) -> String? {
        guard !coverages.isEmpty else { return nil }

        let resource = coverages.compactMap(\.resource)
            .reduce(into: [String: Int]()) { counts, value in counts[value, default: 0] += 1 }
            .sorted { lhs, rhs in lhs.value > rhs.value }
            .first?.key

        let sections = Set(coverages.flatMap(\.sections)).sorted()
        let concepts = Set(coverages.flatMap(\.concepts)).sorted()

        return encodeStudyCoverage(
            StudyCoverage(resource: resource, sections: sections, concepts: concepts)
        )
    }

    static func decodeStudyCoverage(_ json: String?) -> StudyCoverage? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StudyCoverage.self, from: data)
    }

    private static func encodeStudyCoverage(_ coverage: StudyCoverage?) -> String? {
        guard let coverage,
              (!coverage.sections.isEmpty || !coverage.concepts.isEmpty || coverage.resource != nil),
              let data = try? JSONEncoder().encode(coverage) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func classifyBaseAlignment(
        focusBlock: AutoLogFocusBlock,
        appNames: [String],
        windowTitles: [String],
        urls: [String],
        text: String
    ) -> FocusAlignment {
        let haystack = ([focusBlock.task, text] + windowTitles + urls)
            .dropFirst()
            .joined(separator: "\n")
            .lowercased()

        let taskKeywords = extractTaskKeywords(from: focusBlock.task)
        let keywordHits = taskKeywords.filter { haystack.contains($0) }.count
        let hasOffTaskSignal = offTaskTerms.contains { haystack.contains($0) }
        let hasAdjacentSignal = adjacentTerms.contains { haystack.contains($0) }
            || appNames.contains { ["Terminal", "Finder", "Emacs"].contains($0) }
        let hasBrowserFocus = appNames.contains { browserApps.contains($0) }

        if hasOffTaskSignal && keywordHits == 0 {
            return .offTask
        }
        if keywordHits >= 2 || (keywordHits >= 1 && hasBrowserFocus && !hasOffTaskSignal) {
            return .onTask
        }
        if keywordHits >= 1 || hasAdjacentSignal {
            return .taskAdjacent
        }
        if hasOffTaskSignal {
            return .offTask
        }
        return .taskAdjacent
    }

    private static func buildStudyCoverage(
        focusBlock: AutoLogFocusBlock,
        windowTitles: [String],
        urls: [String],
        text: String
    ) -> StudyCoverage? {
        let lowerTask = focusBlock.task.lowercased()
        let isStudyTask = ["learn", "read", "study", "tutorial", "chapter", "module"].contains {
            lowerTask.contains($0)
        }
        guard isStudyTask else { return nil }

        let combined = (windowTitles + urls + [text]).joined(separator: "\n").lowercased()

        let resource = urls.compactMap(resourceName(from:)).first
            ?? windowTitles.compactMap(resourceName(from:)).first

        var sections = Set<String>()
        for title in windowTitles {
            for part in title.split(separator: "—").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard !part.isEmpty, part.count > 2, part.count < 60 else { continue }
                if part.lowercased().contains("brave") || part.lowercased().contains("audio playing") {
                    continue
                }
                sections.insert(part)
            }
        }

        for url in urls {
            if let section = sectionName(from: url) {
                sections.insert(section)
            }
        }

        let concepts = conceptSignals.compactMap { signal in
            signal.patterns.contains { combined.contains($0) } ? signal.label : nil
        }

        let coverage = StudyCoverage(
            resource: resource,
            sections: sections.sorted(),
            concepts: Array(Set(concepts)).sorted()
        )
        return (!coverage.sections.isEmpty || !coverage.concepts.isEmpty || coverage.resource != nil)
            ? coverage
            : nil
    }

    private static func resourceName(from value: String) -> String? {
        let lower = value.lowercased()
        if lower.contains("diffusion.fyi") { return "diffusion.fyi" }
        if lower.contains("claude") { return "Claude" }
        if let url = URL(string: value), let host = url.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return nil
    }

    private static func sectionName(from value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        let components = url.pathComponents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "/" && $0 != "tutorials" }
        guard let last = components.last, last.count > 2 else { return nil }
        return last.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private static func extractTaskKeywords(from task: String) -> [String] {
        task.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "." }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }
}
