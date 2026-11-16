import Testing
@testable import HermesHQNative

@Suite("Activity · delegate fallback results")
struct DelegateFallbackResultTests {
    private let args: JSONValue = ["tasks": [["goal": "Read the notes"], ["goal": "Check the links"]]]

    private func rows(_ result: JSONValue, error: Bool = false) -> [[String: JSONValue]] {
        SubagentRules.delegatePayloads(["tool_id": "mixed", "name": "delegate_task", "args": args,
                                        "result": result, "error": .bool(error)],
                                       complete: true, sourceEventType: "tool.complete")
    }

    @Test func indexedResultsKeepTheirTaskWhenReturnedOutOfOrder() {
        let result = rows(["results": [
            ["task_index": 1, "status": "timeout", "summary": "Link check timed out"],
            ["task_index": 0, "status": "completed", "summary": "Notes read"]]])
        #expect(result.map { $0["status"]?.string } == ["completed", "failed"])
        #expect(result.map { $0["summary"]?.string } == ["Notes read", "Link check timed out"])
        #expect(result[1]["output_tail"]?.array?.first?["is_error"] == true)
    }

    @Test func stringResultsPreserveFailureAndCancellation() {
        let result = rows(.string(#"{"results":[{"status":"error","summary":"Notes unavailable"},{"status":"cancelled","summary":"Stopped"}]}"#))
        #expect(result.map { $0["status"]?.string } == ["failed", "interrupted"])
        #expect(result[0]["summary"]?.string == "Notes unavailable")
        #expect(result[0]["output_tail"]?.array?.first?["is_error"] == true)
    }

    @Test func aGlobalToolErrorStillAppliesToEveryRow() {
        let result = rows(["summary": "Request failed", "results": [
            ["status": "completed", "summary": "Notes result"], ["status": "completed"]]], error: true)
        #expect(result.map { $0["status"]?.string } == ["failed", "failed"])
        #expect(result.map { $0["summary"]?.string } == ["Notes result", "Request failed"])
        #expect(result.allSatisfy { $0["output_tail"]?.array?.first?["is_error"] == true })
    }

    @Test func indexedRowsAreNotReusedAsPositionalResults() {
        let result = rows(["results": [["task_index": 1, "status": "failed", "summary": "Only links failed"]]])
        #expect(result[0]["status"]?.string == "completed")
        #expect(result[0]["summary"] == nil)
        #expect(result[1]["status"]?.string == "failed")
        #expect(result[1]["summary"]?.string == "Only links failed")
    }
}
