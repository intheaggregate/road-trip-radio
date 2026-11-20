import XCTest
@testable import RadioEngine

final class RadioTests: XCTestCase {
    let origin = Point(latitude:35,longitude:-90)
    func north(_ metres: Double) -> Point { Point(latitude:35 + metres / 111_195,longitude:-90) }
    func song(_ id: String, _ duration: Double = 200) -> Song { Song(id:id,title:id,artist:"Artist",seconds:duration) }
    func cue(_ id: String, _ metres: Double, user: Bool = true) -> Moment {
        Moment(id:id,point:north(metres),song:song(id),reason:"A local connection",source:nil,personal:user)
    }
    func context(planned: Bool = false) -> DriveContext {
        DriveContext(point:origin,speed:20,heading:0,road:planned ? Road(points:[origin,north(15000)],duration:750) : nil,
                     elapsed:240,requested:.automatic,wet:false,daylight:true)
    }
    func testPersonalPinWinsAtNaturalBoundaryAndFiresOnce() {
        var mix = Mix()
        let moments = [cue("local",0,user:false),cue("mine",800)]
        let pick = mix.choose(context:context(),current:"now",remaining:40,moments:moments,favorites:[])!
        XCTAssertEqual(pick.song.id,"mine")
        mix.record(pick)
        XCTAssertNil(mix.choose(context:context(),current:"other",remaining:40,moments:[moments[1]],favorites:[]))
    }
    func testApproachUsesLengthOfFiller() {
        let favorites = [Favorite(song:song("too-long",520),energy:.cruise),Favorite(song:song("fits",195),energy:.cruise)]
        let pick = Mix().choose(context:context(),current:"now",remaining:45,moments:[cue("bridge",4800)],favorites:favorites)
        XCTAssertEqual(pick?.song.id,"fits")
    }
    func testDetourAndPassedPlace() {
        var drive = context(planned:true)
        XCTAssertNotNil(drive.eta(to:north(600)))
        drive.point = north(2000)
        XCTAssertNil(drive.eta(to:north(500)))
        drive.point.longitude += 0.03; drive.heading = 90
        XCTAssertNil(drive.eta(to:north(500)))
    }
    func testRoadWithoutHeadingOnlyPlaysAnImmediatePin() {
        var drive = context(); drive.heading = nil; drive.speed = 0
        XCTAssertNil(drive.eta(to:north(800)))
        XCTAssertEqual(drive.eta(to:north(80)),0)
    }
    func testRainNightAndUserOverride() {
        var drive = context()
        drive.wet = true
        let list = [Favorite(song:song("fast"),energy:.upbeat), Favorite(song:song("quiet"),energy:.mellow)]
        XCTAssertEqual(Mix().choose(context:drive,current:"now",remaining:30,moments:[],favorites:list)?.song.id,"quiet")
        drive.wet = false; drive.daylight = false; XCTAssertEqual(drive.energy,.mellow)
        drive.requested = .upbeat
        XCTAssertEqual(Mix().choose(context:drive,current:"now",remaining:30,moments:[],favorites:list)?.song.id,"fast")
    }
    func testDiscoveryCadenceAndTripLength() {
        var mix = Mix()
        let f = Favorite(song:song("fav"),energy:.automatic)
        let first = mix.choose(context:context(),current:"now",remaining:30,moments:[cue("one",0,user:false)],favorites:[f])!
        mix.record(first)
        for id in ["a","b"] {
            let pick = mix.choose(context:context(),current:"now",remaining:30,moments:[cue("two",0,user:false)],favorites:[Favorite(song:song(id),energy:.automatic)])!
            XCTAssertNil(pick.momentID); mix.record(pick)
        }
        XCTAssertEqual(mix.choose(context:context(),current:"now",remaining:30,moments:[cue("two",0,user:false)],favorites:[f])?.momentID,"two")
        var drive = context(); drive.elapsed = 5500; XCTAssertEqual(drive.energy,.upbeat)
    }
    func testLostAcknowledgementAndManualQueue() {
        var gate = QueueGate()
        let now = Date(), pick = Pick(song:song("pin"),reason:"A bridge")
        XCTAssertFalse(gate.ready(current:"a",remaining:120))
        gate.reserve(pick,from:"a",now:now)
        XCTAssertFalse(gate.ready(current:"a",remaining:20))
        gate.observe(current:"b",queue:Set(["pin"]),now:now.addingTimeInterval(50))
        XCTAssertFalse(gate.ready(current:"b",remaining:30))
        gate.observe(current:"pin",queue:nil,now:now.addingTimeInterval(150))
        XCTAssertTrue(gate.ready(current:"pin",remaining:35))
    }
    func testLostWriteSkipsMissedCueOnReconnect() {
        var gate = QueueGate()
        let now = Date()
        gate.reserve(Pick(song:song("old"),reason:"Old town"),from:"a",now:now)
        gate.observe(current:"b",queue:nil,now:now.addingTimeInterval(120))
        XCTAssertFalse(gate.ready(current:"b",remaining:30))
        gate.observe(current:"b",queue:[],now:now.addingTimeInterval(121))
        XCTAssertTrue(gate.ready(current:"b",remaining:30))
    }
    func testExplicitFailureCanRetryAndInvalidResearchIsRejected() {
        var gate = QueueGate()
        gate.reserve(Pick(song:song("pin"),reason:"Pin"),from:"a",now:Date()); gate.rejected()
        XCTAssertTrue(gate.ready(current:"a",remaining:24))
        let story = Story(place:"Town",latitude:300,longitude:0,title:"A",artist:"B",reason:"C",source:"file:///x")
        XCTAssertThrowsError(try ResearchPack(version:1,name:"Trip",stories:[story]).validated())
    }
}
