import SwiftUI
import MapKit
import UniformTypeIdentifiers

@main
struct RoadTripRadioApp: App {
    @StateObject private var station = Station()
    var body: some Scene {
        WindowGroup { RadioTabs().environmentObject(station) }
    }
}
private let pine = Color(red:0.10,green:0.32,blue:0.26)
private let darkPine = Color(red:0.065,green:0.21,blue:0.18)
private let paper = Color(red:0.975,green:0.966,blue:0.934)
private let ink = Color(red:0.12,green:0.17,blue:0.16)
private let gold = Color(red:0.98,green:0.78,blue:0.38)
private func editorial(_ size: CGFloat, _ relative: Font.TextStyle = .title) -> Font {
    .custom("DMSerifText-Regular",size:size,relativeTo:relative)
}

struct RadioTabs: View {
    @EnvironmentObject var station: Station
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    var body: some View {
        TabView(selection:$tab) {
            NavigationStack { DriveScreen(tab:$tab) }.tabItem { Label("Drive",systemImage:"steeringwheel") }.tag(0)
            NavigationStack { PlacesScreen() }.tabItem { Label("Places",systemImage:"mappin.and.ellipse") }.tag(1)
            NavigationStack { RotationScreen() }.tabItem { Label("Music",systemImage:"music.note.list") }.tag(2)
            NavigationStack { SettingsScreen() }.tabItem { Label("Settings",systemImage:"slider.horizontal.3") }.tag(3)
        }
        .tint(pine)
        .onChange(of:phase) { _,new in if new == .active { station.pulse() } }
        .alert("Road Trip Radio",isPresented:Binding(get:{ !station.notice.isEmpty },set:{ if !$0 { station.notice = "" } })) {
            Button("OK") { station.notice = "" }
        } message: { Text(station.notice) }
    }
}

