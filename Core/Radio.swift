import Foundation

enum Energy: String, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic", mellow = "Mellow", cruise = "Cruising", upbeat = "Upbeat"
    var id: String { rawValue }
}

struct Point: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double
    var valid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) }

    /// Local east/north displacement in metres, including crossings of the date line.
    func offset(to other: Point) -> (east: Double, north: Double) {
        var delta = (other.longitude - longitude).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return (delta * 111_195 * cos((latitude + other.latitude) * .pi / 360),
                (other.latitude - latitude) * 111_195)
    }
    func distance(to other: Point) -> Double {
        let vector = offset(to: other)
        return hypot(vector.east, vector.north)
    }
}

struct Road {
    let points: [Point]
    let distances: [Double]
    let duration: Double
    var length: Double { distances.last ?? 0 }

    init(points: [Point], duration: Double) {
        self.points = points
        self.duration = duration
        var totals: [Double] = points.isEmpty ? [] : [0]
        for (a, b) in zip(points, points.dropFirst()) {
            totals.append((totals.last ?? 0) + a.distance(to: b))
        }
        distances = totals
    }
    func projection(_ point: Point) -> (along: Double, away: Double) {
        var closest = (along: 0.0, away: Double.infinity)
        for index in points.indices.dropFirst() {
            let start = points[index - 1]
            let edge = start.offset(to: points[index])
            let v = start.offset(to: point)
            let squared = edge.east * edge.east + edge.north * edge.north
            guard squared > 0 else { continue }
            let fraction = min(1, max(0, (v.east * edge.east + v.north * edge.north) / squared))
            let away = hypot(v.east - fraction * edge.east, v.north - fraction * edge.north)
            if away < closest.away { closest = (distances[index - 1] + fraction * sqrt(squared), away) }
        }
        return closest
    }
}

struct Song: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var seconds: Double
    var artwork: URL? = nil
    var uri: String { "spotify:track:" + id }
    var link: URL { URL(string: "https://open.spotify.com/track/" + id)! }
}

struct Pin: Codable, Identifiable, Equatable {
    var id = UUID()
    var place: String
    var point: Point
    var song: Song
    var note: String
}

struct Story: Codable, Hashable, Identifiable {
    var place: String
    var latitude: Double
    var longitude: Double
    var title: String
    var artist: String
    var reason: String
    var source: String
    var point: Point { Point(latitude: latitude, longitude: longitude) }
    var id: String { "\(place)|\(artist)|\(title)|\(latitude)|\(longitude)" }
    var valid: Bool {
        guard let link = URL(string: source), link.scheme == "https",
              let host = link.host, !host.isEmpty, point.valid else { return false }
        return [place, title, artist, reason].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 600 }
    }
}

struct ResearchPack: Codable {
    let version: Int
    let name: String
    let stories: [Story]
    func validated() throws -> ResearchPack {
        guard version == 1, name.count <= 180, !name.isEmpty, stories.count <= 40,
              stories.allSatisfy(\.valid) else { throw RadioError("This trip file contains an invalid place, song, or source link.") }
        return self
    }
}

struct RadioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Favorite {
    let song: Song
    let energy: Energy
}

struct Moment {
    let id: String
    let point: Point
    let song: Song
    let reason: String
    let source: URL?
    let personal: Bool
}

struct DriveContext {
    var point: Point
    var speed: Double
    var heading: Double?
    var road: Road?
    var elapsed: Double
    var requested: Energy
    var wet: Bool
    var daylight: Bool
    var nearArrival: Bool {
        guard let road, road.length > 0 else { return false }
        let projection = road.projection(point)
        return projection.away < 700 && (road.length - projection.along) / road.length * road.duration < 900
    }
    var energy: Energy {
        if requested != .automatic { return requested }
        if wet || !daylight { return .mellow }
        if nearArrival || elapsed > 5400 { return .upbeat }
        return .cruise
    }
    func eta(to target: Point) -> Double? {
        let direct = point.distance(to: target)
        if direct <= 220 { return 0 }
        if let road {
            let here = road.projection(point), there = road.projection(target)
            if here.away <= 650 {
                let distance = there.along - here.along
                guard there.away <= 650, distance >= -120 else { return nil }
                let routeSpeed = road.length / max(1, road.duration)
                let estimated = speed >= 2 ? (speed + routeSpeed) / 2 : routeSpeed
                return max(0, distance) / max(3, min(50, estimated))
            }
        }
        guard speed >= 2, let heading, heading >= 0 else { return nil }
        let v = point.offset(to: target), direction = heading * .pi / 180
        let forward = v.north * cos(direction) + v.east * sin(direction)
        let across = abs(v.east * cos(direction) - v.north * sin(direction))
        guard forward > 0, across < min(650, max(180, forward * 0.25)) else { return nil }
        return forward / min(50, speed)
    }
}

