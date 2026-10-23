import Foundation
import XCTest
@testable import Densoso

final class AgentToolOutputLimiterTests: XCTestCase {
    func testOutputWithinUTF8BudgetIsPreserved() {
        let output = #"{"status":"available"}"#
        XCTAssertEqual(AgentToolOutputLimiter.limit(output), output)
    }

    func testOversizedOutputReturnsValidStructuredJSONInsteadOfCharacterTruncation() throws {
        let output = AgentToolOutputLimiter.limit(String(repeating: "餐", count: 4_100))

        XCTAssertLessThanOrEqual(output.utf8.count, AgentToolOutputLimiter.maximumUTF8Bytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "tool_output_limit_exceeded")
        XCTAssertEqual(error["truncated"] as? Bool, true)
        XCTAssertNotNil(error["message"] as? String)
    }
}
