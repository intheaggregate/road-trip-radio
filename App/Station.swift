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
    var stories: [Story] = []
    var selectedProgramName: String?
}
struct AirLog: Identifiable {
    let id = UUID()
    let pick: Pick
}

struct SavedRitual: Codable, Identifiable {
    var id = UUID()
    let trigger: CueTrigger
    let place: Point?
    let label: String
    let track: CueTrack

    func matches(_ slot: SoundtrackSlot) -> Bool {
        guard slot.trigger == trigger else { return false }
        if trigger == .highwayOpening { return true }
        guard let place, let point = slot.path.first else { return false }
        return place.distance(to:point) <= max(500,slot.radius)
    }
}

@MainActor
final class Station: ObservableObject {
    let spotify = Spotify()
    let gps = TripGPS()
    let cloud = CloudRadio()
    private let music = MusicMap.shared
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
    private let bundledProgram: DriveProgram?
    private let programsKey = "radio.drivePrograms.v1"
    @Published private var importedPrograms: [DriveProgram] = []
    @Published private(set) var avoidedSuggestions: [CueTrack] =
        UserDefaults.standard.data(forKey:"radio.avoidedSuggestions").flatMap { try? JSONDecoder().decode([CueTrack].self,from:$0) } ?? []
    @Published private(set) var savedRituals: [SavedRitual] =
        UserDefaults.standard.data(forKey:"radio.rituals").flatMap { try? JSONDecoder().decode([SavedRitual].self,from:$0) } ?? []
    private var programDrive = ProgramDrive()
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
    private var catalogAt = Date.distantPast
    private var cloudSet: (scene:CloudDriveScene, songs:[RoadSong], time:Date)?
    private var pcTask: Task<Void,Never>?
    private var town: Town?
    private var blockedUntil = Date.distantPast
    private var pollAfter = Date.distantPast
    private var consecutiveErrors = 0
    private var routeDeviations = 0

