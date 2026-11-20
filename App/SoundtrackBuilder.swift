import MapKit
import SwiftUI

private enum BuilderSearch: String, Identifiable {
    case start = "Starting point", end = "Destination", via = "Drive through", landmark = "Find a landmark"
    var id: String { rawValue }
}

@MainActor struct SoundtrackBuilder: View {
    @ObservedObject var cloud: CloudRadio
    @EnvironmentObject private var station: Station
    @Environment(\.dismiss) private var dismiss
    @AppStorage("radio.tasteBrief.v1") private var taste = ""
    @State private var tripNote = ""
    @State private var start: MKMapItem?
    @State private var finish: MKMapItem?
    @State private var via: MKMapItem?
    @State private var search: BuilderSearch?
    @State private var route: BuilderRoute?
    @State private var name = ""
    @State private var slots: [SoundtrackSlot] = []
    @State private var drafts: [String:DraftCue] = [:]
    @State private var rejected: [String:[CueTrack]] = [:]
    @State private var editor: SoundtrackSlot?
    @State private var placingPin = false
    @State private var changingRoute = false
    @State private var message = ""
    @State private var activity = ""
    @State private var task: Task<Void,Never>?
    @State private var generation = UUID()

    private var working: Bool { !activity.isEmpty }
    private var brief: String {
        [taste,tripNote.isEmpty ? "" : "For this drive: " + tripNote].filter { !$0.isEmpty }.joined(separator:"\n")
    }
    private func choices(_ slot: SoundtrackSlot) -> [CueTrack] {
        SoundtrackGenerator.tracks(for:slot,draft:drafts[slot.id],rejected:station.avoidedSuggestions + (rejected[slot.id] ?? []))
    }
    private func finalProgram() throws -> DriveProgram {
        let cleaned = slots.compactMap { slot -> DraftCue? in
            guard var draft = drafts[slot.id] else { return nil }
            draft.tracks = choices(slot)
            return draft
        }
        return try SoundtrackGenerator.program(name:name.trimmingCharacters(in:.whitespacesAndNewlines),
                                               slots:slots,drafts:cleaned,rejected:station.avoidedSuggestions)
    }

