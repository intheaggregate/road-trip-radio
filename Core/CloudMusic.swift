import Foundation

struct CloudDriveScene: Encodable, Equatable {
    let town: String
    let weather: String
    let energy: String
    let daylight: Bool
    let style: String?
}

struct CloudTrack: Decodable, Equatable {
    let title: String
    let artist: String
}

struct PlanError: LocalizedError {
    let code: String
    var httpStatus: Int? = nil
    var requestID: String? = nil
    var field: String? = nil
    var limitReached: Bool {
        ["subscription_sharing_usage_limit_exceeded", "insufficient_quota"].contains(code)
    }
    var needsSignIn: Bool {
        ["invalid_token", "invalid_grant", "unauthorized", "subscription_sharing_invalid_user", "subscription_sharing_consent_required", "insufficient_scope"].contains(code)
    }
    var requiresAttention: Bool {
        limitReached || needsSignIn || ["subscription_sharing_user_not_eligible", "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported", "http_403"].contains(code)
    }
    var errorDescription: String? {
        if limitReached { return "ChatGPT paused plan usage. Open Manage usage to review your limit." }
        if needsSignIn { return "Reconnect your ChatGPT account to authorize live picks." }
        if code == "subscription_sharing_user_not_eligible" || code == "http_403" { return "Your account or workspace policy does not currently allow these live picks." }
        if code == "subscription_sharing_unsupported_capability" || code == "subscription_sharing_route_not_supported" { return "This ChatGPT connection does not support this request. Check the selected model in Settings." }
        return "ChatGPT could not complete this pick. Your station can keep playing."
    }
}

/// Accept only a finished response. Partial songs from interrupted streams never enter the queue.
struct CloudMusicStream {
    private var text = ""
    private var bytes = 0
    mutating func receive(_ payload: String) throws -> [CloudTrack]? {
        bytes += payload.utf8.count
        guard bytes <= 1_000_000 else { throw RadioError("ChatGPT returned too much data.") }
        if payload == "[DONE]" { return nil }
        let event = try JSONSerialization.jsonObject(with:Data(payload.utf8)) as? [String:Any]
        let response = event?["response"] as? [String:Any]
        switch event?["type"] as? String {
        case "response.output_text.delta":
            text += event?["delta"] as? String ?? ""
        case "response.completed":
            let messages = response?["output"] as? [[String:Any]] ?? []
            let result = messages.filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String:Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            return try Self.tracks(from:result.isEmpty ? text : result)
        case "response.failed", "response.incomplete", "error":
            let fault = response?["error"] as? [String:Any] ?? event?["error"] as? [String:Any]
            throw PlanError(code:fault?["code"] as? String ?? event?["code"] as? String ?? "incomplete")
        default: break
        }
        return nil
    }
    private static func tracks(from raw: String) throws -> [CloudTrack] {
        struct Selection: Decodable { let tracks: [CloudTrack] }
        let response = try JSONDecoder().decode(Selection.self,from:Data(raw.utf8))
        var seen = Set<[String]>()
        let valid = response.tracks.prefix(3).compactMap { track -> CloudTrack? in
            let values = [track.title,track.artist].map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            guard values.allSatisfy({ !$0.isEmpty && $0.count <= 140 && $0.rangeOfCharacter(from:.controlCharacters) == nil }),
                  seen.insert(values.map { $0.lowercased() }).inserted else { return nil }
            return CloudTrack(title:values[0],artist:values[1])
        }
        guard !valid.isEmpty else { throw RadioError("ChatGPT returned no usable recordings.") }
        return valid
    }
}
