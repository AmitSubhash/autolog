import XCTest
@testable import ContextD

final class FocusContextAnalyzerTests: XCTestCase {
    func testAnalyzeMarksOnTaskStudyCoverage() throws {
        let block = AutoLogFocusBlock(
            id: "block-1",
            task: "diffusion.fyi read through full.",
            taskSlug: "diffusion-fyi-read-through-full",
            startedAt: "2026-04-12T13:15:12",
            endedAt: nil,
            doneWhen: nil,
            artifactGoal: nil,
            artifact: nil,
            driftBudgetMinutes: 20,
            score: nil,
            notes: nil,
            nextStep: nil,
            source: "emacs-org",
            status: "active"
        )

        let analysis = FocusContextAnalyzer.analyze(
            focusBlock: block,
            appNames: ["Brave Browser"],
            windowTitles: ["Fundamentals — diffusion.fyi - Brave"],
            urls: ["https://diffusion.fyi/tutorials/fundamentals"],
            text: "Reading diffusion.fyi fundamentals on DDPM and stochastic differential equations.",
            previousAlignment: nil
        )

        XCTAssertEqual(analysis.focusAlignment, FocusAlignment.onTask.rawValue)
        let coverage = FocusContextAnalyzer.decodeStudyCoverage(analysis.studyCoverageJSON)
        XCTAssertEqual(coverage?.resource, "diffusion.fyi")
        XCTAssertTrue(coverage?.sections.contains("Fundamentals") == true)
        XCTAssertTrue(coverage?.concepts.contains("DDPM") == true)
    }

    func testAnalyzeMarksRecoveredAfterOffTask() {
        let block = AutoLogFocusBlock(
            id: "block-1",
            task: "diffusion.fyi read through full.",
            taskSlug: "diffusion-fyi-read-through-full",
            startedAt: "2026-04-12T13:15:12",
            endedAt: nil,
            doneWhen: nil,
            artifactGoal: nil,
            artifact: nil,
            driftBudgetMinutes: 20,
            score: nil,
            notes: nil,
            nextStep: nil,
            source: "emacs-org",
            status: "active"
        )

        let analysis = FocusContextAnalyzer.analyze(
            focusBlock: block,
            appNames: ["Brave Browser"],
            windowTitles: ["Flow Matching — diffusion.fyi - Brave"],
            urls: ["https://diffusion.fyi/tutorials/flow-matching"],
            text: "Reading flow matching and optimal transport on diffusion.fyi.",
            previousAlignment: FocusAlignment.offTask.rawValue
        )

        XCTAssertEqual(analysis.focusAlignment, FocusAlignment.recovered.rawValue)
    }

    func testAnalyzeMarksOffTaskForShopping() {
        let block = AutoLogFocusBlock(
            id: "block-1",
            task: "diffusion.fyi read through full.",
            taskSlug: "diffusion-fyi-read-through-full",
            startedAt: "2026-04-12T13:15:12",
            endedAt: nil,
            doneWhen: nil,
            artifactGoal: nil,
            artifact: nil,
            driftBudgetMinutes: 20,
            score: nil,
            notes: nil,
            nextStep: nil,
            source: "emacs-org",
            status: "active"
        )

        let analysis = FocusContextAnalyzer.analyze(
            focusBlock: block,
            appNames: ["Safari"],
            windowTitles: ["Amazon.com Shopping Cart"],
            urls: ["https://www.amazon.com/checkout"],
            text: "User browsed Amazon.com shopping deals and checkout pages.",
            previousAlignment: nil
        )

        XCTAssertEqual(analysis.focusAlignment, FocusAlignment.offTask.rawValue)
    }
}
