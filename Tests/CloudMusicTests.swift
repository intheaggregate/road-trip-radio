import XCTest
@testable import RadioEngine

final class CloudMusicTests: XCTestCase {
    func testWaitsForCompletionAndValidatesSongs() throws {
        var stream = CloudMusicStream()
        let reply = #"{"tracks":[{"title":"  A  ","artist":"Band"},{"title":"a","artist":"band"},{"title":"","artist":"Other"}]}"#
        let event = try JSONSerialization.data(withJSONObject:["type":"response.output_text.delta","delta":reply])
        XCTAssertNil(try stream.receive(String(decoding:event,as:UTF8.self)))
        XCTAssertEqual(try stream.receive(#"{"type":"response.completed","response":{"output":[]}}"#),[CloudTrack(title:"A",artist:"Band")])
    }
    func testMidstreamLimitNeverReturnsPartialMusic() {
        var stream = CloudMusicStream()
        XCTAssertThrowsError(try stream.receive(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)) { error in
            XCTAssertEqual((error as? PlanError)?.limitReached,true)
        }
        XCTAssertThrowsError(try stream.receive(#"{"type":"response.incomplete"}"#))
    }
}
