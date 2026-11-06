import Foundation
import XCTest
@testable import Densoso

final class AgentToolOutputLimiterTests: XCTestCase {
    func testOutputWithinUTF8BudgetIsPreserved() {
        let output = #"{"status":"available"}"#
        XCTAssertEqual(AgentToolOutputLimiter.limit(output), output)
    }

    func testOutputAtUTF8BudgetIsPreserved() {
        let output = outputAtUTF8Budget()

        XCTAssertEqual(output.utf8.count, AgentToolOutputLimiter.maximumUTF8Bytes)
        XCTAssertEqual(AgentToolOutputLimiter.limit(output), output)
    }

    func testOversizedOutputReturnsValidStructuredJSONInsteadOfCharacterTruncation() throws {
        let output = outputAtUTF8Budget() + "x"
        XCTAssertEqual(output.utf8.count, AgentToolOutputLimiter.maximumUTF8Bytes + 1)

        let limitedOutput = AgentToolOutputLimiter.limit(output)
        XCTAssertLessThanOrEqual(limitedOutput.utf8.count, AgentToolOutputLimiter.maximumUTF8Bytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(limitedOutput.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "tool_output_limit_exceeded")
        XCTAssertEqual(error["truncated"] as? Bool, true)
        XCTAssertNotNil(error["message"] as? String)
    }

    private func outputAtUTF8Budget() -> String {
        let maximumBytes = AgentToolOutputLimiter.maximumUTF8Bytes
        let multibyteCharacterCount = (maximumBytes - 1) / 3
        let remainingASCIIBytes = maximumBytes - (multibyteCharacterCount * 3)
        return String(repeating: "餐", count: multibyteCharacterCount)
            + String(repeating: "x", count: remainingASCIIBytes)
    }
}
