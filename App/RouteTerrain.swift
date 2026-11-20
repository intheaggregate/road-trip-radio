import Foundation

enum RouteTerrain {
    /// One coarse lookup per planned route. Missing elevation coverage still yields
    /// a usable program with chapters based on the route's expected driving time.
    static func chapters(for road: Road) async -> [ListeningStretch] {
        struct Heights: Decodable { let elevation: [Double] }
        let probes = ListeningStretch.probes(for:road)
        guard !Task.isCancelled, probes.count >= 7 else { return ListeningStretch.chapters(for:road) }
        let locale = Locale(identifier:"en_US_POSIX")
        let lat = probes.map { String(format:"%.2f",locale:locale,$0.point.latitude) }.joined(separator:",")
        let lon = probes.map { String(format:"%.2f",locale:locale,$0.point.longitude) }.joined(separator:",")
        do {
            let url = try Network.url("https://api.open-meteo.com/v1/elevation",["latitude":lat,"longitude":lon])
            let (data,response) = try await URLSession.shared.data(for:URLRequest(url:url,timeoutInterval:6))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 16_384 else {
                return ListeningStretch.chapters(for:road)
            }
            let values = try JSONDecoder().decode(Heights.self,from:data).elevation
            guard values.count == probes.count else { return ListeningStretch.chapters(for:road) }
            let samples = zip(probes,values).map { ElevationSample(distance:$0.0.distance,height:$0.1) }
            return ListeningStretch.chapters(for:road,samples:samples)
        } catch {
            return ListeningStretch.chapters(for:road)
        }
    }
}
