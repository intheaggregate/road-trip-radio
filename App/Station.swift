import Combine
import CoreLocation
import Foundation
import MapKit
import SwiftUI

struct Rotation: Codable, Identifiable {
    var id: String
    var name: String
    var energy: Energy
}
private struct Preferences: Codable {
    var pins: [Pin] = []
    var rotations: [Rotation] = []
    var likes = true
    var energy = Energy.automatic
    var device = ""
    var live = false
    var stories: [Story] = []
}
struct AirLog: Identifiable {
    let id = UUID()
    let pick: Pick
}

@MainActor
final class Station: ObservableObject {
    let spotify = Spotify()
    let gps = TripGPS()
    private let music = MusicMap()
    private let prefKey = "radio.preferences.v1"
    @Published private var prefs: Preferences
    @Published private(set) var connected = false
    @Published var busy = false
    @Published var starting = false
    @Published private(set) var driving = false
    @Published var notice = ""
    @Published var status = "Ready for a drive"
    @Published var libraryStatus = ""
    @Published var researchStatus = ""
    @Published var playerName = ""
    @Published var routeBusy = false
    @Published var route: RoutePlan?
    @Published var current: Song?
    @Published var next: Pick?
    @Published var log: [AirLog] = []
    @Published var devices: [Device] = []
    @Published var lists: [LibraryList] = []
    @Published var place = ""
    @Published var conditions: Conditions?
    @Published var fix: CLLocation?
    @Published var researchBusy = false
    @Published var companion = CompanionConfig()
    private var seed: [Story] = []
    private var localStories: [Story] = []
    @Published private var routeStories: [Story] = []
    @Published private(set) var lookingAlongRoute = false
    private var previewTask: Task<Void,Never>?
    private var resolved: [String:Song] = [:]
    private var lookupAfter: [String:Date] = [:]
    private var favorites: [Favorite] = []
    private var activeDevice = ""
    private var startTime = Date()
    private var marker = UUID()
    private var routeMarker = UUID()
    private var heldQueueOrigin: String?
    private var mix = Mix(), gate = QueueGate()
    private var tickTask: Task<Void,Never>?, clockTask: Task<Void,Never>?, contextTask: Task<Void,Never>?
    private var discoveryTask: Task<Void,Never>?, lookupTask: Task<Void,Never>?, libraryTask: Task<Void,Never>?
    private var liveTask: Task<Void,Never>?, routeTask: Task<Void,Never>?
    private var lastPoll = Date.distantPast, lastArea = Date.distantPast, lastRoute = Date.distantPast
    private var lastContextPoint: Point?, weatherPoint: Point?, weatherAt = Date.distantPast
    private var liveAt = Date.distantPast, lastLiveTown = "", catalogAt = Date.distantPast
    private var town: Town?
    private var blockedUntil = Date.distantPast
    private var pollAfter = Date.distantPast
    private var consecutiveErrors = 0
    private var routeDeviations = 0

