import XCTest
@testable import RadioEngine

final class CloudMusicTests: XCTestCase {
    func testWaitsForCompletionAndValidatesSongs() throws {
        var stream = CloudTextStream()
        let reply = #"{"tracks":[{"title":"  A  ","artist":"Band"},{"title":"a","artist":"band"},{"title":"","artist":"Other"}]}"#
        let event = try JSONSerialization.data(withJSONObject:["type":"response.output_text.delta","delta":reply])
        XCTAssertNil(try stream.receive(String(decoding:event,as:UTF8.self)))
        let completed = try XCTUnwrap(stream.receive(#"{"type":"response.completed","response":{"output":[]}}"#))
        XCTAssertEqual(try CloudTrack.decodeSuggestions(completed),[CloudTrack(title:"A",artist:"Band")])
    }
    func testMidstreamLimitNeverReturnsPartialMusic() {
        var stream = CloudTextStream()
        XCTAssertThrowsError(try stream.receive(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)) { error in
            XCTAssertEqual((error as? PlanError)?.limitReached,true)
        }
        XCTAssertThrowsError(try stream.receive(#"{"type":"response.incomplete"}"#))
    }

    func testCompletedPlanningTextWinsOverPreliminaryDeltas() throws {
        var stream = CloudTextStream()
        XCTAssertNil(try stream.receive(#"{"type":"response.output_text.delta","delta":"unfinished draft"}"#))
        let final = #"{"cues":[{"slotID":"river","tracks":[{"title":"Song","artist":"Artist"}]}]}"#
        let block = ["type":"output_text","text":final]
        let message: [String:Any] = ["type":"message","content":[block]]
        let event: [String:Any] = ["type":"response.completed","response":["status":"completed","output":[message]]]
        let data = try JSONSerialization.data(withJSONObject:event)
        XCTAssertEqual(try stream.receive(String(decoding:data,as:UTF8.self)),final)
    }

    func testRefusalAndPrematureEndDiscardDraft() throws {
        var stream = CloudTextStream()
        XCTAssertNil(try stream.receive(#"{"type":"response.output_text.delta","delta":"partial"}"#))
        XCTAssertThrowsError(try stream.receive("[DONE]"))
        XCTAssertThrowsError(try stream.receive(#"{"type":"response.completed","response":{"status":"incomplete"}}"#))
        XCTAssertThrowsError(try stream.receive(#"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"refusal","refusal":"Declined"}]}]}}"#))
    }
}
