import SwiftUI

@MainActor struct SavedChapterEditor: View {
    let program: DriveProgram
    let cue: DriveCue
    @ObservedObject var cloud: CloudRadio
    @EnvironmentObject private var station: Station
    @Environment(\.dismiss) private var dismiss
    @AppStorage("radio.tasteBrief.v1") private var taste = ""
    @State private var feedback = ""
    @State private var includeTaste = true
    @State private var seenSuggestions: [CueTrack] = []
    @State private var draft: DraftCue?
    @State private var selected = Set<CueTrack>()
    @State private var message = ""
    @State private var task: Task<Void,Never>?
    @State private var generation = UUID()

    init(program: DriveProgram, cue: DriveCue, cloud: CloudRadio) {
        self.program = program
        self.cue = cue
        _cloud = ObservedObject(wrappedValue:cloud)
    }
    private var slot: SoundtrackSlot {
        SoundtrackSlot(id:"chapter",label:cue.label,trigger:cue.trigger,path:cue.path,radius:cue.radius,
                       instruction:feedback.trimmingCharacters(in:.whitespacesAndNewlines))
    }
    private var validFeedback: Bool {
        !slot.instruction.isEmpty && slot.instruction.count <= 450
    }
    private var parked: Bool { !station.driving && !station.starting }
    private var changeable: Bool { (cue.trigger == .region || cue.trigger == .longStretch) && cue.locked != true }

    var body: some View {
        Form {
            Section {
                ForEach(cue.tracks,id:\.key) { track in row(track) }
            } header: { Text("Current songs") }
            Section {
                TextField("What should this stretch sound like?",text:$feedback,axis:.vertical)
                    .lineLimit(2...5).disabled(task != nil)
                if feedback.count > 450 { Text("Keep your feedback within 450 characters.").font(.footnote) }
                if !taste.isEmpty {
                    Toggle("Include my saved taste",isOn:$includeTaste).disabled(task != nil)
                    if includeTaste { Text(taste).font(.footnote).foregroundStyle(.secondary) }
                }
                if task != nil {
                    HStack { ProgressView("Finding alternatives…"); Spacer(); Button("Cancel") { cancel() } }
                } else {
                    Button(draft == nil ? "Suggest replacements" : "Try different songs") { generate() }
                        .disabled(!parked || !changeable || !validFeedback || !cloud.canGenerateSoundtrack)
                }
            } header: { Text("Change the music") } footer: {
                Text("Each request uses your ChatGPT plan and shares this chapter’s name, your feedback, and any taste you include. A retry can exclude earlier suggestions from this edit.")
            }
            if !cloud.canGenerateSoundtrack && !cloud.generatingSoundtrack {
                CloudRadioSettings(cloud:cloud)
            }
            if let draft {
                Section {
                    ForEach(draft.tracks,id:\.key) { track in
                        Button {
                            if selected.contains(track) { selected.remove(track) } else { selected.insert(track) }
                        } label: {
                            HStack { row(track); Spacer(); Image(systemName:selected.contains(track) ? "checkmark.circle.fill" : "circle") }
                        }
                        .accessibilityValue(selected.contains(track) ? "Included" : "Excluded")
                    }
                    Button("Save chapter changes") { save(draft) }
                        .disabled(task != nil || selected.isEmpty || !parked)
                } header: { Text("Choose replacements") }
            }
            if !message.isEmpty { Text(message).font(.footnote) }
        }
        .navigationTitle(cue.label).navigationBarTitleDisplayMode(.inline)
        .onDisappear { cancel() }
    }
    private func row(_ track: CueTrack) -> some View {
        VStack(alignment:.leading) {
            Text(track.title)
            Text(track.artist).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
    private func generate() {
        guard parked, changeable, validFeedback, task == nil else { return }
        let request = slot
        let usualTaste = includeTaste ? taste : ""
        let token = UUID()
        generation = token
        message = ""
        // Only earlier model output from this editor can travel back to the model.
        // Existing soundtrack titles and listener exclusions are filtered on the phone.
        let previous = Array(seenSuggestions.suffix(32))
        let localExclusions = program.cues.flatMap(\.tracks) + station.avoidedSuggestions + seenSuggestions
        task = Task {
            defer { if generation == token { task = nil } }
            do {
                let proposals = try await cloud.generateSoundtrack(slots:[request],taste:usualTaste,rejected:previous)
                try Task.checkCancellation()
                guard token == generation else { return }
                guard var candidate = proposals.first(where:{ $0.slotID == request.id }) else {
                    throw RadioError("No new songs fit this brief. Try describing the rhythm, sound, or mood.")
                }
                let proposed = candidate.tracks
                candidate.tracks = SoundtrackGenerator.tracks(for:request,draft:candidate,rejected:localExclusions)
                seenSuggestions = Array((seenSuggestions + proposed).suffix(64))
                guard !candidate.tracks.isEmpty else {
                    throw RadioError("These suggestions were already used or excluded. Try another direction.")
                }
                draft = candidate
                selected = Set(candidate.tracks)
            } catch {
                if token == generation && !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
    private func save(_ candidate: DraftCue) {
        guard parked, changeable, !selected.isEmpty, let latest = station.drivePrograms.first(where:{ $0.name == program.name }) else { return }
        do {
            let replacement = try SoundtrackGenerator.replacingChapter(in:latest,original:cue,
                tracks:candidate.tracks.filter(selected.contains),reason:SoundtrackGenerator.reason(for:slot,draft:candidate),
                style:candidate.style)
            let previouslySelected = station.selectedDriveProgram?.name
            try station.storeProgram(replacement,replacing:true)
            if previouslySelected != replacement.name { station.selectProgram(previouslySelected) }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
