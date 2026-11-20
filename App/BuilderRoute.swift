import CoreLocation
import MapKit

/// The model sees chapter labels. All playback boundaries come from the selected driving route.
struct BuilderRoute {
    let name: String
    let road: Road
    let line: MKPolyline
    let slots: [SoundtrackSlot]

    private struct NamedCrossing {
        let name: String
        let road: Road
    }
    /// Only investigate explicit proper names attached to mapped driving instructions.
    private static let crossingName = try! NSRegularExpression(pattern:
        #"\b(?:\p{Lu}[\p{L}\p{M}\d’.'-]*\s+(?:(?:of|the|de|du|and)\s+)?){1,6}(?:Bridge|Tunnel|Viaduct|Causeway)\b"#)

    private static func namedCrossings(_ steps: [MKRoute.Step]) -> [NamedCrossing] {
        var candidates: [NamedCrossing] = []
        for step in steps where step.polyline.pointCount >= 2 {
            let words = step.instructions
            guard let match = crossingName.firstMatch(in:words,range:NSRange(words.startIndex...,in:words)),
                  let range = Range(match.range,in:words) else { continue }
            let name = String(words[range])
            guard !candidates.contains(where:{ $0.name == name }) else { continue }
            let points = step.polyline.points()
            let path = (0..<step.polyline.pointCount).map { Point(points[$0].coordinate) }
            candidates.append(NamedCrossing(name:name,road:Road(points:path,duration:0)))
            if candidates.count == 4 { break }
        }
        return candidates
    }
    private static func findCrossing(_ crossing: NamedCrossing, on road: Road) async -> Point? {
        guard let near = crossing.road.point(atDistance:crossing.road.length / 2) else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = crossing.name
        request.region = MKCoordinateRegion(center:near.coordinate,latitudinalMeters:65000,longitudinalMeters:65000)
        let search = MKLocalSearch(request:request)
        return await withTaskGroup(of:Point?.self) { group in
            group.addTask {
                let response = try? await withTaskCancellationHandler {
                    try await search.start()
                } onCancel: { search.cancel() }
                for item in response?.mapItems ?? [] {
                    guard item.name?.compare(crossing.name,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame else { continue }
                    let p = Point(item.placemark.coordinate), whereOnRoad = road.projection(p)
                    if whereOnRoad.away <= 250 && whereOnRoad.along > 150 && crossing.road.projection(p).away <= 325 { return p }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(nanoseconds:4_000_000_000); return nil }
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    private static func label(_ item: MKMapItem) -> String {
        item.placemark.locality ?? item.placemark.subAdministrativeArea ?? item.placemark.administrativeArea ?? "Trip endpoint"
    }

    static func make(from start: MKMapItem, via: MKMapItem?, to finish: MKMapItem) async throws -> BuilderRoute {
        var points = [Point]()
        var roads = [(end: Double, name: String)]()
        var crossings: [NamedCrossing] = []
        var distance = 0.0, duration = 0.0
        let stops = [start] + [via].compactMap { $0 } + [finish]
        for (from, to) in zip(stops,stops.dropFirst()) {
            try Task.checkCancellation()
            let request = MKDirections.Request()
            request.source = from; request.destination = to; request.transportType = .automobile
            let directions = MKDirections(request:request)
            let response = try await withTaskCancellationHandler {
                try await directions.calculate()
            } onCancel: { directions.cancel() }
            guard let leg = response.routes.first, leg.polyline.pointCount >= 2 else {
                throw RadioError("Apple Maps could not find a driving route between these stops.")
            }
            let raw = leg.polyline.points()
            let stride = max(1,Int(ceil(Double(leg.polyline.pointCount) / 9000)))
            var path = Swift.stride(from:0,to:leg.polyline.pointCount,by:stride).map { Point(raw[$0].coordinate) }
            let end = Point(raw[leg.polyline.pointCount-1].coordinate)
            if path.last != end { path.append(end) }
            distance += Road(points:path,duration:0).length
            roads.append((distance,leg.name))
            crossings += namedCrossings(leg.steps)
            duration += leg.expectedTravelTime
            if points.last == path.first { points.append(contentsOf:path.dropFirst()) } else { points += path }
        }
        let road = Road(points:points,duration:duration)
        guard road.length >= 200, let begin = points.first, let end = points.last else {
            throw RadioError("Pick two places far enough apart for a driving route.")
        }
        let from = label(start), to = label(finish)
        let name = "\(from) → \(to)"
        let cityRadius = min(5500,max(160,road.length * 0.12))
        var slots = [SoundtrackSlot(id:"departure",label:"Leaving \(from)",trigger:.departure,path:[begin],radius:cityRadius)]
        if duration >= 1500 {
            slots.append(SoundtrackSlot(id:"highway",label:"First highway stretch out of \(from)",trigger:.highwayOpening,path:[],radius:0))
        }
        let chapters = await RouteTerrain.chapters(for:road)
        for (i, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            let lower = chapter.lower, upper = chapter.upper
            let middle = (lower + upper) / 2
            guard let p = road.point(atDistance:middle) else { continue }
            let town = try? await Town.find(CLLocation(latitude:p.latitude,longitude:p.longitude))
            let roadName = roads.first { $0.end >= middle }?.name ?? ""
            let area = town.map { [$0.name,$0.region].filter { !$0.isEmpty }.joined(separator:", ") }
            let minutes = chapter.minutes
            let section = area.map { "Near " + String($0.prefix(48)) }
            let roadLabel = roadName.isEmpty ? nil : String(roadName.prefix(36))
            let label = [section,roadLabel,chapter.terrain,"\(max(1,minutes)) min stretch"].compactMap { $0 }.joined(separator:" · ")
            let path = road.sampled(from:lower,to:upper)
            let makesLongStretch = minutes >= 45 && i > 0
            slots.append(SoundtrackSlot(id:"stretch-\(i+1)",label:label,trigger:makesLongStretch ? .longStretch : .region,
                                       path:path,radius:min(1800,max(400,(upper-lower)/130))))
        }
        if let via {
            let name = via.placemark.locality ?? via.placemark.subAdministrativeArea ?? "Planned stop"
            slots.append(SoundtrackSlot(id:"via",label:"Passing \(name)",trigger:.nearby,
                                       path:[Point(via.placemark.coordinate)],radius:850))
        }
        var features: [Point] = []
        for crossing in crossings.prefix(4) where features.count < 2 {
            try Task.checkCancellation()
            guard let p = await findCrossing(crossing,on:road), !features.contains(where:{ $0.distance(to:p) < 1000 }) else { continue }
            let end = road.projection(p).along
            slots.append(SoundtrackSlot(id:"crossing-\(features.count+1)",label:"Approaching " + crossing.name,
                         trigger:.approach,path:road.sampled(from:max(0,end-4200),to:end),radius:240))
            features.append(p)
        }
        slots.append(SoundtrackSlot(id:"arrival",label:"Arriving in \(to)",trigger:.arrival,path:[end],radius:cityRadius))
        let coordinates = points.map(\.coordinate)
        return BuilderRoute(name:name,road:road,line:MKPolyline(coordinates:coordinates,count:coordinates.count),slots:slots)
    }

    func landmark(_ point: Point, name: String) -> SoundtrackSlot {
        let here = road.projection(point)
        // A directional cue must terminate on the driven road. A side trip remains a true proximity cue.
        let nearRoad = here.away <= 325 && here.along >= 150
        let path = nearRoad ? road.sampled(from:max(0,here.along - 4200),to:here.along) : [point]
        return SoundtrackSlot(id:"place-" + UUID().uuidString.lowercased(),label:String(name.prefix(150)),
                              trigger:nearRoad ? .approach : .nearby,path:path,radius:nearRoad ? 240 : 800)
    }

    func position(_ slot: SoundtrackSlot) -> Double {
        switch slot.trigger {
        case .departure: return -2
        case .highwayOpening: return -1
        case .arrival: return road.length + 1
        default:
            guard !slot.path.isEmpty else { return 0 }
            let point = slot.trigger == .approach ? slot.path.last! : slot.path[slot.path.count / 2]
            return road.projection(point).along
        }
    }
}

private extension Road {
    func sampled(from lower: Double, to upper: Double) -> [Point] {
        let pieces = min(140,max(2,Int(ceil((upper - lower)/40))))
        return (0...pieces).compactMap { point(atDistance:lower + (upper-lower) * Double($0) / Double(pieces)) }
    }
}