struct Pick: Equatable {
    var song: Song
    var reason: String
    var source: URL? = nil
    var momentID: String? = nil
    var personal = false
}

struct Mix {
    private(set) var used = Set<String>()
    private(set) var recent: [String] = []
    private(set) var familiarSinceDiscovery = 2

    mutating func record(_ pick: Pick) {
        if let id = pick.momentID { used.insert(id) }
        familiarSinceDiscovery = pick.momentID == nil ? familiarSinceDiscovery + 1 : 0
        if recent.last != pick.song.id { recent.append(pick.song.id) }
        if recent.count > 40 { recent.removeFirst() }
    }

    func choose(context: DriveContext, current: String, remaining: Double, moments: [Moment], favorites: [Favorite]) -> Pick? {
        let possible = moments.compactMap { moment -> (Moment, Double)? in
            guard moment.song.id != current, !used.contains(moment.id),
                  moment.personal || !recent.contains(moment.song.id),
                  let eta = context.eta(to: moment.point), eta <= 1200 else { return nil }
            return (moment, eta)
        }.sorted {
            if $0.0.personal != $1.0.personal { return $0.0.personal }
            return abs($0.1 - remaining) < abs($1.1 - remaining)
        }
        let hasFavorites = favorites.contains { $0.song.id != current }
        if let (moment, _) = possible.first(where: { moment, eta in
            let window = moment.personal ? 65.0 : 100.0
            return eta <= remaining + window && (moment.personal || familiarSinceDiscovery >= 2 || !hasFavorites)
        }) {
            return Pick(song: moment.song, reason: moment.reason, source: moment.source, momentID: moment.id, personal: moment.personal)
        }

        let aim = possible.first(where: { $0.1 > remaining + 65 && ($0.0.personal || familiarSinceDiscovery >= 1) })
        let targetEnergy = context.energy
        func cost(_ item: Favorite) -> Double {
            var score = 0.0
            if let index = recent.lastIndex(of: item.song.id) { score += 1500 + Double(index) * 12 }
            if item.energy != targetEnergy { score += item.energy == .automatic ? 80 : 190 }
            if let (_, eta) = aim {
                let residual = eta - remaining - item.song.seconds
                if residual < -60 { score += min(800, -residual * 2) }
                else if residual < 120 { score += abs(residual) }
                else { score += min(100, abs(residual - (residual / 210).rounded() * 210)) }
            }
            return score
        }
        guard let favorite = favorites.filter({ $0.song.id != current }).min(by: { cost($0) < cost($1) }) else { return nil }
        let reason: String
        if aim != nil { reason = "A favorite with time to finish before the next musical stop." }
        else if favorite.energy == .automatic { reason = "From your familiar rotation." }
        else if context.requested != .automatic { reason = "From your \(targetEnergy.rawValue.lowercased()) rotation." }
        else if context.wet && favorite.energy == .mellow { reason = "A mellow favorite for the rain." }
        else if !context.daylight && favorite.energy == .mellow { reason = "From your mellow rotation after dark." }
        else if context.nearArrival { reason = "A favorite for the last stretch." }
        else { reason = "From your \(favorite.energy.rawValue.lowercased()) rotation." }
        return Pick(song: favorite.song, reason: reason)
    }
}

/// Spotify exposes an append operation without an idempotency key. Reserve before sending;
/// a lost acknowledgement is held until the queue or a later track transition settles it.
struct QueueGate {
    private(set) var pending: Pick?
    private var origin: String?
    private var reservedAt = Date.distantPast
    private var lastSubmittedFrom: String?
    mutating func observe(current: String, queue: Set<String>?, now: Date) {
        if lastSubmittedFrom != current { lastSubmittedFrom = nil }
        guard let pending else { return }
        if current == pending.song.id {
            self.pending = nil
        } else if current != origin, let queue, !queue.contains(pending.song.id),
                  now.timeIntervalSince(reservedAt) >= 12 {
            self.pending = nil
        }
    }
    func ready(current: String, remaining: Double) -> Bool {
        pending == nil && lastSubmittedFrom != current && remaining > 0 && remaining <= 65
    }
    mutating func reserve(_ pick: Pick, from current: String, now: Date) {
        pending = pick; origin = current; reservedAt = now; lastSubmittedFrom = current
    }
    mutating func rejected() { pending = nil; lastSubmittedFrom = nil }
}