private struct DriveScreen: View {
    @EnvironmentObject var station: Station
    @Binding var tab: Int
    @State private var selectingDestination = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                Text("Road Trip Radio").font(editorial(44,.largeTitle)).foregroundStyle(ink).accessibilityAddTraits(.isHeader)
                VStack(alignment:.leading,spacing:15) {
                    HStack {
                        Label(station.driving ? station.status : "Your station",systemImage:station.driving ? "waveform" : "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(gold)
                        Spacer()
                        if let conditions = station.conditions { Text(conditions.label).font(.caption).foregroundStyle(.white) }
                    }
                    if station.driving, let song = station.current {
                        SongRow(song:song,onDark:true)
                    } else {
                        Text(station.route?.name ?? (station.driving ? "On the air" : "Drive now")).font(editorial(36)).foregroundStyle(.white)
                        if !station.place.isEmpty { Label(station.place,systemImage:"location").foregroundStyle(.white.opacity(0.85)) }
                    }
                    if let next = station.next {
                        Divider().overlay(.white.opacity(0.35))
                        Text("Queued on Spotify").font(.caption.weight(.semibold)).foregroundStyle(gold)
                        Text("\(next.song.title) · \(next.song.artist)").bold().foregroundStyle(.white)
                        Text(next.reason).font(.subheadline).foregroundStyle(.white)
                        HStack {
                            Link("Open in Spotify",destination:next.song.link)
                            if let url = next.source { Link("Read source",destination:url) }
                        }.font(.footnote).tint(gold)
                    }
                    Button {
                        if station.driving { station.stop() }
                        else if !station.connected { tab = 3 }
                        else { Task { await station.start() } }
                    } label: {
                        Label(station.driving ? "End drive" : (station.connected ? (station.starting ? "Starting…" : "Start drive") : "Connect Spotify"),
                              systemImage:station.driving ? "stop.fill" : "play.fill")
                        .frame(maxWidth:.infinity).padding(.vertical,5)
                    }.buttonStyle(.borderedProminent).tint(gold).foregroundStyle(darkPine).disabled(station.starting)
                }.padding(22).background(darkPine,in:RoundedRectangle(cornerRadius:22))
                VStack(alignment:.leading,spacing:10) {
                    HStack { Text("Route").font(editorial(26)); Spacer()
                        if station.route != nil { Button("Clear") { station.clearRoute() }.font(.subheadline) }
                    }
                    if let route = station.route {
                        Map {
                            MapPolyline(route.line).stroke(pine,lineWidth:5)
                            Marker(route.name,coordinate:route.destination.placemark.coordinate)
                            UserAnnotation()
                        }.frame(height:160).clipShape(RoundedRectangle(cornerRadius:12))
                        Text("\(route.name) · \(distance(route.road.length)) · \(duration(route.road.duration))").font(.subheadline)
                        let highlights = station.highlights
                        if station.lookingAlongRoute { HStack { ProgressView(); Text("Finding music along the route…").font(.footnote) } }
                        else if highlights.isEmpty { Text("Local picks will update as you drive. You can also add a song pin for this route.").font(.footnote) }
                        ForEach(highlights.indices,id:\.self) { i in
                            Label("\(highlights[i].0) · \(highlights[i].1)",systemImage:"music.note").font(.subheadline)
                        }
                    }
                    Button {
                        station.gps.request(); selectingDestination = true
                    } label: { Label(station.routeBusy ? "Finding route…" : (station.route == nil ? "Plan a drive" : "Change destination"),systemImage:"map") }
                    .disabled(station.routeBusy)
                }
                if !station.drivePrograms.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Soundtrack").font(editorial(26))
                        Picker("Route soundtrack",selection:Binding(get:{ station.selectedDriveProgram?.name ?? "" },set:{ station.selectProgram($0.isEmpty ? nil : $0) })) {
                            Text("Everyday station").tag("")
                            ForEach(station.drivePrograms,id:\.name) { program in Text(program.name).tag(program.name) }
                        }
                        .pickerStyle(.menu).labelsHidden().disabled(station.driving || station.starting)
                        if let program = station.selectedDriveProgram ?? station.drivePrograms.first {
                            NavigationLink {
                                DriveProgramPreview(program:program)
                            } label: {
                                Label("Preview " + program.name,systemImage:"music.note.list").font(.subheadline)
                            }
                        }
                    }
                }
                VStack(alignment:.leading) {
                    Text("Energy").font(editorial(26))
                    Picker("Energy",selection:Binding(get:{station.energy},set:{station.energy = $0})) {
                        ForEach(Energy.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if !station.log.isEmpty {
                    Text("This drive").font(editorial(26))
                    ForEach(station.log) { item in
                        VStack(alignment:.leading,spacing:5) {
                            SongRow(song:item.pick.song)
                            Text(item.pick.reason).font(.footnote)
                            if let url = item.pick.source { Link("Source",destination:url).font(.footnote) }
                        }
                        Divider()
                    }
                }
            }.padding(20).frame(maxWidth:680,alignment:.leading)
        }.frame(maxWidth:.infinity).background(paper).foregroundStyle(ink)
        .sheet(isPresented:$selectingDestination) { PlaceSearch(title:"Destination",near:station.point) { item in Task { await station.setRoute(item) } } }
    }
    private func distance(_ metres: Double) -> String { Measurement(value:metres,unit:UnitLength.meters).formatted(.measurement(width:.abbreviated,usage:.road)) }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(1,minutes)) min"
    }
}

