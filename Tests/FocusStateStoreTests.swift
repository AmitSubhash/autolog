import XCTest
@testable import ContextD

final class FocusStateStoreTests: XCTestCase {
    private let focusDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/autolog")
    private var originalCurrent: Data?
    private var originalBlocks: Data?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let currentPath = focusDir.appendingPathComponent("focus-state.json")
        let blocksPath = focusDir.appendingPathComponent("focus-blocks.jsonl")
        originalCurrent = try? Data(contentsOf: currentPath)
        originalBlocks = try? Data(contentsOf: blocksPath)
        try FileManager.default.createDirectory(at: focusDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try restore("focus-state.json", originalCurrent)
        try restore("focus-blocks.jsonl", originalBlocks)
        try super.tearDownWithError()
    }

    func testLoadCurrentFocusState() throws {
        let json = """
        {
          "id": "block-123",
          "task": "Fix PigBET preprocessing",
          "task_slug": "fix-pigbet-preprocessing",
          "started_at": "2026-03-27T08:30:00",
          "done_when": "passing run + QA screenshot",
          "artifact_goal": "commit + screenshot",
          "artifact": "",
          "drift_budget_minutes": 10,
          "source": "emacs-org",
          "scorecard_path": "/tmp/scorecard.org",
          "status": "active"
        }
        """
        try write("focus-state.json", contents: json)

        let state = FocusStateStore.loadCurrent()
        XCTAssertEqual(state?.task, "Fix PigBET preprocessing")
        XCTAssertEqual(state?.taskSlug, "fix-pigbet-preprocessing")
        XCTAssertEqual(state?.driftBudgetMinutes, 10)
    }

    func testLoadBlocksIncludesOpenState() throws {
        let blocks = """
        {"id":"old-1","task":"Old block","task_slug":"old-block","started_at":"2026-03-26T20:00:00","ended_at":"2026-03-26T21:00:00","done_when":"done","artifact_goal":"commit","artifact":"abc123","drift_budget_minutes":10,"score":8,"notes":"solid","source":"emacs-org","status":"completed"}
        """
        let current = """
        {
          "id": "current-1",
          "task": "Current block",
          "task_slug": "current-block",
          "started_at": "2026-03-27T09:00:00",
          "done_when": "ship artifact",
          "artifact_goal": "commit",
          "artifact": "",
          "drift_budget_minutes": 12,
          "source": "emacs-org",
          "scorecard_path": "/tmp/scorecard.org",
          "status": "active"
        }
        """
        try write("focus-blocks.jsonl", contents: blocks + "\n")
        try write("focus-state.json", contents: current)

        let loaded = FocusStateStore.loadBlocks(limit: 10, includeOpen: true)
        XCTAssertEqual(loaded.first?.task, "Current block")
        XCTAssertEqual(loaded.last?.task, "Old block")
    }

    private func write(_ name: String, contents: String) throws {
        let url = focusDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func restore(_ name: String, _ data: Data?) throws {
        let url = focusDir.appendingPathComponent(name)
        if let data {
            try data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
