import SwiftUI

/// Match proposed titles locally before saving. A failed service request leaves
/// that title unchecked. Only a successful, empty search counts as a missed match.
@MainActor struct CatalogCheck: View {
    let tracks: [CueTrack]
    @EnvironmentObject private var station: Station
    @State private var matches = [String:Bool]()
    @State private var task: Task<Void,Never>?
    @State private var generation = UUID()
    @State private var retryAt: Date?
    @State private var message = ""
    private let batchSize = 12

    private var unique: [CueTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.key).inserted }
    }
    private var missing: [CueTrack] { unique.filter { matches[$0.key] == false } }
    private var buttonLabel: String {
        if !unique.isEmpty && matches.count == unique.count { return "Recheck Spotify matches" }
        if !matches.isEmpty { return "Continue checking Spotify" }
        return "Check Spotify matches"
    }
    var body: some View {
        if station.connected && !unique.isEmpty {
            Section {
                if task != nil {
                    HStack {
                        ProgressView()
                        Text("Checking Spotify…")
                        Spacer()
                        Button("Cancel") { cancel() }
                    }
                } else {
                    Button(buttonLabel) { check() }.disabled(station.driving || station.starting)
                }
                if !matches.isEmpty {
                    Text("\(matches.values.filter { $0 }.count) matched · \(matches.count) of \(unique.count) checked")
                        .font(.footnote)
                }
                if !message.isEmpty { Text(message).font(.footnote) }
                ForEach(missing,id:\.key) { track in
                    Label("No match for \(track.title) · \(track.artist)",systemImage:"magnifyingglass")
                        .font(.footnote)
                }
            } header: { Text("Spotify availability") }
            .onChange(of:tracks) { _,_ in
                cancel()
                let keep = Set(unique.map(\.key))
                matches = matches.filter { keep.contains($0.key) }
                message = ""
            }
            .onChange(of:station.driving) { _,active in if active { cancel() } }
            .onDisappear { cancel(); matches = [:]; message = "" }
        }
    }
    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
    private func check() {
        guard task == nil, station.connected, !station.driving, !station.starting else { return }
        if let date = retryAt, Date() < date {
            message = "Spotify asked for a pause. Try again after \(date.formatted(date:.omitted,time:.standard))."
            return
        }
        retryAt = nil
        if matches.count == unique.count { matches = [:] }
        let batch = Array(unique.filter { matches[$0.key] == nil }.prefix(batchSize))
        guard !batch.isEmpty else { return }
        message = ""
        let id = UUID()
        generation = id
        task = Task {
            defer { if generation == id { task = nil } }
            do {
                for (index,track) in batch.enumerated() {
                    try Task.checkCancellation()
                    if index > 0 { try await Task.sleep(nanoseconds:200_000_000) }
                    let song = try await station.spotify.resolve(title:track.title,artist:track.artist)
                    guard !Task.isCancelled, generation == id, station.connected else { return }
                    matches[track.key] = song != nil
                }
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                if let service = error as? ServiceError, service.status == 429 {
                    let date = Date().addingTimeInterval(max(1,service.wait))
                    retryAt = date
                    message = "Spotify asked for a pause. Resume after \(date.formatted(date:.omitted,time:.standard))."
                } else {
                    message = "Spotify could not finish this check. Continue when the connection is available."
                }
            }
        }
    }
}