private struct DriveProgramPreview: View {
    let program: DriveProgram
    @EnvironmentObject var station: Station
    var body: some View {
        List {
            Section {
                if station.selectedDriveProgram?.name == program.name {
                    Label("Selected for this drive",systemImage:"checkmark.circle.fill")
                } else {
                    Button("Use this soundtrack") { station.selectProgram(program.name) }
                        .disabled(station.driving || station.starting)
                }
            } footer: {
                Text("The DJ follows your location and queues each cue at a song break. Personal pins take priority.")
            }
            ForEach(program.cues,id:\.id) { cue in
                Section {
                    ForEach(cue.tracks,id:\.key) { track in
                        VStack(alignment:.leading,spacing:2) {
                            Text(track.title).font(.headline)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(cue.label) } footer: { Text(cue.reason) }
            }
        }.navigationTitle(program.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct SongRow: View {
    let song: Song
    var onDark = false
    var body: some View {
        HStack(spacing:12) {
            AsyncImage(url:song.artwork) { image in image.resizable().scaledToFit() } placeholder: {
                Image(systemName:"music.note").foregroundStyle(onDark ? gold : pine)
            }.frame(width:50,height:50)
            VStack(alignment:.leading,spacing:2) {
                Text(song.title).font(.headline).foregroundStyle(onDark ? .white : .primary)
                Text(song.artist).font(.subheadline).foregroundStyle(onDark ? .white.opacity(0.82) : .secondary)
            }
            Spacer(minLength:4)
            Link(destination:song.link) {
                HStack(spacing:3) {
                    if UIImage(named:"SpotifyIcon") != nil { Image("SpotifyIcon").resizable().scaledToFit().frame(width:17,height:17) }
                    Text("Spotify").font(.caption.bold())
                }
            }.foregroundStyle(onDark ? gold : pine).accessibilityLabel("Open \(song.title) in Spotify")
        }.fixedSize(horizontal:false,vertical:true)
    }
}

struct PlaceSearch: View {
    let title: String
    let near: Point?
    let pick: (MKMapItem)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var message = ""
    @State private var found: [MKMapItem] = []
    @State private var searching = false
    private func search() async {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        searching = true; defer { searching = false }
        do { found = try await findPlaces(query,near:near); message = found.isEmpty ? "No places found." : "" }
        catch { message = error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            List {
                HStack {
                    TextField("City, address, or landmark",text:$query).submitLabel(.search).onSubmit { Task { await search() } }
                    Button("Search") { Task { await search() } }.disabled(searching || query.isEmpty)
                }
                if searching { ProgressView() }
                if !message.isEmpty { Text(message) }
                ForEach(found.indices,id:\.self) { i in
                    Button {
                        pick(found[i]); dismiss()
                    } label: {
                        VStack(alignment:.leading) { Text(found[i].name ?? "Place"); Text(found[i].placemark.title ?? "").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.navigationTitle(title).toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct PlacesScreen: View {
    @EnvironmentObject var station: Station
    @State private var addPin = false
    @State private var file = false
    @State private var research = false
    var body: some View {
        List {
            Section("My song pins") {
                Button { station.gps.request(); addPin = true } label:{ Label("Pin a song",systemImage:"mappin.and.ellipse") }
                ForEach(station.pins) { pin in
                    VStack(alignment:.leading,spacing:5) {
                        Text(pin.place).font(.headline); SongRow(song:pin.song)
                        if !pin.note.isEmpty { Text(pin.note).font(.footnote) }
                    }.swipeActions { Button("Delete",role:.destructive) { station.removePin(pin.id) } }
                }
            }
            Section("Trip research") {
                Button { file = true } label:{ Label("Import trip file",systemImage:"square.and.arrow.down") }
                if station.companion.paired {
                    Button { research = true } label:{ Label("Research a drive on my PC",systemImage:"desktopcomputer") }.disabled(station.researchBusy)
                }
                if !station.researchStatus.isEmpty { Text(station.researchStatus).font(.footnote) }
                ForEach(station.savedStories) { story in
                    StoryRow(story:story).swipeActions { Button("Remove",role:.destructive) { station.removeStory(story.id) } }
                }
            }
            Section("Roadside recordings") {
                ForEach(station.allStories.filter { !station.savedStories.map(\.id).contains($0.id) },id:\.id) { StoryRow(story:$0) }
            }
        }.navigationTitle("Places")
        .sheet(isPresented:$addPin) { PinEditor() }
        .sheet(isPresented:$research) { ResearchEditor() }
        .fileImporter(isPresented:$file,allowedContentTypes:[.json]) { result in
            do { station.importPack(try result.get()) } catch { station.notice = error.localizedDescription }
        }
    }
}
private struct StoryRow: View {
    let story: Story
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            Text(story.place).font(.headline); Text("\(story.title) · \(story.artist)").font(.subheadline)
            Text(story.reason).font(.footnote).foregroundStyle(.secondary)
            if let source = URL(string:story.source) { Link("Read source",destination:source).font(.caption) }
        }.padding(.vertical,3)
    }
}
private struct ResearchEditor: View {
    @EnvironmentObject var station: Station
    @Environment(\.dismiss) private var dismiss
    @State private var names = ""
    var body: some View {
        NavigationStack { Form {
            Section("Cities or landmarks in driving order") { TextField("One place per line",text:$names,axis:.vertical).lineLimit(3...6) }
            Button("Research with my ChatGPT allowance") {
                let places = names.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard (1...6).contains(places.count) else { station.notice = "Enter one to six places."; return }
                Task { await station.researchTrip(places) }; dismiss()
            }.disabled(names.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }.navigationTitle("Trip research").toolbar { Button("Close") { dismiss() } }
        .onAppear { names = [station.place,station.route?.name ?? ""].filter { !$0.isEmpty }.joined(separator:"\n") } }
    }
}
private struct PinEditor: View {
    @EnvironmentObject var station: Station
    @Environment(\.dismiss) private var dismiss
    @State private var point: Point?
    @State private var place = ""
    @State private var note = ""
    @State private var query = ""
    @State private var message = ""
    @State private var position: MapCameraPosition = .automatic
    @State private var places = false
    @State private var searching = false
    @State private var songs: [Song] = []
    @State private var selected: Song?
    func center(_ p: Point) { position = .region(MKCoordinateRegion(center:p.coordinate,latitudinalMeters:2400,longitudinalMeters:2400)) }
    func search() async {
        guard !query.isEmpty else { return }; searching = true; defer { searching = false }
        do { songs = try await station.spotify.search(query); message = songs.isEmpty ? "No tracks found." : "" }
        catch { message = error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Find a place") { places = true }
                    MapReader { proxy in
                        Map(position:$position) { if let point { Marker(place.isEmpty ? "Song pin" : place,coordinate:point.coordinate) } }
                            .frame(height:170).onTapGesture(coordinateSpace:.local) { tap in
                                if let coord = proxy.convert(tap,from:.local) { point = Point(coord) }
                            }
                    }
                    TextField("Name this spot",text:$place)
                } header: { Text("Place") } footer: { Text("Search for a landmark or tap the map to drop your pin.") }
                Section("Song") {
                    HStack {
                        TextField("Title or artist",text:$query).submitLabel(.search).onSubmit { Task { await search() } }
                        Button("Search") { Task { await search() } }.disabled(query.isEmpty || searching)
                    }
                    if searching { ProgressView() }
                    if !message.isEmpty { Text(message).font(.footnote) }
                    ForEach(songs) { song in
                        Button { selected = song } label: {
                            HStack { VStack(alignment:.leading) { Text(song.title); Text(song.artist).font(.caption) }; Spacer(); if song.id == selected?.id { Image(systemName:"checkmark") } }
                        }
                    }
                }
                Section("Personal note") { TextField("Why this song belongs here",text:$note,axis:.vertical) }
            }.navigationTitle("Pin a song").toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Save") {
                    if let point, let selected { station.add(Pin(place:place,point:point,song:selected,note:note)); dismiss() }
                }.disabled(point == nil || selected == nil || place.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
            }.onAppear { if point == nil, let p = station.point { center(p) } }
            .sheet(isPresented:$places) { PlaceSearch(title:"Find a place",near:station.point) { item in
                let p = Point(item.placemark.coordinate); point = p; place = item.name ?? ""; center(p)
            } }
        }
    }
}
private struct RotationScreen: View {
    @EnvironmentObject var station: Station
    var body: some View {
        Form {
            Section {
                Toggle("Liked Songs",isOn:Binding(get:{station.likes},set:{station.likes = $0}))
                ForEach(station.lists) { list in
                    Picker(list.name,selection:Binding(get:{station.rotations.first { $0.id == list.id }?.energy.rawValue ?? "Off"},set:{station.setRotation(list,Energy(rawValue:$0))})) {
                        Text("Off").tag("Off")
                        ForEach(Energy.allCases) { Text($0 == .automatic ? "Any energy" : $0.rawValue).tag($0.rawValue) }
                    }
                }
                if station.connected { Button("Refresh playlists") { Task { await station.refreshChoices() } } }
            } header: { Text("Familiar rotation") } footer: { Text("Give your playlists an energy to shape the mix as daylight, weather, and the drive change.") }
            if !station.libraryStatus.isEmpty { Text(station.libraryStatus).font(.footnote) }
        }.navigationTitle("Music")
        .task { if station.connected && station.lists.isEmpty { await station.refreshChoices() } }
    }
}
private struct SettingsScreen: View {
    @EnvironmentObject var station: Station
    @State private var client = ""
    @State private var address = ""
    @State private var key = ""
    @State private var confirming = false
    @State private var checking = false
    var body: some View {
        Form {
            Section("Spotify Premium") {
                if station.connected {
                    Label("Connected",systemImage:"checkmark.circle.fill")
                    Picker("Play on",selection:Binding(get:{station.device},set:{station.device = $0})) {
                        Text("Active phone").tag("")
                        ForEach(station.devices) { Text($0.name).tag($0.id) }
                    }.disabled(station.driving)
                    Button("Find devices") { Task { await station.refreshChoices() } }
                    Link("Open Spotify",destination:URL(string:"https://open.spotify.com/")!)
                    Button("Disconnect Spotify",role:.destructive) { confirming = true }
                } else {
                    Link("Register a personal Spotify app",destination:URL(string:"https://developer.spotify.com/dashboard")!)
                    Text("Register this callback in the Spotify dashboard and paste your Client ID below.").font(.footnote)
                    Text(Spotify.callback).font(.system(.footnote,design:.monospaced)).textSelection(.enabled)
                    TextField("Spotify Client ID",text:$client).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(station.busy ? "Connecting…" : "Connect Spotify") { Task { await station.connect(client.trimmingCharacters(in:.whitespacesAndNewlines)) } }.disabled(station.busy || client.isEmpty)
                }
            }
            Section {
                if station.companion.paired {
                    Label("PC paired",systemImage:"checkmark.circle"); Text(station.companion.address).font(.footnote)
                    Toggle("Live picks during drives",isOn:Binding(get:{station.live},set:{station.live = $0}))
                    Button("Unpair PC") { station.unpair(); key = "" }
                } else {
                    TextField("Private HTTPS address",text:$address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Pairing code",text:$key)
                    Button(checking ? "Checking…" : "Pair Windows PC") {
                        checking = true
                        Task { await station.pair(CompanionConfig(address:address,key:key)); checking = false }
                    }.disabled(checking || address.isEmpty || key.isEmpty)
                }
            } header: { Text("Optional ChatGPT research") }
              footer: { Text("Your PC uses its signed-in Codex allowance. Live picks send the town, weather, and energy up to once every 20 minutes. You can also import a trip file in Places.") }
            Section("Sources") {
                Link("MusicBrainz",destination:URL(string:"https://musicbrainz.org")!)
                Link("Weather by Open-Meteo · CC BY 4.0",destination:URL(string:"https://open-meteo.com/")!)
                Link("Setup and privacy",destination:URL(string:"https://github.com/intheaggregate/road-trip-radio#readme")!)
            }
        }.navigationTitle("Settings")
        .confirmationDialog("Disconnect and remove this account’s song pins and playlist choices?",isPresented:$confirming,titleVisibility:.visible) {
            Button("Disconnect and clear",role:.destructive) { station.disconnect() }
        }
    }
}
