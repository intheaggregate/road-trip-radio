import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

typealias Object = [String: Any]

enum Vault {
    static func data(_ key: String) -> Data? {
        var query = attributes(key)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    static func save(_ data: Data?, key: String) throws {
        let query = attributes(key)
        guard let data else { SecItemDelete(query as CFDictionary); return }
        let fields: Object = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RadioError("The iPhone Keychain could not save this connection.") }
    }
    private static func attributes(_ key: String) -> Object {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "RoadTripRadio", kSecAttrAccount as String: key]
    }
}

struct ServiceError: LocalizedError {
    let status: Int
    let wait: Double
    let message: String
    var errorDescription: String? { message }
}
enum Network {
    static func url(_ base: String, _ query: [String: String] = [:]) throws -> URL {
        guard var parts = URLComponents(string: base) else { throw RadioError("Invalid service address.") }
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw RadioError("Invalid service address.") }
        return url
    }
    static func json(_ request: URLRequest) async throws -> Object {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RadioError("The service did not send an HTTP response.") }
        guard (200...299).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? Object
            let message = (body?["error"] as? Object)?["message"] as? String ?? body?["error_description"] as? String ?? body?["message"] as? String
            throw ServiceError(status: http.statusCode, wait: Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30,
                               message: message ?? "Service returned HTTP \(http.statusCode).")
        }
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? Object else { throw RadioError("Unexpected service response.") }
        return object
    }
}

private struct Credentials: Codable {
    var access: String
    var refresh: String
    var expires: Date
    var client: String
}

struct Device: Identifiable {
    let id: String, name: String, type: String
    let active: Bool
    init?(_ json: Object) {
        guard let id = json["id"] as? String, !id.isEmpty, json["is_restricted"] as? Bool != true else { return nil }
        self.id = id
        name = json["name"] as? String ?? "Spotify device"
        type = json["type"] as? String ?? ""
        active = json["is_active"] as? Bool ?? false
    }
}
struct Player {
    let device: Device?
    let playing: Bool
    let track: Song?
    let remaining: Double
}
struct LibraryList: Identifiable, Codable, Hashable {
    let id: String, name: String
}
extension Song {
    init?(spotify json: Object) {
        guard json["is_local"] as? Bool != true, json["is_playable"] as? Bool != false,
              (json["type"] as? String ?? "track") == "track",
              let id = json["id"] as? String, id.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil,
              let title = json["name"] as? String, let artist = (json["artists"] as? [Object])?.first?["name"] as? String else { return nil }
        let images = (json["album"] as? Object)?["images"] as? [Object]
        self.init(id: id, title: title, artist: artist, seconds: (json["duration_ms"] as? Double ?? 0) / 1000,
                  artwork: (images?.first?["url"] as? String).flatMap(URL.init(string:)))
    }
}

