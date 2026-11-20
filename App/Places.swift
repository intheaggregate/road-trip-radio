import CoreLocation
import Foundation
import MapKit

extension Point {
    init(_ coordinate: CLLocationCoordinate2D) { self.init(latitude:coordinate.latitude, longitude:coordinate.longitude) }
    var coordinate: CLLocationCoordinate2D { .init(latitude:latitude, longitude:longitude) }
}

struct RoutePlan {
    let name: String
    let destination: MKMapItem
    let line: MKPolyline
    let road: Road
    static func make(from location: CLLocation, to destination: MKMapItem) async throws -> RoutePlan {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate:location.coordinate))
        req.destination = destination; req.transportType = .automobile
        let response = try await MKDirections(request:req).calculate()
        guard let route = response.routes.first else { throw RadioError("Apple Maps could not find a driving route.") }
        let line = route.polyline, raw = line.points()
        var points: [Point] = []
        let stride = max(1, Int(ceil(Double(line.pointCount) / 1400)))
        for index in Swift.stride(from:0, to:line.pointCount, by:stride) { points.append(Point(raw[index].coordinate)) }
        if line.pointCount > 0 { points.append(Point(raw[line.pointCount - 1].coordinate)) }
        return RoutePlan(name:destination.name ?? "Destination", destination:destination, line:line,
                         road:Road(points:points, duration:route.expectedTravelTime))
    }
}
func findPlaces(_ text: String, near: Point?) async throws -> [MKMapItem] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = text
    if let near { request.region = MKCoordinateRegion(center:near.coordinate, latitudinalMeters:120_000, longitudinalMeters:120_000) }
    return try await MKLocalSearch(request:request).start().mapItems
}

final class TripGPS: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var onFix: ((CLLocation)->Void)?
    var onIssue: ((String)->Void)?
    private(set) var active = false
    private var requestedFix = false
    override init() {
        super.init()
        manager.delegate = self; manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest; manager.distanceFilter = 40
        manager.pausesLocationUpdatesAutomatically = false
    }
    func request() {
        requestedFix = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: onIssue?("Enable Location While Using in iPhone Settings to follow the drive.")
        }
    }
    func start() {
        active = true
        manager.allowsBackgroundLocationUpdates = true; manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }
    func stop() { active = false; manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: if active { manager.startUpdatingLocation() } else if requestedFix { manager.requestLocation() }
        case .restricted, .denied: stop(); onIssue?("Location access is off. Enable While Using in iPhone Settings.")
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 650, abs(fix.timestamp.timeIntervalSinceNow) < 90 else { return }
        requestedFix = false; onFix?(fix)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code != .locationUnknown { onIssue?(error.localizedDescription) }
    }
}

struct Conditions {
    var wet: Bool
    var day: Bool
    var label: String
    static func load(_ point: Point) async throws -> Conditions {
        let url = try Network.url("https://api.open-meteo.com/v1/forecast",[
            "latitude":String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),point.latitude),
            "longitude":String(format:"%.2f",locale:Locale(identifier:"en_US_POSIX"),point.longitude),
            "current":"weather_code,is_day","timezone":"auto"
        ])
        let json = try await Network.json(URLRequest(url:url,timeoutInterval:8))
        guard let current = json["current"] as? Object, let code = current["weather_code"] as? Int, let day = current["is_day"] as? Int else { throw RadioError("Weather is unavailable.") }
        let wet = (51...99).contains(code)
        let label: String
        switch code { case 0: label = "Clear"; case 1...3: label = "Clouds"; case 45,48: label = "Fog"; case 71...77,85,86: label = "Snow"; case 95...99: label = "Storms"; case 51...94: label = "Rain"; default: label = "On the road" }
        return Conditions(wet:wet,day:day == 1,label:label)
    }
}

struct Town {
    let name: String, region: String, country: String
    let point: Point
    var label: String { [name,region,country].filter { !$0.isEmpty }.joined(separator:", ") }
    static func find(_ fix: CLLocation) async throws -> Town? {
        guard let p = try await CLGeocoder().reverseGeocodeLocation(fix, preferredLocale:Locale(identifier:"en_US")).first,
              let city = p.locality ?? p.subAdministrativeArea else { return nil }
        return Town(name:city, region:p.administrativeArea ?? "", country:p.isoCountryCode ?? "", point:Point(fix.coordinate))
    }
}

