import Foundation
import XCTest
@testable import RadioEngine

final class SoundtrackGeneratorTests: XCTestCase {
    private let jetty = Point(latitude:10.12345,longitude:50.98765)
    private let pass = Point(latitude:10.45,longitude:50.4)
    private let headland = Point(latitude:10.75,longitude:50.1)

    private func track(_ title: String, _ artist: String = "Example Band") -> CueTrack {
        CueTrack(title:title,artist:artist)
    }
    private func route() -> [SoundtrackSlot] {
        [SoundtrackSlot(id:"a",label:"Jetty",trigger:.departure,path:[jetty],radius:4000),
         SoundtrackSlot(id:"b",label:"Ridge road",trigger:.region,path:[pass,headland],radius:900,
                        instruction:"Sparse strings, then bring in the drums."),
         SoundtrackSlot(id:"c",label:"Headland",trigger:.arrival,path:[headland],radius:4000)]
    }
    private func evidence(_ point: Point) -> Story {
        Story(place:"Practice Hall",latitude:point.latitude,longitude:point.longitude,title:"Session One",
              artist:"Example Quartet",reason:"The public session log credits this recording to the hall.",
              source:"https://example.org/archive/session")
    }

    func testPrivateRitualStaysLocalAndEmptyDraftStillPlaysIt() throws {
        var slots = route()
        slots[0].lockedTrack = track("Private departure")
        let input = try SoundtrackGenerator.prompt(slots:slots,taste:"Quiet guitars",rejected:[track("Private departure")])
        XCTAssertFalse(input.contains("Private departure"))
        XCTAssertFalse(input.contains("Jetty"))
        XCTAssertFalse(input.contains("10.45"))
        XCTAssertFalse(input.contains("radius"))
        XCTAssertTrue(input.contains("Sparse strings"))
        let plan = try SoundtrackGenerator.program(name:"Harbor road",slots:slots,drafts:[],
                                                   rejected:[track("Private departure")])
        XCTAssertEqual(plan.cues.map(\.id),["a"])
        XCTAssertEqual(plan.cues[0].tracks,[track("Private departure")])
        XCTAssertEqual(plan.origin,jetty)
    }

    func testAnotherRouteUsesItsOwnGeometryAndRejectsInventedChapters() throws {
        let desert = [SoundtrackSlot(id:"driver-start",label:"Mesa",trigger:.departure,
                                     path:[Point(latitude:-23,longitude:135)],radius:1100),
                      SoundtrackSlot(id:"middle",label:"Dry riverbed",trigger:.longStretch,
                                     path:[Point(latitude:-23.1,longitude:135.2),Point(latitude:-23.3,longitude:135.3)],
                                     radius:1650)]
        let json = """
        {"cues":[{"slotID":"middle","path":[{"latitude":0,"longitude":0}],"trigger":"arrival",
          "tracks":[{"title":"Far Along","artist":"Example Pair"}],"style":"muted drums",
          "reason":"They recorded at a landmark beside this highway."},
          {"slotID":"made-up-town","tracks":[{"title":"Ignored","artist":"Example"}]}]}
        """
        let drafts = try SoundtrackGenerator.decode(json)
        let result = try SoundtrackGenerator.program(name:"Interior road",slots:desert,drafts:drafts)
        XCTAssertEqual(result.cues.map(\.id),["middle"])
        let cue = try XCTUnwrap(result.cues.first)
        XCTAssertEqual(cue.path,desert[1].path)
        XCTAssertEqual(cue.trigger,.longStretch)
        XCTAssertEqual(cue.radius,1650)
        XCTAssertNil(cue.source)
        XCTAssertFalse(cue.reason.contains("recorded"))
        XCTAssertEqual(cue.musicStyle,"muted drums")
        XCTAssertEqual(result.origin,desert[0].path.first)
    }

    func testOpenRegionsGetAlternativesAndReserveLockedRecordings() throws {
        var slots = route()
        slots[2].lockedTrack = track("The ending")
        let drafts = [DraftCue(slotID:"a",tracks:[track("Opening"),track("Unused alternative")],reason:"opening"),
                      DraftCue(slotID:"b",tracks:[track("opening"),track("THE ENDING"),track("Skip me"),
                                                 track("Rhythm One"),track(" rhythm   one "),track("Rhythm Two")],style:"guitar-driven"),
                      DraftCue(slotID:"c",tracks:[track("Uninvited replacement")])]
        let result = try SoundtrackGenerator.program(name:"Headland road",slots:slots,drafts:drafts,rejected:[track("Skip me")])
        XCTAssertEqual(result.cues.map(\.tracks),[[track("Opening")],[track("Rhythm One"),track("Rhythm Two")],[track("The ending")]])
        XCTAssertEqual(result.cues[0].reason,"An opening song to set the tone.")
        XCTAssertEqual(result.cues[1].musicStyle,"guitar-driven")
        XCTAssertNil(result.cues[2].musicStyle)
    }