@MainActor
final class Spotify: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let callback = "roadtripradio://spotify-callback"
    private var credentials = Vault.data("spotify").flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
    private var refreshTask: Task<Credentials, Error>?
    private var session: ASWebAuthenticationSession?
    private var generation = UUID()
    var connected: Bool { credentials != nil }
    var clientID: String { credentials?.client ?? "" }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func install(_ value: Credentials) throws {
        try Vault.save(JSONEncoder().encode(value), key: "spotify")
        credentials = value
    }
    func disconnect() {
        generation = UUID(); session?.cancel(); session = nil; refreshTask?.cancel(); refreshTask = nil
        credentials = nil; try? Vault.save(nil, key: "spotify")
    }
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw RadioError("Could not start secure sign-in.") }
        return base64url(Data(bytes))
    }
    private func base64url(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func connect(client: String) async throws {
        let attempt = generation
        guard client.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else { throw RadioError("Enter the 32-character Client ID from your Spotify developer app.") }
        let verifier = try random(), state = try random()
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let url = try Network.url("https://accounts.spotify.com/authorize", [
            "client_id": client, "response_type": "code", "redirect_uri": Self.callback,
            "code_challenge_method": "S256", "code_challenge": challenge, "state": state,
            "scope": "user-read-playback-state user-modify-playback-state user-library-read playlist-read-private playlist-read-collaborative"
        ])
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: "roadtripradio") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? RadioError("Spotify sign-in closed.")) }
            }
            web.presentationContextProvider = self
            self.session = web
            if !web.start() { continuation.resume(throwing: RadioError("Could not open Spotify sign-in.")) }
        }
        defer { session = nil }
        let fields = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.host == "spotify-callback", fields.first(where: { $0.name == "state" })?.value == state,
              let code = fields.first(where: { $0.name == "code" })?.value else { throw RadioError("Spotify did not authorize the connection.") }
        let value = try await Self.exchange(client: client, fields: ["grant_type":"authorization_code", "code":code, "redirect_uri":Self.callback, "code_verifier":verifier], previous: nil)
        guard attempt == generation else { throw CancellationError() }
        try install(value)
    }
    private static func exchange(client: String, fields: [String:String], previous: String?) async throws -> Credentials {
        var req = URLRequest(url: URL(string:"https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type")
        let all = fields.merging(["client_id":client]) { _, new in new }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        req.httpBody = Data(all.map { key, value in key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator:"&").utf8)
        let json = try await Network.json(req)
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String ?? previous else { throw RadioError("Spotify returned incomplete sign-in credentials.") }
        return Credentials(access:access, refresh:refresh, expires:Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600), client:client)
    }
    private func token(force: Bool = false) async throws -> String {
        guard let value = credentials else { throw RadioError("Connect Spotify in Settings.") }
        if !force && value.expires.timeIntervalSinceNow > 80 { return value.access }
        if let refreshTask { return try await refreshTask.value.access }
        let attempt = generation
        let task = Task { try await Self.exchange(client:value.client, fields:["grant_type":"refresh_token","refresh_token":value.refresh], previous:value.refresh) }
        refreshTask = task
        defer { if attempt == generation { refreshTask = nil } }
        let updated = try await task.value
        guard attempt == generation else { throw CancellationError() }
        try install(updated)
        return updated.access
    }
    private func call(_ path: String, query: [String:String] = [:], method: String = "GET", body: Object? = nil) async throws -> Object {
        var req = URLRequest(url: try Network.url("https://api.spotify.com/v1/" + path, query))
        req.httpMethod = method; req.timeoutInterval = 10
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField:"Content-Type") }
        req.setValue("Bearer " + (try await token()), forHTTPHeaderField:"Authorization")
        do { return try await Network.json(req) }
        catch let error as ServiceError where error.status == 401 {
            req.setValue("Bearer " + (try await token(force:true)), forHTTPHeaderField:"Authorization")
            return try await Network.json(req)
        }
    }
    func devices() async throws -> [Device] {
        let result = try await call("me/player/devices")
        return (result["devices"] as? [Object] ?? []).compactMap(Device.init)
    }
    func player() async throws -> Player {
        let json = try await call("me/player")
        let song = (json["item"] as? Object).flatMap(Song.init(spotify:))
        return Player(device:(json["device"] as? Object).flatMap(Device.init), playing:json["is_playing"] as? Bool ?? false,
                      track:song, remaining:max(0, (song?.seconds ?? 0) - (json["progress_ms"] as? Double ?? 0) / 1000))
    }
    func queue() async throws -> Set<String> {
        let json = try await call("me/player/queue")
        return Set((json["queue"] as? [Object] ?? []).compactMap { $0["id"] as? String })
    }
    func enqueue(_ song: Song, device: String) async throws {
        _ = try await call("me/player/queue",query:["uri":song.uri,"device_id":device],method:"POST")
    }
    func start(device: String, playlist: String?, songs: [Song], resume: Bool) async throws {
        let body: Object?
        if resume { body = nil }
        else if let playlist { body = ["context_uri":"spotify:playlist:" + playlist] }
        else if !songs.isEmpty { body = ["uris":songs.prefix(40).map(\.uri)] }
        else { throw RadioError("Start a song in Spotify, then return to Drive.") }
        _ = try await call("me/player/play",query:["device_id":device],method:"PUT",body:body)
    }
    func search(_ text: String) async throws -> [Song] {
        let json = try await call("search",query:["q":text,"type":"track","limit":"10"])
        return ((json["tracks"] as? Object)?["items"] as? [Object] ?? []).compactMap(Song.init(spotify:))
    }
    func resolve(_ story: Story) async throws -> Song? {
        let raw = try await search("track:" + story.title + " artist:" + story.artist)
        func normal(_ text: String) -> String {
            text.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
                .components(separatedBy:CharacterSet.alphanumerics.inverted).joined()
        }
        return raw.first { song in
            let title = song.title.components(separatedBy:" - ").first ?? song.title
            return (normal(song.title) == normal(story.title) || normal(title) == normal(story.title)) && normal(song.artist) == normal(story.artist)
        }
    }
    func lists() async throws -> [LibraryList] {
        let me = try await call("me")
        let owner = me["id"] as? String
        var offset = 0, result: [LibraryList] = []
        while true {
            let page = try await call("me/playlists",query:["limit":"50","offset":String(offset)])
            let rows = page["items"] as? [Object] ?? []
            result += rows.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String,
                      (item["owner"] as? Object)?["id"] as? String == owner || item["collaborative"] as? Bool == true else { return nil }
                return LibraryList(id:id, name:name)
            }
            offset += rows.count
            if rows.isEmpty || !(page["next"] is String) { return result }
        }
    }
    func rotation(_ id: String?) async throws -> [Song] {
        let path = id.map { "playlists/" + $0 + "/items" } ?? "me/tracks"
        func extract(_ page: Object) -> [Song] {
            (page["items"] as? [Object] ?? []).compactMap { row in
                (row["item"] as? Object ?? row["track"] as? Object).flatMap(Song.init(spotify:))
            }
        }
        let page = try await call(path,query:["limit":"50"])
        var songs = extract(page)
        let total = page["total"] as? Int ?? songs.count
        if total > 50 {
            let pages = (total - 1) / 50
            for number in (1...pages).shuffled().prefix(3) {
                let extra = try await call(path,query:["limit":"50","offset":String(number * 50)])
                songs += extract(extra)
            }
        }
        return songs.shuffled()
    }
}
