import XCTest
@testable import RadioEngine

final class ListeningStretchTests: XCTestCase {
    private func route(km: Double = 110, minutes: Double = 95) -> Road {
        Road(points:[Point(latitude:0,longitude:0),Point(latitude:0,longitude:km/111.195)],duration:minutes*60)
    }
    private func samples(_ road: Road, height: (Int)->Double) -> [ElevationSample] {
        (0..<26).map { i in ElevationSample(distance:road.length*(0.06+0.88*Double(i)/25),height:height(i)) }
    }
    func testSustainedElevationChangeCreatesAnInteriorChapter() throws {
        let road = route()
        let data = samples(road) { $0 < 10 ? 140 : 140 + Double($0-9)*70 }
        XCTAssertEqual(ListeningStretch.chapters(for:road).count,1)
        let chapters = ListeningStretch.chapters(for:road,samples:data)
        XCTAssertEqual(chapters.count,2)
        let first = try XCTUnwrap(chapters.first), last = try XCTUnwrap(chapters.last)
        XCTAssertEqual(first.terrain,"level terrain")
        XCTAssertEqual(last.terrain,"changing elevation")
        XCTAssertEqual(first.upper,last.lower,accuracy:0.001)
        XCTAssertTrue((0.30...0.50).contains(first.upper/road.length))
    }
    func testFlatHighPlateauAndOneBadPixelDoNotInventMountains() {
        let road = route()
        let flat = samples(road) { $0 == 12 ? 2900 : 2200 }
        let result = ListeningStretch.chapters(for:road,samples:flat)
        XCTAssertEqual(result.map(\.terrain),["level terrain"])
        let undulating = samples(road) { $0.isMultiple(of:2) ? 100 : 122 }
        XCTAssertEqual(ListeningStretch.chapters(for:road,samples:undulating).map(\.terrain),["rolling terrain"])
    }
    func testMissingCoverageFallsBackToBoundedDurationChapters() {
        let road = route(km:700,minutes:750)
        let expected = ListeningStretch.chapters(for:road)
        XCTAssertEqual(expected.count,6)
        XCTAssertTrue(expected.allSatisfy { $0.terrain == nil && $0.minutes > 0 })
        XCTAssertEqual(ListeningStretch.chapters(for:road,samples:samples(road) { $0 == 4 ? .nan : 20 }),expected)
        XCTAssertEqual(ListeningStretch.chapters(for:road,samples:samples(road) { _ in 0 }.reversed()),expected)
        XCTAssertTrue(ListeningStretch.chapters(for:route(km:1,minutes:5)).isEmpty)
    }
    func testSingleRequestUsesCoarseInteriorPositionsAndHasABoundedSize() {
        let road = route(km:1800,minutes:1220)
        let probes = ListeningStretch.probes(for:road)
        XCTAssertEqual(probes.count,72)
        for probe in probes {
            XCTAssertGreaterThan(probe.distance,0)
            XCTAssertLessThan(probe.distance,road.length)
            XCTAssertEqual(probe.point.longitude*100,(probe.point.longitude*100).rounded(),accuracy:0.00001)
            XCTAssertGreaterThan(probe.point.distance(to:road.points.first!),1000)
            XCTAssertGreaterThan(probe.point.distance(to:road.points.last!),1000)
        }
        XCTAssertTrue(ListeningStretch.probes(for:route(km:10,minutes:10)).isEmpty)
    }
}