/// An addressable source for recording credits and artist origins, independently of Spotify.
actor MusicMap {
    static let shared = MusicMap()
    private var nextRequest = Date.distantPast
    private var cache: [String:[Story]] = [:]
    private let identity = "RoadTripRadio/1.0 (https://github.com/intheaggregate/road-trip-radio)"
    private func fetch(_ path: String, _ query: [String:String]) async throws -> Object {
        let delay = max(0,nextRequest.timeIntervalSinceNow)
        nextRequest = Date().addingTimeInterval(delay + 1.1)
        if delay > 0 { try await Task.sleep(nanoseconds:UInt64(delay * 1e9)) }
        try Task.checkCancellation()
        var req = URLRequest(url:try Network.url("https://musicbrainz.org/ws/2/" + path,query.merging(["fmt":"json"]) { _,new in new }),timeoutInterval:9)
        req.setValue(identity,forHTTPHeaderField:"User-Agent")
        return try await Network.json(req)
    }
    private func string(_ any: Any?) -> String? { any as? String }
    private func number(_ any: Any?) -> Double? {
        if let n = any as? Double { return n }
        return (any as? String).flatMap(Double.init)
    }
    private func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"") + "\""
    }
    func stories(near point: Point, town: Town?) async throws -> [Story] {
        let key = "\(Int((point.latitude * 8).rounded()))|\(Int((point.longitude * 8).rounded()))|\(town?.label ?? "")"
        if let existing = cache[key] { return existing }
        var found: [Story] = []
        let span = 0.07 / max(0.15,cos(point.latitude * .pi / 180))
        let query = "lat:[\(point.latitude - 0.07) TO \(point.latitude + 0.07)] AND long:[\(point.longitude - span) TO \(point.longitude + span)]"
        let places = try await fetch("place",["query":query,"limit":"12"])
        let positioned = (places["places"] as? [Object] ?? []).compactMap { json -> (Object, Point)? in
            guard let coordinates = json["coordinates"] as? Object, let lat = number(coordinates["latitude"]), let lon = number(coordinates["longitude"]) else { return nil }
            return (json,Point(latitude:lat,longitude:lon))
        }.sorted { point.distance(to:$0.1) < point.distance(to:$1.1) }
        for (place, location) in positioned.prefix(3) {
            guard let id = string(place["id"]), let name = string(place["name"]) else { continue }
            let details = try await fetch("place/" + id,["inc":"recording-rels"])
            guard let link = (details["relations"] as? [Object])?.first(where:{ $0["type"] as? String == "recorded at" }),
                  let recording = link["recording"] as? Object, let rid = string(recording["id"]) else { continue }
            let credit = try await fetch("recording/" + rid,["inc":"artist-credits"])
            guard let title = string(credit["title"]), let artist = (credit["artist-credit"] as? [Object])?.first?["name"] as? String else { continue }
            found.append(Story(place:name,latitude:location.latitude,longitude:location.longitude,title:title,artist:artist,
                               reason:"\(artist) recorded this at \(name).",source:"https://musicbrainz.org/recording/" + rid))
            if found.count == 2 { break }
        }
        if let town {
            do { if let local = try await hometown(town) { found.append(local) } }
            catch { if found.isEmpty || Task.isCancelled { throw error } }
        }
        if cache.count > 80 { cache.removeAll(keepingCapacity:true) }
        cache[key] = found
        return found
    }
    private func hometown(_ town: Town) async throws -> Story? {
        let people = try await fetch("artist",["query":"beginarea:" + quote(town.name),"limit":"12"])
        for artist in (people["artists"] as? [Object] ?? []).prefix(4) {
            guard let id = string(artist["id"]), let name = string(artist["name"]), let area = artist["begin-area"] as? Object,
                  (area["name"] as? String)?.caseInsensitiveCompare(town.name) == .orderedSame, let areaID = string(area["id"]),
                  let type = string(artist["type"]), ["Group","Person"].contains(type) else { continue }
            guard try await matchesRegion(areaID, town:town) else { continue }
            let response = try await fetch("recording",["query":"arid:" + id + " AND status:official","limit":"5"])
            guard let title = (response["recordings"] as? [Object])?.first?["title"] as? String else { continue }
            let why = type == "Group" ? "\(name) formed in \(town.name)." : "\(name) was born in \(town.name)."
            return Story(place:town.name,latitude:town.point.latitude,longitude:town.point.longitude,title:title,
                         artist:name,reason:why,source:"https://musicbrainz.org/artist/" + id,areaRadius:8000)
        }
        return nil
    }
    private var ancestry: [String:Set<String>] = [:]
    private func matchesRegion(_ area: String, town: Town) async throws -> Bool {
        if ancestry[area] == nil {
            var names = Set<String>(), id: String? = area
            for _ in 0..<7 {
                guard let next = id else { break }
                let row = try await fetch("area/" + next,["inc":"area-rels"])
                if let name = string(row["name"]) { names.insert(name.uppercased()) }
                for field in ["iso-3166-1-codes","iso-3166-2-codes"] {
                    for code in row[field] as? [String] ?? [] { names.insert(code.uppercased()) }
                }
                id = (row["relations"] as? [Object])?.first(where:{ $0["type"] as? String == "part of" && $0["direction"] as? String == "backward" })
                    .flatMap { ($0["area"] as? Object)?["id"] as? String }
            }
            ancestry[area] = names
        }
        let names = ancestry[area] ?? []
        guard !town.country.isEmpty, names.contains(town.country.uppercased()) else { return false }
        return town.region.isEmpty || names.contains(town.region.uppercased()) || names.contains("\(town.country)-\(town.region)".uppercased())
    }
}
