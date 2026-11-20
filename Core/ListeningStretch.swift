import Foundation

struct ElevationSample {
    let distance: Double
    let height: Double
}

struct ListeningStretch: Equatable {
    let lower: Double
    let upper: Double
    let terrain: String?
    let minutes: Int

    /// Sparse interior points rounded before they leave the device. Keep private
    /// endpoints out even if a hairpin or loop passes them again mid-drive.
    static func probes(for road: Road) -> [(distance: Double, point: Point)] {
        guard road.length.isFinite, road.length >= 24_000, road.duration >= 1500,
              let start = road.points.first, let end = road.points.last else { return [] }
        let count = Int(min(72,max(12,(road.length / 4500).rounded(.up))))
        var result = [(distance:Double,point:Point)]()
        for index in 0..<count {
            let distance = road.length * (0.06 + 0.88 * Double(index) / Double(count - 1))
            guard let point = road.point(atDistance:distance) else { continue }
            let coarse = Point(latitude:(point.latitude * 100).rounded() / 100,
                               longitude:(point.longitude * 100).rounded() / 100)
            guard coarse.valid, coarse.distance(to:start) >= 1000, coarse.distance(to:end) >= 1000,
                  result.last?.point != coarse else { continue }
            result.append((distance,coarse))
        }
        return result
    }

    private enum Terrain: Int {
        case level, rolling, change
        var label: String {
            switch self {
            case .level: return "level terrain"
            case .rolling: return "rolling terrain"
            case .change: return "changing elevation"
            }
        }
    }

    static func chapters(for road: Road, samples: [ElevationSample] = []) -> [ListeningStretch] {
        guard road.length.isFinite, road.duration.isFinite, road.length >= 8000, road.duration >= 600 else { return [] }
        let lower = road.length * 0.06, upper = road.length * 0.94
        let fallbackCount = Int(min(6,max(1,(road.duration * 0.88 / 5400).rounded(.up))))
        var cuts = [lower,upper]
        let valid = (7...80).contains(samples.count) &&
            samples.allSatisfy { (0...road.length).contains($0.distance) && (-500...9000).contains($0.height) } &&
            zip(samples,samples.dropFirst()).allSatisfy { $1.distance > $0.distance && $1.distance - $0.distance <= 40_000 }
        var bands = [Terrain]()
        if valid {
            // Metres of elevation change per horizontal kilometre. A lower median
            // across neighbouring intervals keeps an isolated DEM spike out of the score.
            let slopes = zip(samples,samples.dropFirst()).map { a,b in
                (b.height - a.height) * 1000 / (b.distance - a.distance)
            }
            for i in samples.indices {
                let local = slopes[max(0,i-2)..<min(slopes.count,i+2)]
                let values = local.map { abs($0) }.sorted()
                let typical = values[(values.count-1)/2]
                let reverses = local.contains { $0 < -1 } && local.contains { $0 > 1 }
                if typical < 2.5 { bands.append(.level) }
                else if typical < 10 && reverses { bands.append(.rolling) }
                else { bands.append(.change) }
            }
            // Require a sustained run on each side. Prefer strong changes when
            // several nearby boundaries compete for the same few minutes of music.
            var candidates = [(boundary:Double,strength:Int)]()
            for i in 3..<(bands.count-2) where bands[i] != bands[i-1] {
                let before = bands[i-3..<i], after = bands[i...i+2]
                if before.allSatisfy({ $0 == bands[i-1] }) && after.allSatisfy({ $0 == bands[i] }) {
                    candidates.append(((samples[i-1].distance + samples[i].distance)/2,
                                       abs(bands[i].rawValue - bands[i-1].rawValue)))
                }
            }
            let minimumGap = road.length * max(0.055,min(0.24,1200 / road.duration))
            for change in candidates.sorted(by:{ a,b in a.strength == b.strength ? a.boundary < b.boundary : a.strength > b.strength }) {
                if cuts.count >= 7 { break }
                if change.boundary > lower && change.boundary < upper &&
                    cuts.allSatisfy({ abs($0 - change.boundary) >= minimumGap }) { cuts.append(change.boundary) }
            }
        }
        cuts.sort()
        if cuts.count == 2 {
            cuts = (0...fallbackCount).map { lower + (upper-lower) * Double($0) / Double(fallbackCount) }
        }
        // Preserve all retained terrain transitions. Split the longest stretches if
        // the drive still needs more listening chapters by duration alone.
        while cuts.count <= fallbackCount {
            let longest = (1..<cuts.count).max { a,b in cuts[a]-cuts[a-1] < cuts[b]-cuts[b-1] }!
            cuts.insert((cuts[longest] + cuts[longest-1])/2,at:longest)
        }
        return zip(cuts,cuts.dropFirst()).map { a,b in
            var label: String?
            if valid {
                let indices = samples.indices.filter { a <= samples[$0].distance && samples[$0].distance <= b }
                if let first = indices.first, let last = indices.last, indices.count >= 3,
                   samples[last].distance - samples[first].distance >= (b-a)*0.5 {
                    let measured = indices.map { bands[$0] }
                    let votes = [Terrain.level,.rolling,.change].map { kind in (kind,measured.filter { $0 == kind }.count) }
                    if let strongest = votes.max(by:{ $0.1 < $1.1 }), strongest.1 * 5 >= measured.count * 3 {
                        label = strongest.0.label
                    } else { label = "changing elevation" }
                }
            }
            let minutes = max(1,(road.duration * ((b-a)/road.length) / 60).rounded())
            return ListeningStretch(lower:a,upper:b,terrain:label,minutes:Int(exactly:minutes) ?? Int.max)
        }
    }
}