    func testIndependentReferenceMustMatchPlaceAndRecording() throws {
        let known = evidence(pass)
        let actual = track(known.title,known.artist)
        var slot = SoundtrackSlot(id:"hall",label:"Practice hall",trigger:.nearby,path:[pass],radius:350,reference:known)
        let draft = DraftCue(slotID:"hall",tracks:[track("Another recording"),actual],reason:"fabricated local fact")
        let result = try SoundtrackGenerator.program(name:"Ridge",slots:[slot],drafts:[draft])
        XCTAssertEqual(result.cues[0].tracks,[actual])
        XCTAssertEqual(result.cues[0].source,known.source)
        XCTAssertEqual(result.cues[0].reason,known.reason)
        XCTAssertThrowsError(try SoundtrackGenerator.program(name:"Ridge",slots:[slot],drafts:[draft],rejected:[actual]))

        slot.lockedTrack = track("My choice")
        let requested = try SoundtrackGenerator.program(name:"Ridge",slots:[slot],drafts:[draft])
        XCTAssertEqual(requested.cues[0].tracks,[track("My choice")])
        XCTAssertNil(requested.cues[0].source)
        slot.lockedTrack = nil
        slot.path = [jetty]
        XCTAssertFalse(try SoundtrackGenerator.prompt(slots:[slot],taste:"brass",rejected:[]).contains(known.artist))
        XCTAssertTrue(SoundtrackGenerator.tracks(for:slot,draft:draft).isEmpty)
    }

    func testRerollUsesOnlyTargetAndBoundsRejections() throws {
        let target = route()[1]
        let prior = (0..<75).map { track("Discarded \($0)") }
        let text = try SoundtrackGenerator.prompt(slots:[target],taste:"metal and folk",rejected:prior)
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
        let chapters = try XCTUnwrap(data["chapters"] as? [[String:Any]])
        XCTAssertEqual(chapters.map { $0["slotID"] as? String },["b"])
        XCTAssertEqual((data["rejected"] as? [[String:String]])?.count,32)
        XCTAssertFalse(text.contains("Jetty"))
        XCTAssertFalse(text.contains("Discarded 0"))
        XCTAssertTrue(text.contains("Discarded 74"))
        XCTAssertThrowsError(try SoundtrackGenerator.prompt(slots:[target,target],taste:"",rejected:[]))
        XCTAssertThrowsError(try SoundtrackGenerator.decode("{\"cues\":[{\"slotID\":\"b\",\"tracks\":[]},{\"slotID\":\"b\",\"tracks\":[]}]}"))
    }

    func testSavedRetuneChangesOnlyRegionalPoolAndRejectsStaleWrites() throws {
        var slots = route()
        slots[0].lockedTrack = track("Opening")
        slots[2].lockedTrack = track("Ending")
        let plan = try SoundtrackGenerator.program(name:"Harbor road",slots:slots,
                                                   drafts:[DraftCue(slotID:"b",tracks:[track("Old selection")])])
        let original = plan.cues[1]
        let changed = try SoundtrackGenerator.replacingChapter(in:plan,original:original,
                         tracks:[track("Ending"),track("New selection"),track("NEW selection")],
                         reason:"A slower transition.",style:"low acoustic strings")
        XCTAssertEqual(changed.cues[0],plan.cues[0])
        XCTAssertEqual(changed.cues[2],plan.cues[2])
        XCTAssertEqual(changed.origin,plan.origin)
        XCTAssertEqual(changed.cues[1].path,original.path)
        XCTAssertEqual(changed.cues[1].tracks,[track("New selection")])
        XCTAssertNil(changed.cues[1].source)
        XCTAssertThrowsError(try SoundtrackGenerator.replacingChapter(in:changed,original:original,tracks:[track("Late")],reason:"Late reply",style:nil))

        slots[1].lockedTrack = track("User's exact song")
        let locked = try SoundtrackGenerator.program(name:"Harbor road",slots:slots,drafts:[])
        XCTAssertEqual(locked.cues[1].locked,true)
        XCTAssertThrowsError(try SoundtrackGenerator.replacingChapter(in:locked,original:locked.cues[1],tracks:[track("Other")],reason:"Unwanted",style:nil))
    }
}