    var body: some View {
        Form {
            if let route {
                mappedRoute(route).disabled(working)
            } else { routeFields.disabled(working) }
            preferences.disabled(working)
            if let route {
                chapterActions(route).disabled(working)
                let cues = (try? finalProgram().cues) ?? []
                ForEach(slots) { slot in
                    chapter(slot,cue:cues.first { $0.id == slot.id }).disabled(working)
                }
                CatalogCheck(tracks:cues.flatMap(\.tracks)).disabled(working)
                Section {
                    TextField("Name this soundtrack",text:$name)
                    Button("Save and use \(cues.count) \(cues.count == 1 ? "chapter" : "chapters")") { save() }
                        .disabled(cues.isEmpty || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.disabled(working)
            } else { buildActions.disabled(working) }
            if working {
                HStack { ProgressView(); Text(activity); Spacer(); Button("Cancel") { cancel() } }
            }
            if !message.isEmpty { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("Create a soundtrack").navigationBarTitleDisplayMode(.inline)
        .sheet(item:$search) { target in
            PlaceSearch(title:target.rawValue,near:searchCenter(target)) { item in
                switch target {
                case .start: start = item
                case .end: finish = item
                case .via: via = item
                case .landmark: addLandmark(Point(item.placemark.coordinate),label:item.name ?? "Landmark")
                }
            }
        }
        .sheet(item:$editor) { slot in
            SlotEditor(slot:slot,remembered:station.savedRituals.contains(where:{ $0.matches(slot) })) { updated,remember in
                if let i = slots.firstIndex(where:{ $0.id == updated.id }) { slots[i] = updated }
                station.rememberRitual(updated,enabled:remember)
            }
        }
        .sheet(isPresented:$placingPin) {
            if let route { RoutePinPicker(route:route,save:addLandmark) }
        }
        .confirmationDialog("Choose a different route?",isPresented:$changingRoute) {
            Button("Clear this draft and change route",role:.destructive) {
                route = nil; slots = []; drafts = [:]; rejected = [:]; message = ""
            }
        }
        .onDisappear { cancel() }
    }

    private var routeFields: some View {
        Section {
            placeButton("From",item:start,target:.start)
            placeButton("To",item:finish,target:.end)
            if via != nil {
                placeButton("Via",item:via,target:.via)
                Button("Remove stop") { via = nil }
            } else { Button("Add a stop") { search = .via } }
        } header: { Text("Drive") } footer: {
            Text("Apple Maps supplies the driving route. Open-Meteo receives rounded route samples to identify changes in terrain.")
        }
    }
    private func placeButton(_ title: String, item: MKMapItem?, target: BuilderSearch) -> some View {
        Button { search = target } label: {
            HStack { Text(title); Spacer(); Text(item?.name ?? "Choose place").foregroundStyle(.secondary) }
        }.accessibilityIdentifier(target == .start ? "Choose starting point" : target.rawValue)
    }
    private func searchCenter(_ target: BuilderSearch) -> Point? {
        if target == .landmark, let road = route?.road { return road.point(atDistance:road.length / 2) }
        return nil
    }
    private var preferences: some View {
        Section {
            TextField("Music you love, artists, or sounds you avoid",text:$taste,axis:.vertical).lineLimit(1...5)
            TextField("Anything different for this drive?",text:$tripNote,axis:.vertical).lineLimit(1...4)
            if !station.avoidedSuggestions.isEmpty {
                DisclosureGroup("Songs to avoid on future drives") {
                    ForEach(station.avoidedSuggestions,id:\.key) { song in
                        Button { station.allowSuggestion(song) } label: {
                            HStack { Text(song.title + " · " + song.artist); Spacer(); Image(systemName:"minus.circle") }
                        }.accessibilityLabel("Allow " + song.title + " again")
                    }
                }
            }
        } header: { Text("Your music") } footer: {
            Text("Your taste is remembered on this iPhone. The second note applies to this drive.")
        }
    }
    private var buildActions: some View {
        Section {
            if cloud.canGenerateSoundtrack {
                Button("Generate soundtrack with ChatGPT") { mapRoute(generate:true) }
                    .disabled(start == nil || finish == nil)
                Button("Map route and set exact songs first") { mapRoute(generate:false) }
                    .disabled(start == nil || finish == nil)
            } else {
                Button("Map this drive") { mapRoute(generate:false) }.disabled(start == nil || finish == nil)
                cloudConnection
            }
        } footer: { consent }
    }
    private var consent: some View {
        Text("Generating sends route chapter names, your music notes and previous song feedback to ChatGPT using your plan. The phone keeps the route geometry and fixed song requests.")
    }
    private var cloudConnection: some View {
        NavigationLink("Connect ChatGPT for suggestions") {
            Form { CloudRadioSettings(cloud:cloud) }.navigationTitle("ChatGPT")
        }
    }
    private func mappedRoute(_ route: BuilderRoute) -> some View {
        Section {
            Map { MapPolyline(route.line).stroke(Color.accentColor,lineWidth:4) }
                .frame(height:155).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityLabel("Mapped driving route")
            Text("\(route.name) · \(max(1,Int(route.road.duration / 60))) min")
            Button("Change route") { changingRoute = true }
        }
    }
    private func chapterActions(_ route: BuilderRoute) -> some View {
        Section {
            if cloud.canGenerateSoundtrack {
                let open = slots.filter { $0.lockedTrack == nil && choices($0).isEmpty && $0.reference == nil }
                if !open.isEmpty {
                    Button("Suggest songs for open chapters") {
                        run("Finding songs…") { try await generate(open) }
                    }
                }
            } else { cloudConnection }
            Menu("Add a musical moment") {
                Button("Find a landmark") { search = .landmark }
                Button("Pin a spot on the map") { placingPin = true }
                Button("Song for either end at the starting city") { addBookend(from:.departure) }
                Button("Song for either end at the destination") { addBookend(from:.arrival) }
            }
            Button("Find local music connections") { research(route) }
        } header: { Text("Route chapters") } footer: { consent }
    }

    private func chapter(_ slot: SoundtrackSlot, cue: DriveCue?) -> some View {
        Section {
            if let cue {
                ForEach(cue.tracks,id:\.key) { track in
                    HStack {
                        VStack(alignment:.leading) { Text(track.title); Text(track.artist).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if slot.lockedTrack != nil { Image(systemName:"lock.fill").accessibilityLabel("Fixed request") }
                        else {
                            Menu {
                                Button("Skip for this chapter") { reject(track,in:slot,standing:false) }
                                Button("Avoid on future drives") { reject(track,in:slot,standing:true) }
                            } label: { Image(systemName:"ellipsis.circle") }.accessibilityLabel("Options for " + track.title)
                        }
                    }
                }
                if let source = cue.source.flatMap(URL.init(string:)) { Link("Music connection",destination:source) }
            }
            if !slot.instruction.isEmpty { Text(slot.instruction).font(.footnote).foregroundStyle(.secondary) }
            Button("Set a song or describe the sound") { editor = slot }
            if cloud.canGenerateSoundtrack && slot.lockedTrack == nil && slot.reference == nil {
                Button(cue == nil ? "Suggest songs here" : "Try different songs here") {
                    run("Finding songs for this chapter…") { try await generate([slot]) }
                }
            }
            Button("Remove chapter",role:.destructive) { slots.removeAll { $0.id == slot.id }; drafts[slot.id] = nil }
        } header: { Text(slot.label) } footer: {
            if let cue { Text(cue.reason) }
            else if slot.trigger == .nearby { Text("Plays only if you actually pass within \(Int(slot.radius)) m of the pin.") }
            else if slot.trigger == .approach { Text("Follows the mapped approach in this direction.") }
        }
    }
    private func mapRoute(generate wantsDraft: Bool) {
        guard let start, let finish else { return }
        run("Mapping the drive…") {
            let mapped = try await BuilderRoute.make(from:start,via:via,to:finish)
            try Task.checkCancellation()
            route = mapped; slots = station.applyRituals(to:mapped.slots); sortSlots()
            var i = 1, proposed = mapped.name
            while station.drivePrograms.contains(where:{ $0.name == proposed }) {
                i += 1; proposed = mapped.name + " (\(i))"
            }
            name = proposed
            if wantsDraft {
                activity = "Finding songs for the route…"
                let open = slots.filter { $0.lockedTrack == nil }
                if !open.isEmpty { try await generate(open) }
            }
        }
    }
    private func sortSlots() {
        if let route { slots.sort { route.position($0) < route.position($1) } }
    }
    private func addLandmark(_ point: Point, label: String) {
        guard let route else { return }
        let slot = route.landmark(point,name:label)
        slots.append(slot); sortSlots()
        message = slot.trigger == .nearby
            ? "\(slot.label) is a conditional stop. It will play only if you pass within 800 m."
            : "\(slot.label) is anchored to your approach on the mapped road."
    }
    private func addBookend(from trigger: CueTrigger) {
        guard let base = route?.slots.first(where:{ $0.trigger == trigger }) else { return }
        let item = trigger == .departure ? start : finish
        let city = item?.placemark.locality ?? item?.placemark.subAdministrativeArea ?? "this city"
        let slot = SoundtrackSlot(id:"bookend-" + UUID().uuidString.lowercased(),label:"At either end in " + String(city.prefix(125)),
                                  trigger:.bookend,path:base.path,radius:base.radius)
        slots.append(slot); sortSlots(); editor = slot
    }
    private func research(_ route: BuilderRoute) {
        run("Checking music connections along the road…") {
            let found = await RouteMusicResearch.stops(on:route.road,known:station.allStories)
            try Task.checkCancellation()
            let new = found.filter { candidate in !slots.contains(where:{ $0.id == candidate.id }) }
            for slot in new {
                guard let story = slot.reference else { continue }
                slots.append(slot)
                drafts[slot.id] = DraftCue(slotID:slot.id,tracks:[CueTrack(title:story.title,artist:story.artist)])
            }
            sortSlots()
            message = new.isEmpty ? "No new documented music connections found along this route." : "Added \(new.count) documented music connections."
        }
    }
    private func reject(_ track: CueTrack, in slot: SoundtrackSlot, standing: Bool) {
        if standing { station.avoidSuggestion(track) }
        else { rejected[slot.id] = Array(((rejected[slot.id] ?? []) + [track]).suffix(24)) }
    }
    private func generate(_ targets: [SoundtrackSlot]) async throws {
        let ids = Set(targets.map(\.id))
        // Locked titles and Spotify metadata never enter the planning prompt.
        let otherPicks = slots.filter { !ids.contains($0.id) && $0.lockedTrack == nil && $0.reference == nil }.flatMap(choices)
        let locked = slots.compactMap(\.lockedTrack)
        let fixedKeys = Set(locked.map(\.key))
        let oldPicks = targets.count == 1 ? (drafts[targets[0].id]?.tracks ?? []) : []
        let theseSkips = targets.count == 1 ? (rejected[targets[0].id] ?? []) : []
        let avoid = (otherPicks + station.avoidedSuggestions + oldPicks + theseSkips).filter { !fixedKeys.contains($0.key) }
        let result = try await cloud.generateSoundtrack(slots:targets,taste:brief,rejected:avoid)
        try Task.checkCancellation()
        var replaced = 0
        var taken = avoid + locked
        for slot in targets where slot.lockedTrack == nil {
            guard var draft = result.first(where:{ $0.slotID == slot.id }) else { continue }
            let tracks = SoundtrackGenerator.tracks(for:slot,draft:draft,rejected:taken + (rejected[slot.id] ?? []))
            if !tracks.isEmpty {
                draft.tracks = tracks; drafts[slot.id] = draft; taken += tracks; replaced += 1
                if targets.count == 1 { rejected[slot.id] = Array(((rejected[slot.id] ?? []) + oldPicks).suffix(24)) }
            }
        }
        if replaced == 0 { message = "No new matches for these chapters. Try a more specific music note or set a song." }
        else if replaced < targets.count { message = "Prepared \(replaced) of \(targets.count) chapters. You can fill the remaining ones individually." }
        else { message = "" }
    }
    private func save() {
        do { try station.storeProgram(finalProgram()); dismiss() }
        catch { message = error.localizedDescription }
    }
    private func run(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        let id = UUID(); generation = id; activity = label; message = ""
        task = Task {
            defer { if id == generation { activity = ""; task = nil } }
            do { try await action() }
            catch { if !Task.isCancelled && generation == id { message = error.localizedDescription } }
        }
    }
    private func cancel() {
        generation = UUID(); task?.cancel(); task = nil; activity = ""
    }
}

private struct SlotEditor: View {
    @Environment(\.dismiss) private var dismiss
    let slot: SoundtrackSlot
    let save: (SoundtrackSlot,Bool)->Void
    @State private var title: String
    @State private var artist: String
    @State private var note: String
    @State private var remember: Bool
    init(slot: SoundtrackSlot, remembered: Bool, save: @escaping (SoundtrackSlot,Bool)->Void) {
        self.slot = slot; self.save = save
        _title = State(initialValue:slot.lockedTrack?.title ?? ""); _artist = State(initialValue:slot.lockedTrack?.artist ?? "")
        _note = State(initialValue:slot.instruction)
        _remember = State(initialValue:remembered)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("This chapter") { Text(slot.label) }
                Section("Exact song") {
                    TextField("Song title",text:$title); TextField("Artist",text:$artist)
                    if [.highwayOpening,.arrival,.departure,.bookend].contains(slot.trigger) {
                        Toggle(slot.trigger == .highwayOpening ? "Use as my highway opener on future drives" : "Remember this ritual here on future drives",isOn:$remember)
                            .disabled(title.isEmpty || artist.isEmpty)
                    }
                }
                Section("Musical direction") {
                    TextField("What should this stretch feel like?",text:$note,axis:.vertical).lineLimit(2...5)
                }
            }.navigationTitle("Shape this moment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Done") {
                        var result = slot
                        let song = title.trimmingCharacters(in:.whitespacesAndNewlines)
                        result.lockedTrack = song.isEmpty ? nil : CueTrack(title:song,artist:artist.trimmingCharacters(in:.whitespacesAndNewlines))
                        result.instruction = note.trimmingCharacters(in:.whitespacesAndNewlines)
                        save(result,remember && result.lockedTrack != nil); dismiss()
                    }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != artist.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ||
                               title.count > 160 || artist.count > 160 || note.count > 450)
                }
            }
        }
    }
}

private struct RoutePinPicker: View {
    @Environment(\.dismiss) private var dismiss
    let route: BuilderRoute
    let save: (Point,String)->Void
    @State private var selected: Point?
    @State private var label = ""
    @State private var camera: MapCameraPosition = .automatic
    var body: some View {
        NavigationStack {
            VStack(alignment:.leading) {
                MapReader { proxy in
                    Map(position:$camera) {
                        MapPolyline(route.line).stroke(Color.accentColor,lineWidth:4)
                        if let p = selected { Marker("Musical moment",coordinate:p.coordinate) }
                    }.onTapGesture { tap in
                        if let coordinate = proxy.convert(tap,from:.local) { selected = Point(coordinate) }
                    }
                }
                Text("Zoom in and tap the spot where the music should land.").font(.footnote)
                TextField("Name this moment",text:$label).textFieldStyle(.roundedBorder)
            }.padding().navigationTitle("Pin a moment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Add") {
                        if let selected { save(selected,label.trimmingCharacters(in:.whitespacesAndNewlines)); dismiss() }
                    }.disabled(selected == nil || label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