    init() {
        let data = UserDefaults.standard.data(forKey:prefKey)
        prefs = data.flatMap { try? JSONDecoder().decode(Preferences.self,from:$0) } ?? Preferences()
        let programData = Bundle.main.url(forResource:"InterstateProgram",withExtension:"json")
            .flatMap { try? Data(contentsOf:$0) }
        bundledProgram = programData.flatMap { try? JSONDecoder().decode(DriveProgram.self,from:$0).validated() }
        let stored = UserDefaults.standard.dictionary(forKey:programsKey) ?? [:]
        importedPrograms = stored.values.compactMap { value in
            guard let data = value as? Data else { return nil }
            return try? JSONDecoder().decode(DriveProgram.self,from:data).validated()
        }
        if let url = Bundle.main.url(forResource:"Landmarks",withExtension:"json"),
           let data = try? Data(contentsOf:url), let pack = try? JSONDecoder().decode(ResearchPack.self,from:data).validated() { seed = pack.stories }
        if let data = Vault.data("companion"), let config = try? JSONDecoder().decode(CompanionConfig.self,from:data) { companion = config }
        connected = spotify.connected
        gps.onFix = { [weak self] location in self?.receive(location) }
        gps.onIssue = { [weak self] message in self?.notice = message }
        cloud.onChange = { [weak self] in
            self?.liveTask?.cancel(); self?.liveTask = nil; self?.cloudSet = nil
        }
    }
    var pins: [Pin] { prefs.pins }
    var rotations: [Rotation] { prefs.rotations }
    var energy: Energy { get { prefs.energy } set { prefs.energy = newValue; save() } }
    var likes: Bool { get { prefs.likes } set { prefs.likes = newValue; save(); reloadLibrary() } }
    var device: String { get { prefs.device } set { prefs.device = newValue; save() } }
    var savedStories: [Story] { prefs.stories }
    var drivePrograms: [DriveProgram] {
        var programs = importedPrograms
        if let bundledProgram, !programs.contains(where:{ $0.name == bundledProgram.name }) { programs.append(bundledProgram) }
        return programs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var selectedDriveProgram: DriveProgram? {
        guard let name = prefs.selectedProgramName else { return nil }
        return importedPrograms.first { $0.name == name } ?? (bundledProgram?.name == name ? bundledProgram : nil)
    }
    func selectProgram(_ name: String?) {
        guard !driving, !starting else { return }
        prefs.selectedProgramName = name
        save()
    }
    func avoidSuggestion(_ track: CueTrack) {
        avoidedSuggestions.removeAll { $0.key == track.key }
        avoidedSuggestions = Array((avoidedSuggestions + [track]).suffix(40))
        persistAvoidedSuggestions()
    }
    func allowSuggestion(_ track: CueTrack) {
        avoidedSuggestions.removeAll { $0.key == track.key }
        persistAvoidedSuggestions()
    }
    private func persistAvoidedSuggestions() {
        if let data = try? JSONEncoder().encode(avoidedSuggestions) {
            UserDefaults.standard.set(data,forKey:"radio.avoidedSuggestions")
        }
    }
    func rememberRitual(_ slot: SoundtrackSlot, enabled: Bool) {
        guard [.departure,.arrival,.bookend,.highwayOpening].contains(slot.trigger) else { return }
        savedRituals.removeAll { $0.matches(slot) }
        if enabled, let fixed = slot.lockedTrack {
            savedRituals.append(SavedRitual(trigger:slot.trigger,place:slot.path.first,label:slot.label,track:fixed))
        }
        persistRituals()
    }
    func forgetRitual(_ id: UUID) {
        savedRituals.removeAll { $0.id == id }
        persistRituals()
    }
    private func persistRituals() {
        if let data = try? JSONEncoder().encode(savedRituals) { UserDefaults.standard.set(data,forKey:"radio.rituals") }
    }
    func applyRituals(to slots: [SoundtrackSlot]) -> [SoundtrackSlot] {
        var updated = slots.map { slot -> SoundtrackSlot in
            var next = slot
            if let ritual = savedRituals.first(where:{ $0.matches(slot) }) { next.lockedTrack = ritual.track }
            return next
        }
        for ritual in savedRituals where ritual.trigger == .bookend {
            for endpoint in slots where endpoint.trigger == .departure || endpoint.trigger == .arrival {
                var bookend = SoundtrackSlot(id:"bookend-" + ritual.id.uuidString.lowercased(),label:ritual.label,
                                             trigger:.bookend,path:endpoint.path,radius:endpoint.radius)
                if ritual.matches(bookend) {
                    bookend.lockedTrack = ritual.track; updated.append(bookend); break
                }
            }
        }
        return updated
    }
    func storeProgram(_ candidate: DriveProgram, replacing: Bool = false) throws {
        guard !driving, !starting else { throw RadioError("End this drive before saving a new soundtrack.") }
        let program = try candidate.validated()
        if !replacing, drivePrograms.contains(where:{ $0.name.caseInsensitiveCompare(program.name) == .orderedSame }) {
            throw RadioError("A soundtrack already has this name. Choose another name to keep both.")
        }
        let data = try JSONEncoder().encode(program)
        var stored = UserDefaults.standard.dictionary(forKey:programsKey) ?? [:]
        stored[program.name] = data
        UserDefaults.standard.set(stored,forKey:programsKey)
        importedPrograms.removeAll { $0.name == program.name }
        importedPrograms.append(program)
        selectProgram(program.name)
        researchStatus = "\(program.name) is ready in Drive."
    }
    func liveMusicStyle(_ drive: DriveContext) -> String? {
        selectedDriveProgram.flatMap { programDrive.musicStyle(in:$0,context:drive) }
    }
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
        let generation = marker
        starting = true; defer { if marker == generation { starting = false } }
        do {
            if gps.manager.authorizationStatus == .notDetermined {
                gps.request()
                while gps.manager.authorizationStatus == .notDetermined {
                    try await Task.sleep(nanoseconds:250_000_000)
                    guard marker == generation else { return }
                }
            }
            guard [.authorizedAlways,.authorizedWhenInUse].contains(gps.manager.authorizationStatus) else {
                throw RadioError("To follow this drive, enable Location While Using in iPhone Settings.")
            }
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
            programDrive = ProgramDrive()
            cancelTripResearch()
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
        libraryTask = nil; liveTask = nil; routeTask = nil; cloudSet = nil
        status = "Drive ended"; next = nil; current = nil; activeDevice = ""; heldQueueOrigin = nil; routeDeviations = 0
    }
    private func receive(_ location: CLLocation) {
        fix = location
        guard driving else { return }
        let p = Point(location.coordinate), token = marker
        if let program = selectedDriveProgram { programDrive.observe(context(location),program:program) }
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
                discover(p, town:found)
                if let fix { requestLiveIfDue(fix) }
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
        let drive = fix.map(context)
        let soundtrack: [CueTrack]
        if let drive, let program = selectedDriveProgram { soundtrack = programDrive.preload(in:program,context:drive) }
        else { soundtrack = [] }
        let pending = soundtrack.filter { resolved[$0.key] == nil && (lookupAfter[$0.key] ?? .distantPast) <= Date() }
        let nearby = allStories.filter { $0.point.distance(to:p) < 30000 && resolved[$0.id] == nil && (lookupAfter[$0.id] ?? .distantPast) <= Date() }
            .sorted { $0.point.distance(to:p) < $1.point.distance(to:p) }
        let target = drive?.energy ?? .cruise
        let choices = (drive.map(cloudMusic) ?? []) + RoadSong.selections
        var knownMusic = Set<String>()
        let music = choices.filter { $0.energy == target && knownMusic.insert($0.key).inserted && resolved[$0.key] == nil && (lookupAfter[$0.key] ?? .distantPast) <= Date() }
        let lookups = pending.map { (key:$0.key,title:$0.title,artist:$0.artist) } +
            nearby.map { (key:$0.id,title:$0.title,artist:$0.artist) } +
            music.map { (key:$0.key,title:$0.title,artist:$0.artist) }
        guard !lookups.isEmpty else { return }
        let token = marker
        lookupTask = Task {
            defer { if marker == token { lookupTask = nil } }
            for entry in lookups.prefix(4) {
                guard !Task.isCancelled, marker == token else { return }
                lookupAfter[entry.key] = Date().addingTimeInterval(300)
                do {
                    let song = try await spotify.resolve(title:entry.title,artist:entry.artist)
                    guard marker == token else { return }
                    if let song { resolved[entry.key] = song }
                } catch let e as ServiceError where e.status == 429 {
                    guard marker == token else { return }
                    blockedUntil = Date().addingTimeInterval(e.wait); lookupAfter[entry.key] = blockedUntil; return
                } catch {
                    if marker == token { lookupAfter[entry.key] = Date().addingTimeInterval(15) }
                    return
                }
            }
        }
    }
    private func context(_ location: CLLocation) -> DriveContext {
        let localHour = Calendar.current.component(.hour,from:Date())
        let currentPoint = Point(location.coordinate)
        let nearbyWeather = weatherPoint.map { currentPoint.distance(to:$0) < 50000 } ?? false
        let weather = nearbyWeather && Date().timeIntervalSince(weatherAt) < 3600 ? conditions : nil
        return DriveContext(point:currentPoint, speed:max(0,location.speed), heading:location.course >= 0 ? location.course:nil,
                            road:route?.road, elapsed:Date().timeIntervalSince(startTime), requested:energy,
                            wet:weather?.wet ?? false,daylight:weather?.day ?? (7..<19).contains(localHour))
    }
    func pulse() {
        guard driving else { return }
        if let fix, abs(fix.timestamp.timeIntervalSinceNow) < 75 {
            requestLiveIfDue(fix)
            resolveNear(Point(fix.coordinate))
        }
        guard tickTask == nil, Date() >= max(blockedUntil,pollAfter), Date().timeIntervalSince(lastPoll) >= 7 else { return }
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
        let cues = selectedDriveProgram.map {
            programDrive.moments(in:$0,context:drive,resolved:resolved,remaining:state.remaining)
        } ?? []
        mix.heardProgramCues(current:song.id,remaining:state.remaining,moments:cues)
        let personal = pins.map { Moment(id:$0.id.uuidString,point:$0.point,song:$0.song,reason:$0.note.isEmpty ? "Your pin at \($0.place)." : $0.note,source:nil,personal:true) }
        let nearby = allStories.compactMap { story -> Moment? in
            guard let song = resolved[story.id] else { return nil }
            return Moment(id:story.id,point:story.point,song:song,reason:story.reason,source:URL(string:story.source),personal:false,areaRadius:story.areaRadius)
        }
        let cloudSongs = cloudMusic(drive)
        let roadSongs = (cloudSongs + RoadSong.selections).compactMap { selection in
            resolved[selection.key].map { Favorite(song:$0,energy:selection.energy) }
        }
        guard var pick = mix.choose(context:drive,current:song.id,remaining:state.remaining,moments:personal+cues+nearby,
                                    favorites:favorites,roadSongs:roadSongs) else { return }
        if !pick.personal, state.remaining > 18, lookupTask != nil, let program = selectedDriveProgram,
           programDrive.waitingForCue(in:program,context:drive,resolved:resolved,remaining:state.remaining,chosenID:pick.momentID) {
            pollAfter = Date().addingTimeInterval(7)
            return
        }
        if pick.momentID == "energy|" + pick.song.id, cloudSongs.contains(where:{ resolved[$0.key]?.id == pick.song.id }) {
            pick.reason += " Suggested by ChatGPT for this stretch."
        }
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
        guard !driving, !starting else { return }
        do {
            try await ResearchDesk.check(config)
            try Vault.save(JSONEncoder().encode(config),key:"companion")
            companion = config; researchStatus = "PC connected"
        } catch { notice = error.localizedDescription }
    }
    func unpair() {
        cancelTripResearch(); companion = CompanionConfig(); try? Vault.save(nil,key:"companion"); researchStatus = ""
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
            let data = try Data(contentsOf:url)
            guard data.count <= 160_000 else { throw RadioError("Choose a trip JSON file smaller than 160 KB.") }
            let contents = try JSONSerialization.jsonObject(with:data) as? [String:Any]
            if contents?["cues"] != nil {
                try storeProgram(JSONDecoder().decode(DriveProgram.self,from:data),replacing:true)
            } else {
                merge(try JSONDecoder().decode(ResearchPack.self,from:data).validated())
            }
        } catch { notice = error.localizedDescription }
    }
    func researchTrip(_ places: [String]) {
        guard !researchBusy, !driving, !starting else { return }
        researchBusy = true; researchStatus = "Researching places on your PC…"
        let config = companion
        pcTask = Task {
            defer { if !Task.isCancelled { researchBusy = false; pcTask = nil } }
            do {
                let pack = try await ResearchDesk.researchTrip(config,places:places,energy:energy)
                if !Task.isCancelled, config == companion { merge(pack) }
            } catch { if !Task.isCancelled { researchStatus = error.localizedDescription } }
        }
    }
    private func cancelTripResearch() {
        if pcTask != nil { pcTask?.cancel(); pcTask = nil; researchBusy = false; researchStatus = "" }
    }
    private func cloudScene(_ drive: DriveContext) -> CloudDriveScene {
        let area = town.flatMap { $0.point.distance(to:drive.point) < 18000 ? $0.label : nil } ?? ""
        let nearby = weatherPoint.map { $0.distance(to:drive.point) < 50000 } ?? false
        let weather = nearby && Date().timeIntervalSince(weatherAt) < 3600 ? conditions?.label : nil
        return CloudDriveScene(town:area,weather:weather ?? "Unknown",energy:drive.energy.rawValue,
                              daylight:drive.daylight,style:liveMusicStyle(drive))
    }
    private func cloudMusic(_ drive: DriveContext) -> [RoadSong] {
        guard let set = cloudSet, cloud.enabled, Date().timeIntervalSince(set.time) < 1800 else { return [] }
        let scene = cloudScene(drive)
        guard scene.energy == set.scene.energy, scene.style == set.scene.style,
              scene.weather == set.scene.weather, scene.daylight == set.scene.daylight else { return [] }
        return set.songs
    }
    private func requestLiveIfDue(_ location: CLLocation) {
        guard driving, cloud.canRequest, liveTask == nil, abs(location.timestamp.timeIntervalSinceNow) < 75 else { return }
        let drive = context(location), token = marker
        let scene = cloudScene(drive)
        if scene.town.isEmpty && Date().timeIntervalSince(startTime) < 15 { return }
        liveTask = Task {
            defer { if marker == token && !Task.isCancelled { liveTask = nil } }
            do {
                let tracks = try await cloud.suggest(scene)
                guard !Task.isCancelled, marker == token, cloud.enabled, let fix,
                      cloudScene(context(fix)) == scene else { return }
                let songs = tracks.map { RoadSong(title:$0.title,artist:$0.artist,energy:drive.energy) }
                cloudSet = (scene,songs,Date())
                resolveNear(Point(fix.coordinate))
            } catch { /* CloudRadio exposes account and usage errors in Settings. */ }
        }
    }
}
