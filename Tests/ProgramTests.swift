import XCTest
@testable import RadioEngine

final class ProgramTests: XCTestCase {
    // Synthetic straight road, with locations in metres east and north of its origin.
    private func point(_ east: Double, _ north: Double = 0) -> Point {
        Point(latitude:north / 111_195,longitude:east / 111_195)
    }
    private func scene(_ east: Double, _ time: Double, north: Double = 0, speed: Double = 20,
                       heading: Double? = 90, road: Road? = nil) -> DriveContext {
        DriveContext(point:point(east,north),speed:speed,heading:heading,road:road,elapsed:time,
                     requested:.automatic,wet:false,daylight:true)
    }
    private func cue(_ id: String, _ trigger: CueTrigger, _ points: [Point], _ radius: Double,
                     style: String? = nil) -> DriveCue {
        DriveCue(id:id,trigger:trigger,label:id,reason:"Listener's choice",tracks:[CueTrack(title:id,artist:"Example")],
                 path:points,radius:radius,musicStyle:style)
    }
    private func program(_ cues: DriveCue...) -> DriveProgram { DriveProgram(version:1,name:"Example",cues:cues) }
    private func picks(_ drive: ProgramDrive, _ pack: DriveProgram, _ scene: DriveContext, _ remaining: Double = 35) -> [Moment] {
        var resolved: [String:Song] = [:]
        for track in pack.cues.flatMap(\.tracks) {
            resolved[track.key] = Song(id:track.title,title:track.title,artist:track.artist,seconds:180)
        }
        return drive.moments(in:pack,context:scene,resolved:resolved,remaining:remaining)
    }
    private func selected(_ drive: ProgramDrive, _ pack: DriveProgram, _ scene: DriveContext, mix: Mix = Mix()) -> Pick? {
        mix.choose(context:scene,current:"playing",remaining:35,moments:picks(drive,pack,scene),favorites:[])
    }

    func testDepartureAndArrivalAreDifferentNaturalBoundaries() {
        let pack = program(cue("opener",.departure,[point(0)],5000),cue("theme",.bookend,[point(0)],5000))
        var drive = ProgramDrive(), mix = Mix()
        let start = scene(0,0,speed:0)
        drive.observe(start,program:pack)
        XCTAssertEqual(selected(drive,pack,start)?.song.id,"opener")
        mix.record(selected(drive,pack,start)!)
        let theme = selected(drive,pack,start,mix:mix)!
        XCTAssertEqual(theme.song.id,"theme")
        mix.record(theme)
        XCTAssertNil(selected(drive,pack,start,mix:mix))
        drive.observe(scene(20000,1400),program:pack)
        let returning = scene(3000,6200,heading:270)
        drive.observe(returning,program:pack)
        let entries = picks(drive,pack,returning)
        XCTAssertEqual(entries.map(\.song.id),["theme"])
        XCTAssertNotEqual(entries.first?.id,theme.momentID)
        var passingThrough = returning
        passingThrough.road = Road(points:[point(3000),point(-70000)],duration:3000)
        XCTAssertTrue(picks(drive,pack,passingThrough).isEmpty)
    }

    func testFirstHighwayTransitionNeedsCityOriginAndSustainedSpeed() {
        let pack = program(cue("city",.bookend,[point(0)],4000),cue("freeway",.highwayOpening,[],0))
        var drive = ProgramDrive()
        drive.observe(scene(0,0,speed:3),program:pack)
        let fast = scene(1600,140,speed:23)
        drive.observe(fast,program:pack)
        XCTAssertFalse(picks(drive,pack,fast).contains { $0.song.id == "freeway" })
        let highway = scene(1800,150,speed:24)
        drive.observe(highway,program:pack)
        XCTAssertEqual(selected(drive,pack,highway)?.song.id,"freeway")
        XCTAssertFalse(picks(drive,pack,scene(22000,900)).contains { $0.song.id == "freeway" })
        var movingStart = ProgramDrive()
        movingStart.observe(fast,program:pack)
        movingStart.observe(highway,program:pack)
        XCTAssertFalse(picks(movingStart,pack,highway).contains { $0.song.id == "freeway" })
        var roadsideStart = ProgramDrive()
        for state in [scene(40000,0,speed:2),scene(40200,20),scene(40500,35)] { roadsideStart.observe(state,program:pack) }
        XCTAssertTrue(picks(roadsideStart,pack,scene(40500,35)).isEmpty)
    }

