import CoreLocation
import CryptoKit
import Foundation

@MainActor enum RouteMusicResearch {
    /// Imported notes and recording credits must fall on the selected road to become candidates.
    static func stops(on road: Road, known: [Story]) async -> [SoundtrackSlot] {
        guard road.length > 0 else { return [] }
        var stories = known
        func candidates() -> [SoundtrackSlot] {
            var seen = Set<String>()
            let matches = stories.compactMap { story -> (story:Story, along:Double, away:Double)? in
                guard story.valid else { return nil }
                let projection = road.projection(story.point)
                guard projection.away <= (story.areaRadius ?? 750) else { return nil }
                return (story,projection.along,projection.away)
            }.sorted { $0.away < $1.away }
            var chosen: [(slot:SoundtrackSlot, along:Double)] = []
            for match in matches {
                let story = match.story
                let track = CueTrack(title:story.title,artist:story.artist)
                guard !seen.contains(track.key),
                      !chosen.contains(where:{ abs($0.along - match.along) < 1200 }) else { continue }
                seen.insert(track.key)
                let identifier = SHA256.hash(data:Data(story.id.utf8)).prefix(8).map { String(format:"%02x",$0) }.joined()
                let slot = SoundtrackSlot(id:"recording-" + identifier,label:story.place,trigger:.nearby,
                                          path:[story.point],radius:story.areaRadius ?? 850,reference:story)
                chosen.append((slot,match.along))
                if chosen.count == 3 { break }
            }
            return chosen.sorted { $0.along < $1.along }.map { $0.slot }
        }
        for fraction in [0.45,0.85] {
            guard !Task.isCancelled, candidates().count < 3 else { break }
            guard let point = road.point(atDistance:road.length * fraction) else { continue }
            if let result = await lookup(point) { stories.append(contentsOf:result) }
        }
        return Task.isCancelled ? [] : candidates()
    }

    private static func lookup(_ point: Point) async -> [Story]? {
        await withTaskGroup(of:[Story]?.self) { group in
            group.addTask {
                let location = CLLocation(latitude:point.latitude,longitude:point.longitude)
                let town = try? await Town.find(location)
                guard !Task.isCancelled else { return nil }
                return try? await MusicMap.shared.stories(near:point,town:town)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds:15_000_000_000)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }
}