    init() {
        let data = UserDefaults.standard.data(forKey:prefKey)
        prefs = data.flatMap { try? JSONDecoder().decode(Preferences.self,from:$0) } ?? Preferences()
        if let url = Bundle.main.url(forResource:"Landmarks",withExtension:"json"),
           let data = try? Data(contentsOf:url), let pack = try? JSONDecoder().decode(ResearchPack.self,from:data).validated() { seed = pack.stories }
        if let data = Vault.data("companion"), let config = try? JSONDecoder().decode(CompanionConfig.self,from:data) { companion = config }
        connected = spotify.connected
        gps.onFix = { [weak self] location in self?.receive(location) }
        gps.onIssue = { [weak self] message in self?.notice = message }
    }
    var pins: [Pin] { prefs.pins }
    var rotations: [Rotation] { prefs.rotations }
    var energy: Energy { get { prefs.energy } set { prefs.energy = newValue; save() } }
    var likes: Bool { get { prefs.likes } set { prefs.likes = newValue; save(); reloadLibrary() } }
    var device: String { get { prefs.device } set { prefs.device = newValue; save() } }
    var live: Bool { get { prefs.live } set { prefs.live = newValue; save(); if !newValue { liveTask?.cancel() } } }
    var savedStories: [Story] { prefs.stories }
    var point: Point? { fix.map { Point($0.coordinate) } }
    var allStories: [Story] {
        var known = Set<String>()
        return (seed + prefs.stories + routeStories + localStories).filter { known.insert($0.id).inserted }
    }
    var highlights: [(String,String)] {
        guard let route else { return [] }
        let records = pins.map { ($0.place,$0.song.title,$0.point) } + allStories.map { ($0.place,$0.title,$0.point) }
        return records.compactMap { name,title,point -> (Double,String,String)? in
            let p = route.road.projection(point)
            return p.away < 1500 ? (p.along,name,title) : nil
        }.sorted { $0.0 < $1.0 }.prefix(12).map { ($0.1,$0.2) }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data,forKey:prefKey) }
    }
    func add(_ pin: Pin) { prefs.pins.append(pin); save() }
    func removePin(_ id: UUID) { prefs.pins.removeAll { $0.id == id }; save() }
    func removeStory(_ id: String) { prefs.stories.removeAll { $0.id == id }; save() }
    func setRotation(_ list: LibraryList, _ energy: Energy?) {
        prefs.rotations.removeAll { $0.id == list.id }
        if let energy { prefs.rotations.append(Rotation(id:list.id,name:list.name,energy:energy)) }
        save(); reloadLibrary()
    }
    func connect(_ id: String) async {
        busy = true; defer { busy = false }
        do { try await spotify.connect(client:id); connected = true; await refreshChoices() }
        catch { notice = error.localizedDescription }
    }
    func disconnect() {
        stop(); spotify.disconnect(); connected = false
        prefs.pins = []; prefs.rotations = []; prefs.device = ""; prefs.likes = true; save()
        lists = []; devices = []; favorites = []; resolved = [:]; current = nil; next = nil; log = []; libraryStatus = ""
    }
    func refreshChoices() async {
        guard connected else { return }
        do { devices = try await spotify.devices() } catch { notice = error.localizedDescription }
        do { lists = try await spotify.lists() } catch { libraryStatus = error.localizedDescription }
    }
    private func reloadLibrary() {
        libraryTask?.cancel()
        let selections = prefs.rotations, useLikes = prefs.likes
        libraryTask = Task {
            guard connected else { return }
            var next: [Favorite] = [], problems: [String] = []
            for (id, energy, name) in (useLikes ? [(nil as String?,Energy.automatic,"Liked Songs")] : []) + selections.map({ (Optional($0.id),$0.energy,$0.name) }) {
                do {
                    let tracks = try await spotify.rotation(id)
                    next += tracks.map { Favorite(song:$0,energy:energy) }
                } catch { problems.append(name + " · " + error.localizedDescription) }
                if Task.isCancelled { return }
            }
            favorites = next.shuffled()
            libraryStatus = (["\(Set(next.map { $0.song.id }).count) songs in this rotation"] + problems).joined(separator:"\n")
        }
    }
    func setRoute(_ item: MKMapItem) async {
        let nonce = UUID(); routeMarker = nonce
        previewTask?.cancel(); lookingAlongRoute = false
        routeBusy = true
        defer { if routeMarker == nonce { routeBusy = false } }
        do {
            if fix.map({ abs($0.timestamp.timeIntervalSinceNow) > 90 }) ?? true {
                gps.request()
                for _ in 0..<40 {
                    guard routeMarker == nonce else { return }
                    if let fix, abs(fix.timestamp.timeIntervalSinceNow) <= 90 { break }
                    try await Task.sleep(nanoseconds:250_000_000)
                }
            }
            guard let fix, abs(fix.timestamp.timeIntervalSinceNow) <= 90 else { throw RadioError("A current location is needed to preview the route. Check Location access in iPhone Settings.") }
            let result = try await RoutePlan.make(from:fix,to:item)
            guard routeMarker == nonce else { return }
            route = result; lastRoute = Date(); routeDeviations = 0
            if !driving { preview(result,token:nonce) }
        } catch { if routeMarker == nonce { notice = error.localizedDescription } }
    }
    private func preview(_ plan: RoutePlan, token: UUID) {
        routeStories = []; lookingAlongRoute = true
        previewTask = Task {
            defer { if routeMarker == token { lookingAlongRoute = false } }
            let road = plan.road
            for fraction in [0.45,1.0] {
                guard let index = road.distances.firstIndex(where:{ $0 >= road.length * fraction }),
                      routeMarker == token, !Task.isCancelled else { return }
                let p = road.points[index]
                let town = try? await Town.find(CLLocation(latitude:p.latitude,longitude:p.longitude))
                if let found = try? await music.stories(near:p,town:town), routeMarker == token {
                    routeStories += found
                }
            }
        }
    }
    func clearRoute() {
        routeMarker = UUID(); previewTask?.cancel(); lookingAlongRoute = false; routeStories = []
        routeTask?.cancel(); routeTask = nil; routeBusy = false; route = nil
    }
    func start() async {
        guard !starting, !driving else { return }
        guard connected else { notice = "Connect your Spotify account in Settings first."; return }
        guard [.authorizedAlways,.authorizedWhenInUse].contains(gps.manager.authorizationStatus) else { gps.request(); notice = "Allow location access, then tap Start again."; return }
        let generation = marker
        starting = true; defer { if marker == generation { starting = false } }
        do {
            let state = try await spotify.player()
            let available = try await spotify.devices()
            guard marker == generation else { return }
            devices = available
            let choice = prefs.device.isEmpty ? available.first { $0.active && $0.type.lowercased() == "smartphone" } : available.first { $0.id == prefs.device }
            guard let choice else { throw RadioError("Open Spotify on this iPhone and play a song, or choose the playback device in Settings.") }
            if state.device?.id != choice.id || !state.playing {
                if favorites.isEmpty && prefs.rotations.isEmpty && state.track == nil { reloadLibrary(); await libraryTask?.value }
                guard marker == generation else { return }
                try await spotify.start(device:choice.id,playlist:prefs.rotations.first?.id,songs:favorites.map(\.song),resume:state.device?.id == choice.id && state.track != nil)
            }
            guard marker == generation else { return }
            activeDevice = choice.id; playerName = choice.name; driving = true; starting = false
            startTime = Date(); mix = Mix(); gate = QueueGate(); heldQueueOrigin = nil; current = nil; next = nil; log = []
            status = "Listening on \(choice.name)"; blockedUntil = .distantPast; lastPoll = .distantPast
            pollAfter = .distantPast; consecutiveErrors = 0
            gps.start(); reloadLibrary(); pulse()
            if let fix, abs(fix.timestamp.timeIntervalSinceNow) < 75 { receive(fix) }
            clockTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds:8_000_000_000)
                    if Task.isCancelled { return }; pulse()
                }
            }
        } catch { if marker == generation { notice = error.localizedDescription } }
    }
    func stop() {
        marker = UUID(); driving = false; starting = false; gps.stop()
        for task in [tickTask,clockTask,contextTask,discoveryTask,lookupTask,libraryTask,liveTask,routeTask] { task?.cancel() }
        tickTask = nil; clockTask = nil; contextTask = nil; discoveryTask = nil; lookupTask = nil
        libraryTask = nil; liveTask = nil; routeTask = nil
        status = "Drive ended"; next = nil; current = nil; activeDevice = ""; heldQueueOrigin = nil; routeDeviations = 0
    }
    private func receive(_ location: CLLocation) {
        fix = location
        guard driving else { return }
        let p = Point(location.coordinate), token = marker
        let moved = lastContextPoint.map { $0.distance(to:p) > 5500 } ?? true
        if contextTask == nil && (moved || Date().timeIntervalSince(lastArea) > 600) && Date().timeIntervalSince(lastArea) > 35 {
            lastArea = Date(); lastContextPoint = p
            contextTask = Task {
                defer { if marker == token { contextTask = nil } }
                let found = try? await Town.find(location)
                guard marker == token else { return }
                town = found; place = found?.name ?? ""
                if (weatherPoint.map({ $0.distance(to:p) > 15000 }) ?? true) || Date().timeIntervalSince(weatherAt) > 900 {
                    let weather = try? await Conditions.load(p)
                    guard marker == token else { return }
                    if let weather { conditions = weather; weatherPoint = p; weatherAt = Date() }
                }
                discover(p, town:found); requestLiveIfDue()
            }
        }
        if let route, Date().timeIntervalSince(lastRoute) > 50, !routeBusy {
            routeDeviations = route.road.projection(p).away > 850 ? routeDeviations + 1 : 0
            if routeDeviations >= 2 {
                routeDeviations = 0; lastRoute = Date()
                routeTask = Task { await setRoute(route.destination) }
            }
        }
        resolveNear(p); pulse()
    }
    private func discover(_ p: Point, town: Town?) {
        guard discoveryTask == nil, Date().timeIntervalSince(catalogAt) > 70 else { return }
        catalogAt = Date(); let token = marker
        discoveryTask = Task {
            defer { if marker == token { discoveryTask = nil } }
            if let result = try? await music.stories(near:p,town:town), marker == token {
                localStories = result; resolveNear(p)
            }
        }
    }
    private func resolveNear(_ p: Point) {
        guard lookupTask == nil, Date() >= blockedUntil else { return }
        let nearby = allStories.filter { $0.point.distance(to:p) < 30000 && resolved[$0.id] == nil && (lookupAfter[$0.id] ?? .distantPast) <= Date() }
            .sorted { $0.point.distance(to:p) < $1.point.distance(to:p) }
        guard !nearby.isEmpty else { return }
        let token = marker
        lookupTask = Task {
            defer { if marker == token { lookupTask = nil } }
            for story in nearby.prefix(4) {
                guard !Task.isCancelled, marker == token else { return }
                lookupAfter[story.id] = Date().addingTimeInterval(300)
                do {
                    let song = try await spotify.resolve(story)
                    guard marker == token else { return }
                    if let song { resolved[story.id] = song }
                } catch let e as ServiceError where e.status == 429 {
                    blockedUntil = Date().addingTimeInterval(e.wait); return
                } catch { return }
            }
        }
    }
    private func context(_ location: CLLocation) -> DriveContext {
        let localHour = Calendar.current.component(.hour,from:Date())
        return DriveContext(point:Point(location.coordinate), speed:max(0,location.speed), heading:location.course >= 0 ? location.course:nil,
                            road:route?.road, elapsed:Date().timeIntervalSince(startTime), requested:energy,
                            wet:conditions?.wet ?? false,daylight:conditions?.day ?? (7..<19).contains(localHour))
    }
    func pulse() {
        guard driving, tickTask == nil, Date() >= max(blockedUntil,pollAfter), Date().timeIntervalSince(lastPoll) >= 7 else { return }
        let token = marker; lastPoll = Date()
        tickTask = Task {
            defer { if marker == token { tickTask = nil } }
            do { try await tick(token); if marker == token { consecutiveErrors = 0 } }
            catch {
                guard marker == token else { return }
                if let e = error as? ServiceError, e.status == 429 { blockedUntil = Date().addingTimeInterval(e.wait) }
                consecutiveErrors = min(4,consecutiveErrors + 1)
                pollAfter = Date().addingTimeInterval(5 * pow(2,Double(consecutiveErrors)))
                status = "Waiting for Spotify · " + error.localizedDescription
            }
        }
    }
    private func tick(_ token: UUID) async throws {
        let state = try await spotify.player()
        guard marker == token else { return }
        let delay = state.playing ? min(40,max(7,state.remaining - 55)) : 20
        pollAfter = Date().addingTimeInterval(delay)
        guard state.device?.id == activeDevice else { status = "Waiting for \(playerName)"; return }
        current = state.track
        guard state.playing else { status = "Paused in Spotify"; return }
        guard let song = state.track else { status = "Waiting for a music track"; return }
        let queue: Set<String>?
        if gate.pending != nil && gate.pending?.song.id != song.id && heldQueueOrigin != song.id { queue = try await spotify.queue() } else { queue = nil }
        guard marker == token else { return }
        if let pending = gate.pending, queue?.contains(pending.song.id) == true { heldQueueOrigin = song.id }
        gate.observe(current:song.id,queue:queue,now:Date()); next = gate.pending
        status = "Listening on \(playerName)"
        guard gate.ready(current:song.id,remaining:state.remaining),
              let fix, abs(fix.timestamp.timeIntervalSinceNow) < 75 else { return }
        let drive = context(fix)
        let personal = pins.map { Moment(id:$0.id.uuidString,point:$0.point,song:$0.song,reason:$0.note.isEmpty ? "Your pin at \($0.place)." : $0.note,source:nil,personal:true) }
        let nearby = allStories.compactMap { story -> Moment? in
            guard let song = resolved[story.id] else { return nil }
            return Moment(id:story.id,point:story.point,song:song,reason:story.reason,source:URL(string:story.source),personal:false,areaRadius:story.areaRadius)
        }
        guard let pick = mix.choose(context:drive,current:song.id,remaining:state.remaining,moments:personal+nearby,favorites:favorites) else { return }
        gate.reserve(pick,from:song.id,now:Date()); heldQueueOrigin = song.id
        do { try await spotify.enqueue(pick.song,device:activeDevice) }
        catch {
            guard marker == token else { return }
            if let service = error as? ServiceError, (400..<500).contains(service.status) { gate.rejected() }
            else { mix.record(pick) } // A dropped reply may follow an accepted queue write.
            throw error
        }
        guard marker == token else { return }
        mix.record(pick); next = pick; log.insert(AirLog(pick:pick),at:0)
        if log.count > 60 { log.removeLast() }
    }
    func pair(_ config: CompanionConfig) async {
        do {
            try await ResearchDesk.check(config)
            try Vault.save(JSONEncoder().encode(config),key:"companion")
            companion = config; researchStatus = "PC connected"
        } catch { notice = error.localizedDescription }
    }
    func unpair() {
        live = false; companion = CompanionConfig(); try? Vault.save(nil,key:"companion"); researchStatus = ""
    }
    func merge(_ pack: ResearchPack) {
        var known = Set((seed + prefs.stories).map(\.id))
        let additions = pack.stories.filter { known.insert($0.id).inserted }
        prefs.stories.append(contentsOf:additions); save()
        researchStatus = "\(pack.name) · \(additions.count) new sourced picks"
        if driving, let point { resolveNear(point) }
    }
    func importPack(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 160_000 else { throw RadioError("Choose a trip JSON file smaller than 160 KB.") }
            let pack = try JSONDecoder().decode(ResearchPack.self,from:Data(contentsOf:url)).validated()
            merge(pack)
        } catch { notice = error.localizedDescription }
    }
    func researchTrip(_ places: [String]) async {
        guard !researchBusy else { return }
        researchBusy = true; researchStatus = "Researching places on your PC…"
        defer { researchBusy = false }
        do {
            let config = companion
            let pack = try await ResearchDesk.run(config,places:places,live:false,energy:energy,weather:"Unknown")
            if config == companion { merge(pack) }
        } catch { researchStatus = error.localizedDescription }
    }
    private func requestLiveIfDue() {
        guard live, companion.paired, liveTask == nil, let town, Date().timeIntervalSince(liveAt) >= 1200 else { return }
        let liveKey = [town.label,energy.rawValue,conditions?.label ?? "Unknown"].joined(separator:"|")
        guard lastLiveTown != liveKey else { return }
        let token = marker, config = companion, name = town.label
        liveAt = Date()
        liveTask = Task {
            defer { if marker == token { liveTask = nil } }
            do {
                let pack = try await ResearchDesk.run(config,places:[name],live:true,energy:energy,weather:conditions?.label ?? "Unknown")
                guard !Task.isCancelled, marker == token, live, config == companion, self.town?.label == name else { return }
                let nearby = pack.stories.filter { town.point.distance(to:$0.point) <= 35000 }
                merge(ResearchPack(version:1,name:pack.name,stories:nearby)); lastLiveTown = liveKey
            } catch { if marker == token { researchStatus = "Live research unavailable · \(error.localizedDescription)" } }
        }
    }
}
