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
    var areaRadius: Double? = nil
    var point: Point { Point(latitude: latitude, longitude: longitude) }
    var id: String { "\(place)|\(artist)|\(title)|\(latitude)|\(longitude)" }
    var valid: Bool {
        guard let link = URL(string: source), link.scheme == "https",
              let host = link.host, !host.isEmpty, point.valid,
              areaRadius.map({ (0...15000).contains($0) }) ?? true else { return false }
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

struct RoadSong {
    let title: String
    let artist: String
    let energy: Energy
    static let selections = [
        RoadSong(title:"Come Away With Me",artist:"Norah Jones",energy:.mellow),
        RoadSong(title:"Harvest Moon",artist:"Neil Young",energy:.mellow),
        RoadSong(title:"Lovely Day",artist:"Bill Withers",energy:.cruise),
        RoadSong(title:"Dreams",artist:"Fleetwood Mac",energy:.cruise),
        RoadSong(title:"Move On Up",artist:"Curtis Mayfield",energy:.upbeat),
        RoadSong(title:"Walking On Sunshine",artist:"Katrina & The Waves",energy:.upbeat)
    ]
    var key: String { "road-music|" + artist + "|" + title }
}

struct Moment {
    let id: String
    let point: Point
    let song: Song
    let reason: String
    let source: URL?
    let personal: Bool
    var areaRadius: Double? = nil
    var cuePriority: CuePriority? = nil
    var estimatedETA: Double? = nil
}

enum CuePriority: Int {
    case regional = 1, bookend, departure, highwayOpening, landmark
}

enum CueTrigger: String, Codable {
    case departure, bookend, approach, highwayOpening, region, longStretch, nearby
}

struct CueTrack: Codable, Hashable {
    var title: String
    var artist: String
    var key: String { "program|\(artist.lowercased())|\(title.lowercased())" }
}

struct DriveCue: Codable {
    let id: String
    let trigger: CueTrigger
    let label: String
    let reason: String
    let tracks: [CueTrack]
    let path: [Point]
    let radius: Double
    var musicStyle: String? = nil

    func projection(_ point: Point) -> (along: Double, away: Double) {
        if path.count == 1 { return (0, point.distance(to:path[0])) }
        return Road(points:path,duration:0).projection(point)
    }
}

struct DriveProgram: Codable {
    let version: Int
    let name: String
    let cues: [DriveCue]

    func validated() throws -> DriveProgram {
        func text(_ value: String, _ limit: Int) -> Bool {
            !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.count <= limit &&
                value.rangeOfCharacter(from:.controlCharacters) == nil
        }
        guard version == 1, text(name,160), (1...60).contains(cues.count),
              Set(cues.map(\.id)).count == cues.count else { throw RadioError("Choose a version 1 driving program with unique cues.") }
        for cue in cues {
            guard text(cue.id,90), text(cue.label,160), text(cue.reason,450),
                  cue.id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil,
                  (1...16).contains(cue.tracks.count), cue.tracks.allSatisfy({ text($0.title,160) && text($0.artist,160) }),
                  cue.path.count <= 150, cue.path.allSatisfy(\.valid), (0...120000).contains(cue.radius),
                  cue.radius > 0 || (cue.trigger == .highwayOpening && cue.path.isEmpty),
                  cue.musicStyle.map({ text($0,160) }) ?? true else { throw RadioError("A driving cue has invalid songs, text, or coordinates.") }
            switch cue.trigger {
            case .approach:
                guard cue.path.count >= 2, Road(points:cue.path,duration:0).length > 30 else {
                    throw RadioError("An approach needs a path ending at its landmark.")
                }
            case .departure, .bookend:
                guard cue.path.count == 1 else { throw RadioError("A trip endpoint needs one center point.") }
            case .highwayOpening: break
            case .nearby, .region, .longStretch:
                guard !cue.path.isEmpty else { throw RadioError("This cue needs a place or a stretch of road.") }
            }
        }
        return self
    }
}

/// Evidence comes from this drive's fixes. Starting the app mid-route does not imply
/// an earlier city departure, highway entry, or long spell of driving.
struct ProgramDrive {
    private var origin: Point?
    private var previous: (point: Point, elapsed: Double)?
    private var course: Double?
    private var courseAnchor: Point?
    private var sawStreetSpeed = false
    private var fastSince: (point: Point, elapsed: Double)?
    private var highwayAt: Double?
    private var seenOutside = Set<String>()
    private var crossedAt: [String:Double] = [:]
    private var approaching = Set<String>()
    private var corridorSeconds: [String:Double] = [:]

    mutating func observe(_ context: DriveContext, program: DriveProgram? = nil) {
        if origin == nil { origin = context.point }
        if let previous, context.elapsed < previous.elapsed { return }
        defer { previous = (context.point,context.elapsed) }
        if let anchor = courseAnchor, anchor.distance(to:context.point) >= 65 {
            let offset = anchor.offset(to:context.point)
            course = atan2(offset.east,offset.north) * 180 / .pi
            courseAnchor = context.point
        } else if courseAnchor == nil { courseAnchor = context.point }
        if context.speed < 12 { sawStreetSpeed = true }
        if context.speed >= 19, sawStreetSpeed {
            if let start = fastSince {
                if highwayAt == nil, context.elapsed - start.elapsed >= 7,
                   start.point.distance(to:context.point) >= 130 { highwayAt = context.elapsed }
            } else { fastSince = (context.point,context.elapsed) }
        } else { fastSince = nil }

        guard let program else { return }
        for cue in program.cues {
            switch cue.trigger {
            case .bookend:
                if let center = cue.path.first, center.distance(to:context.point) > cue.radius + 8000 {
                    seenOutside.insert(cue.id)
                }
            case .approach:
                guard crossedAt[cue.id] == nil, let end = cue.path.last else { continue }
                let onApproach = approachETA(cue,context:context) != nil
                if onApproach && end.distance(to:context.point) <= cue.radius {
                    crossedAt[cue.id] = context.elapsed
                } else if approaching.contains(cue.id), let previous, context.elapsed - previous.elapsed <= 90 {
                    let movement = Road(points:[previous.point,context.point],duration:0)
                    let pass = movement.projection(end)
                    if movement.length < 4000, pass.away <= cue.radius, pass.along > 0, pass.along < movement.length {
                        crossedAt[cue.id] = context.elapsed
                    }
                }
                if onApproach { approaching.insert(cue.id) } else { approaching.remove(cue.id) }
            case .longStretch:
                if cue.projection(context.point).away > cue.radius { corridorSeconds[cue.id] = nil; continue }
                let alreadyInside = corridorSeconds[cue.id] != nil
                if corridorSeconds[cue.id] == nil { corridorSeconds[cue.id] = 0 }
                if alreadyInside, let previous, context.speed >= 4, previous.point.distance(to:context.point) > 20 {
                    let dt = context.elapsed - previous.elapsed
                    if (0...180).contains(dt) { corridorSeconds[cue.id,default:0] += dt }
                }
            default: break
            }
        }
    }

    /// Follow the ordered approach line, so a parallel highway or the reverse crossing
    /// cannot use this cue. Use local road direction even when no destination is set.
    private func approachETA(_ cue: DriveCue, context: DriveContext) -> Double? {
        guard context.speed >= 2, let heading = context.heading ?? course else { return nil }
        let road = Road(points:cue.path,duration:0)
        let here = road.projection(context.point)
        guard here.away <= cue.radius, road.length > 0 else { return nil }
        let index = road.distances.indices.dropFirst().first { road.distances[$0] >= here.along } ?? (cue.path.count - 1)
        guard index > 0 else { return nil }
        let segment = cue.path[index-1].offset(to:cue.path[index])
        let direction = atan2(segment.east,segment.north)
        guard cos(heading * .pi / 180 - direction) > 0.55 else { return nil }
        if let navigation = context.road, let target = cue.path.last {
            let position = navigation.projection(context.point)
            if position.away <= 600 {
                let crossing = navigation.projection(target)
                guard crossing.away <= max(200,cue.radius), crossing.along >= position.along - cue.radius else { return nil }
            }
        }
        return max(0,road.length - here.along) / min(45,max(6,context.speed))
    }

    private func opening(_ context: DriveContext, program: DriveProgram) -> Bool {
        guard context.elapsed <= 5400, let origin, origin.distance(to:context.point) <= 95000 else { return false }
        return program.cues.contains { cue in
            (cue.trigger == .bookend || cue.trigger == .departure) && cue.path.first.map { origin.distance(to:$0) <= cue.radius } == true
        }
    }

    private typealias Window = (phase: String, priority: CuePriority, eta: Double)
    private func window(_ cue: DriveCue, program: DriveProgram, context: DriveContext) -> Window? {
        guard let origin else { return nil }
        switch cue.trigger {
        case .departure, .bookend:
            guard let center = cue.path.first, center.distance(to:context.point) <= cue.radius else { return nil }
            if context.elapsed <= 2700, center.distance(to:origin) <= cue.radius, !seenOutside.contains(cue.id) {
                return ("out",cue.trigger == .departure ? .departure : .bookend,0)
            }
            guard cue.trigger == .bookend, seenOutside.contains(cue.id) else { return nil }
            if let destination = context.road?.points.last, destination.distance(to:center) > cue.radius + 5000 { return nil }
            return ("in",.bookend,0)
        case .highwayOpening:
            guard opening(context,program:program), let highwayAt, context.elapsed - highwayAt <= 480,
                  cue.path.isEmpty || cue.projection(context.point).away <= cue.radius else { return nil }
            return ("entry",.highwayOpening,0)
        case .approach:
            if let crossed = crossedAt[cue.id] {
                guard context.elapsed - crossed <= 240, let target = cue.path.last, context.point.distance(to:target) < 8500 else { return nil }
                return ("crossing",.landmark,0)
            }
            guard let eta = approachETA(cue,context:context), eta <= 1200 else { return nil }
            return ("crossing",.landmark,eta)
        case .region, .nearby, .longStretch:
            guard cue.projection(context.point).away <= cue.radius else { return nil }
            if cue.trigger == .longStretch {
                let minimum: Double = context.elapsed >= 5400 ? 600 : 1500
                guard (corridorSeconds[cue.id] ?? 0) >= minimum else { return nil }
            }
            return ("area",cue.trigger == .nearby ? .landmark : .regional,0)
        }
    }

    func preload(in program: DriveProgram, context: DriveContext) -> [CueTrack] {
        var seen = Set<String>()
        let ordered = program.cues.compactMap { cue -> (DriveCue,Int,Double)? in
            if let match = window(cue,program:program,context:context) { return (cue,-match.priority.rawValue,match.eta) }
            if cue.trigger == .highwayOpening { return opening(context,program:program) ? (cue,0,0) : nil }
            let distance = cue.projection(context.point).away - cue.radius
            return distance <= 25000 ? (cue,1,distance) : nil
        }.sorted { a,b in a.1 != b.1 ? a.1 < b.1 : a.2 < b.2 }
        return ordered.flatMap { $0.0.tracks }.filter { seen.insert($0.key).inserted }
    }

    func moments(in program: DriveProgram, context: DriveContext, resolved: [String:Song], remaining: Double) -> [Moment] {
        program.cues.flatMap { cue -> [Moment] in
            guard let match = window(cue,program:program,context:context) else { return [] }
            if let crossed = crossedAt[cue.id], context.elapsed - crossed + remaining > 300 { return [] }
            return cue.tracks.compactMap { track in
                guard let song = resolved[track.key] else { return nil }
                let perTrack = match.priority == .regional || match.priority == .bookend ? "|" + track.key : ""
                return Moment(id:"program|\(cue.id)|\(match.phase)" + perTrack,point:context.point,song:song,
                              reason:cue.reason,source:nil,personal:false,cuePriority:match.priority,estimatedETA:match.eta)
            }
        }
    }

    func musicStyle(in program: DriveProgram, context: DriveContext) -> String? {
        for cue in program.cues where cue.trigger == .region || cue.trigger == .longStretch {
            if let style = cue.musicStyle, window(cue,program:program,context:context) != nil { return style }
        }
        return nil
    }
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

    func choose(context: DriveContext, current: String, remaining: Double, moments: [Moment], favorites: [Favorite], roadSongs: [Favorite] = []) -> Pick? {
        let possible = moments.compactMap { moment -> (Moment, Double)? in
            guard moment.song.id != current, !used.contains(moment.id),
                  moment.personal || !recent.contains(moment.song.id) else { return nil }
            let insideArea = moment.areaRadius.map { context.point.distance(to:moment.point) <= $0 } ?? false
            guard let eta = moment.estimatedETA ?? (insideArea ? 0 : context.eta(to:moment.point)), eta <= 1200 else { return nil }
            return (moment, eta)
        }.sorted {
            if $0.0.personal != $1.0.personal { return $0.0.personal }
            let first = $0.0.cuePriority?.rawValue ?? 0, second = $1.0.cuePriority?.rawValue ?? 0
            if first != second { return first > second }
            return abs($0.1 - remaining) < abs($1.1 - remaining)
        }
        let hasFavorites = favorites.contains { $0.song.id != current }
        if let (moment, _) = possible.first(where: { moment, eta in
            let window = moment.cuePriority == .landmark ? 15.0 : (moment.personal ? 65.0 : 100.0)
            let explicitCue = (moment.cuePriority?.rawValue ?? 0) > CuePriority.regional.rawValue
            return eta <= remaining + window && (moment.personal || explicitCue || familiarSinceDiscovery >= 2 || !hasFavorites)
        }) {
            return Pick(song: moment.song, reason: moment.reason, source: moment.source, momentID: moment.id, personal: moment.personal)
        }

        let aim = possible.first(where: { moment, eta in
            let landmark = moment.cuePriority == .landmark
            return eta > remaining + (landmark ? 15 : 65) && (moment.personal || landmark || familiarSinceDiscovery >= 1)
        })
        let targetEnergy = context.energy
        if aim == nil, familiarSinceDiscovery >= 2 || !hasFavorites,
           let match = roadSongs.first(where: { $0.energy == targetEnergy && $0.song.id != current && !recent.contains($0.song.id) && !used.contains("energy|" + $0.song.id) }) {
            let reason: String
            if context.requested != .automatic { reason = "A pick for your " + targetEnergy.rawValue.lowercased() + " drive." }
            else if context.wet { reason = "A quieter pick for the rain." }
            else if !context.daylight { reason = "A mellow pick for the road after dark." }
            else if context.nearArrival { reason = "An upbeat pick for the last stretch." }
            else if context.elapsed > 5400 { reason = "A lift after a long stretch on the road." }
            else { reason = "An easygoing pick for the open road." }
            return Pick(song:match.song,reason:reason,momentID:"energy|" + match.song.id)
        }
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
