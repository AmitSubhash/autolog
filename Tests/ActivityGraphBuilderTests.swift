import XCTest
@testable import ContextD

final class ActivityGraphBuilderTests: XCTestCase {
    func testParseInferenceResponseAcceptsWrappedJSONObject() {
        let response = """
        Here is the grouping result:

        {"activities":[{"name":"Debugging AutoLog API auth","description":"Fixing auth handling","session_ids":[1,2],"key_topics":["AutoLog"],"confidence":0.92}]}

        Hope that helps.
        """

        let parsed = ActivityGraphBuilder.parseInferenceResponse(
            response,
            logger: DualLogger(category: "ActivityGraphBuilderTests")
        )

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "Debugging AutoLog API auth")
        XCTAssertEqual(parsed.first?.sessionIds, [1, 2])
        XCTAssertEqual(parsed.first?.keyTopics, ["AutoLog"])
    }

    func testParseInferenceResponseAcceptsRootArrayFallback() {
        let response = """
        [
          {
            "name": "Reviewing build output",
            "description": "Single-session fallback",
            "session_ids": [7],
            "key_topics": ["AutoLog"],
            "confidence": 0.6
          }
        ]
        """

        let parsed = ActivityGraphBuilder.parseInferenceResponse(
            response,
            logger: DualLogger(category: "ActivityGraphBuilderTests")
        )

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "Reviewing build output")
        XCTAssertEqual(parsed.first?.sessionIds, [7])
    }

    func testParseInferenceResponseReturnsEmptyForInvalidText() {
        let parsed = ActivityGraphBuilder.parseInferenceResponse(
            "definitely not json",
            logger: DualLogger(category: "ActivityGraphBuilderTests")
        )

        XCTAssertTrue(parsed.isEmpty)
    }
}
