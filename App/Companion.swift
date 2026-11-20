import Foundation

struct CompanionConfig: Codable, Equatable {
    var address = ""
    var key = ""
    var paired: Bool { !address.isEmpty && !key.isEmpty }
    func baseURL() throws -> URL {
        let raw = address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let parts = URLComponents(string:raw), parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["","/"].contains(parts.path), let url = parts.url, !key.isEmpty else { throw RadioError("Enter the private HTTPS origin and pairing code printed by your PC.") }
        return url
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ResearchDesk {
    private static let session = URLSession(configuration:.ephemeral,delegate:NoRedirect(),delegateQueue:nil)
    private static func call(_ config: CompanionConfig, path: String, body: Object? = nil) async throws -> (Int,Data) {
        let url = try config.baseURL().appendingPathComponent(path)
        var req = URLRequest(url:url,timeoutInterval:10)
        req.setValue("Bearer " + config.key,forHTTPHeaderField:"Authorization")
        if let body { req.httpMethod = "POST"; req.setValue("application/json",forHTTPHeaderField:"Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject:body) }
        let (data,response) = try await session.data(for:req)
        guard let http = response as? HTTPURLResponse, data.count <= 150_000 else { throw RadioError("Unexpected companion response.") }
        guard (200...299).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with:data)) as? Object
            throw RadioError(json?["message"] as? String ?? "The PC companion returned HTTP \(http.statusCode).")
        }
        return (http.statusCode,data)
    }
    static func check(_ config: CompanionConfig) async throws { _ = try await call(config,path:"v1/status") }
    static func run(_ config: CompanionConfig, places: [String], live: Bool, energy: Energy, weather: String) async throws -> ResearchPack {
        let (_, data) = try await call(config,path:"v1/research",body:["mode":live ? "live":"trip","places":places,"energy":energy.rawValue,"weather":weather])
        guard let job = (try JSONSerialization.jsonObject(with:data) as? Object)?["id"] as? String,
              job.range(of:"^[A-Za-z0-9_-]{24}$",options:.regularExpression) != nil else { throw RadioError("Invalid research job.") }
        for _ in 0..<90 {
            try await Task.sleep(nanoseconds:4_000_000_000)
            let (code,data) = try await call(config,path:"v1/research/" + job)
            if code == 200 { return try JSONDecoder().decode(ResearchPack.self,from:data).validated() }
        }
        throw RadioError("Research is taking longer than expected. Request the same trip again to retrieve the result.")
    }
}