    func testDirectionalApproachUsesCurrentTrackBoundaryAndCanSurviveSkippedFix() {
        let pack = program(cue("crossing",.approach,[point(0),point(6000)],110))
        var drive = ProgramDrive()
        let early = scene(1800,50)
        drive.observe(early,program:pack)
        XCTAssertNil(selected(drive,pack,early))
        let near = scene(5300,225)
        drive.observe(near,program:pack)
        XCTAssertEqual(selected(drive,pack,near)?.song.id,"crossing")
        let passed = scene(6500,285)
        drive.observe(passed,program:pack)
        XCTAssertEqual(selected(drive,pack,passed)?.song.id,"crossing")
        XCTAssertNil(selected(drive,pack,scene(12000,720)))
        for invalid in [scene(5500,0,heading:270),scene(5500,0,north:420),
                        scene(5500,0,road:Road(points:[point(5500),point(5500,2000)],duration:100))] {
            var otherDrive = ProgramDrive()
            otherDrive.observe(invalid,program:pack)
            XCTAssertNil(selected(otherDrive,pack,invalid))
        }
    }

    func testApproachCanInferDirectionFromPositionsWithoutCompass() {
        let pack = program(cue("bridge",.approach,[point(0),point(2500)],100))
        var drive = ProgramDrive()
        drive.observe(scene(1500,0,heading:nil),program:pack)
        let nearer = scene(1900,20,heading:nil)
        drive.observe(nearer,program:pack)
        XCTAssertEqual(selected(drive,pack,nearer)?.song.id,"bridge")
    }

    func testBypassAndMusicStyleUseActualCorridorInBothDirections() {
        let pack = program(cue("village",.nearby,[point(4000,2000)],800),
                           cue("region",.region,[point(0),point(10000)],600,style:"Instrumental guitar"))
        for heading in [90.0,270.0] {
            var drive = ProgramDrive()
            let interstate = scene(4000,10,heading:heading)
            drive.observe(interstate,program:pack)
            XCTAssertEqual(picks(drive,pack,interstate).map(\.song.id),["region"])
            XCTAssertEqual(drive.musicStyle(in:pack,context:interstate),"Instrumental guitar")
            let town = scene(4000,200,north:1800,heading:heading)
            drive.observe(town,program:pack)
            XCTAssertEqual(selected(drive,pack,town)?.song.id,"village")
            XCTAssertNil(drive.musicStyle(in:pack,context:town))
            XCTAssertTrue(drive.preload(in:pack,context:town).contains { $0.title == "region" })
        }
    }

    func testLongStretchCountsDrivingInThatRegionAndNeverRequiresAComputer() {
        let pack = program(cue("lift",.longStretch,[point(0),point(80000)],1200,style:"Driving percussion"))
        var drive = ProgramDrive()
        let entering = scene(0,7000)
        drive.observe(entering,program:pack)
        XCTAssertNil(selected(drive,pack,entering))
        let stopped = scene(0,10000,speed:0)
        drive.observe(stopped,program:pack)
        XCTAssertNil(drive.musicStyle(in:pack,context:stopped))
        for minute in 1...10 {
            let state = scene(Double(minute) * 1200,10000 + Double(minute) * 60)
            drive.observe(state,program:pack)
            XCTAssertEqual(selected(drive,pack,state)?.song.id,minute == 10 ? "lift" : nil)
        }
        XCTAssertEqual(drive.musicStyle(in:pack,context:scene(12000,10600)),"Driving percussion")
        let detour = scene(15000,10800,north:9000)
        drive.observe(detour,program:pack)
        XCTAssertNil(drive.musicStyle(in:pack,context:detour))
    }

    func testRegionalChoicesRespectCadenceAndListenerPinsWin() {
        let pack = program(cue("regional",.region,[point(100)],200),cue("stop",.nearby,[point(100)],200))
        let state = scene(100,0)
        var drive = ProgramDrive(), mix = Mix()
        drive.observe(state,program:pack)
        let moments = picks(drive,pack,state)
        let pin = Moment(id:"pin",point:point(100),song:Song(id:"pin",title:"Pin",artist:"Example",seconds:230),
                         reason:"Personal pin",source:nil,personal:true)
        let favorite = Favorite(song:Song(id:"rotation",title:"Rotation",artist:"Example",seconds:200),energy:.automatic)
        let pinned = mix.choose(context:state,current:"now",remaining:30,moments:moments+[pin],favorites:[favorite])!
        XCTAssertEqual(pinned.song.id,"pin")
        mix.record(pinned)
        let landmark = mix.choose(context:state,current:"now",remaining:30,moments:moments,favorites:[favorite])!
        XCTAssertEqual(landmark.song.id,"stop")
        mix.record(landmark)
        XCTAssertEqual(mix.choose(context:state,current:"now",remaining:30,moments:moments,favorites:[favorite])?.song.id,"rotation")
    }

    func testProgramValidationRejectsBrokenGeometryAndDuplicateIDs() throws {
        let site = cue("site",.nearby,[point(1)],200)
        let entry = cue("entry",.highwayOpening,[],0)
        XCTAssertNoThrow(try program(site,entry).validated())
        XCTAssertThrowsError(try program(site,site).validated())
        XCTAssertThrowsError(try program(cue("bridge",.approach,[point(0)],100)).validated())
        XCTAssertThrowsError(try program(cue("zero",.nearby,[point(0)],0)).validated())
        XCTAssertThrowsError(try program().validated())
    }
}
