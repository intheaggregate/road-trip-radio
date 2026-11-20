import CryptoKit
import Foundation
@preconcurrency import Network
import Security

private let issuer = "https://auth.openai.com"
let inferenceResource = "https://api.openai.com/v1"

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
}
private func decodedURL(_ value: String) -> Data? {
    let base = value.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
    return Data(base64Encoded:base + String(repeating:"=",count:(4 - base.count % 4) % 4))
}
private func randomSecret() throws -> String {
    var bytes = [UInt8](repeating:0,count:32)
    guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault,$0.count,$0.baseAddress!) }) == errSecSuccess else {
        throw RadioError("Secure sign-in could not start.")
    }
    return base64URL(Data(bytes))
}
struct CloudRegistration: Codable {
    let client: String
    let subject: String
    let label: String
}
struct CloudTokens: Codable {
    let access: String
    let refresh: String?
    let identity: String?
    let scopes: String
    let expires: Date
    var permitsPicks: Bool { scopes.split(separator:" ").contains("chatgpt.tokens.use.direct") }
}

enum CloudOAuth {
    static func form(_ endpoint: String, _ fields: [String:String]) async throws -> Object {
        var request = URLRequest(url:URL(string:endpoint)!,timeoutInterval:20)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        request.httpBody = Data(fields.map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters:allowed) ?? "") }.joined(separator:"&").utf8)
        return try await Network.json(request)
    }
    static func exchange(_ fields: [String:String], previous: CloudTokens? = nil) async throws -> CloudTokens {
        let reply = try await form(issuer + "/api/accounts/oauth/token",fields.merging(["resource":inferenceResource]) { _,v in v })
        guard let access = reply["access_token"] as? String, !access.isEmpty,
              let seconds = reply["expires_in"] as? Double, seconds > 0 else { throw RadioError("Incomplete ChatGPT token response.") }
        return CloudTokens(access:access,refresh:reply["refresh_token"] as? String ?? previous?.refresh,
                           identity:reply["id_token"] as? String ?? previous?.identity,
                           scopes:reply["scope"] as? String ?? previous?.scopes ?? "",expires:Date().addingTimeInterval(seconds))
    }
    static func revoke(_ token: String, client: String) async throws {
        let discovery = try await Network.json(URLRequest(url:URL(string:issuer + "/.well-known/openid-configuration")!))
        guard let raw = discovery["revocation_endpoint"] as? String, let url = URL(string:raw),
              url.scheme == "https", url.host == "auth.openai.com" else { throw RadioError("Remote sign-out unavailable.") }
        _ = try await form(raw,["token":token,"token_type_hint":"refresh_token","client_id":client])
    }
    // Security.framework's RSA public key input is a DER sequence containing the modulus and exponent.
    private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
        var size = bytes.count
        var length = [UInt8]()
        if size < 128 { length = [UInt8(size)] }
        else {
            while size > 0 { length.insert(UInt8(size & 255),at:0); size >>= 8 }
            length.insert(128 + UInt8(length.count),at:0)
        }
        return Data([tag] + length) + bytes
    }
    private static func integer(_ value: Data) -> Data {
        der(2,(value.first ?? 0) >= 128 ? Data([0]) + value : value)
    }
    static func verify(_ jwt: String, nonce: String, client: String) async throws -> CloudRegistration {
        let invalid = RadioError("The signed ChatGPT identity could not be verified.")
        let chunks = jwt.components(separatedBy:".")
        guard chunks.count == 3, let rawHeader = decodedURL(chunks[0]), let rawBody = decodedURL(chunks[1]),
              let signature = decodedURL(chunks[2]), let header = try JSONSerialization.jsonObject(with:rawHeader) as? Object,
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else { throw invalid }
        let keys = try await Network.json(URLRequest(url:URL(string:issuer + "/.well-known/jwks.json")!))
        guard let key = (keys["keys"] as? [Object])?.first(where:{ $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" }),
              let n = (key["n"] as? String).flatMap(decodedURL), (256...1024).contains(n.count),
              let e = (key["e"] as? String).flatMap(decodedURL), (1...8).contains(e.count) else { throw invalid }
        let attributes: [String:Any] = [kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeyClass as String:kSecAttrKeyClassPublic]
        guard let pub = SecKeyCreateWithData(der(48,integer(n) + integer(e)) as CFData,attributes as CFDictionary,nil),
              SecKeyVerifySignature(pub,.rsaSignatureMessagePKCS1v15SHA256,Data((chunks[0] + "." + chunks[1]).utf8) as CFData,signature as CFData,nil),
              let body = try JSONSerialization.jsonObject(with:rawBody) as? Object else { throw invalid }
        let audience = body["aud"] as? [String] ?? [body["aud"] as? String ?? ""]
        let now = Date().timeIntervalSince1970
        guard body["iss"] as? String == issuer, body["nonce"] as? String == nonce, audience.contains(client),
              (body["azp"] as? String ?? (audience.count == 1 ? client : "")) == client,
              let expiry = body["exp"] as? Double, expiry > now, let issued = body["iat"] as? Double, issued <= now + 10,
              (body["nbf"] as? Double ?? 0) <= now + 10,
              let sub = body["sub"] as? String, !sub.isEmpty else { throw invalid }
        return CloudRegistration(client:client,subject:sub,label:body["email"] as? String ?? "ChatGPT account")
    }
}

/// The browser returns to this iPhone. Only a pending sign-in opens the loopback socket.
@MainActor final class CloudLogin {
    private var listener: NWListener?
    private var timeout: Task<Void,Never>?
    private var completion: CheckedContinuation<[String:String],Error>?
    private var connections: [ObjectIdentifier:NWConnection] = [:]
    private func finish(_ result: Result<[String:String],Error>) {
        let done = completion
        completion = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        done?.resume(with:result)
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func read(_ connection: NWConnection, port: UInt16, state: String, prefix: Data = Data()) {
        let id = ObjectIdentifier(connection)
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] chunk,_,ended,error in
            MainActor.assumeIsolated {
                guard let self, self.completion != nil, self.connections[id] != nil else { connection.cancel(); return }
                let data = prefix + (chunk ?? Data())
                if error != nil || data.count > 16384 { connection.cancel(); self.connections[id] = nil; return }
                guard let end = data.range(of:Data([13,10,13,10])) else {
                    if ended { connection.cancel(); self.connections[id] = nil }
                    else { self.read(connection,port:port,state:state,prefix:data) }
                    return
                }
                let headers = String(decoding:data[..<end.lowerBound],as:UTF8.self).components(separatedBy:"\r\n")
                let request = headers.first?.components(separatedBy:" ") ?? []
                var fields = [String:String]()
                var accepted = false
                if request.count == 3, request[0] == "GET", headers.dropFirst().contains(where:{ $0.lowercased() == "host: 127.0.0.1:\(port)" }),
                   let parts = URLComponents(string:request[1]), parts.host == nil, parts.scheme == nil, parts.path == "/auth/callback" {
                    let items = parts.queryItems ?? []
                    for item in items { fields[item.name] = item.value }
                    accepted = fields["state"] == state && Set(items.map(\.name)).count == items.count
                }
                let body = accepted ? "Return to Road Trip Radio." : "Unknown sign-in request."
                let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nCache-Control: no-store\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                let authorized = accepted ? fields : nil
                connection.send(content:Data(response.utf8),completion:.contentProcessed { _ in
                    MainActor.assumeIsolated {
                        connection.cancel()
                        guard self.connections.removeValue(forKey:id) != nil else { return }
                        if let authorized { self.finish(.success(authorized)) }
                    }
                })
            }
        }
    }
    func authorize(previous: CloudRegistration?, hint: String?, requestConsent: Bool = false,
                   present: @escaping (URL?)->Void) async throws -> (CloudRegistration,CloudTokens) {
        let state = try randomSecret(), nonce = try randomSecret(), verifier = try randomSecret()
        let hostKey = "chatgpt.host"
        let host: String
        if let saved = Vault.data(hostKey), let value = String(data:saved,encoding:.utf8) { host = value }
        else { host = "urn:uuid:" + UUID().uuidString.lowercased(); try Vault.save(Data(host.utf8),key:hostKey) }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let socket = try NWListener(using:params)
        listener = socket
        var redirect = ""
        let fields: [String:String] = try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            socket.stateUpdateHandler = { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self, self.listener === socket, self.completion != nil else { return }
                    switch status {
                    case .ready:
                        guard let port = socket.port else { self.finish(.failure(RadioError("Could not receive sign-in."))); return }
                        redirect = "http://127.0.0.1:\(port.rawValue)/auth/callback"
                        var query = ["client_id":previous?.client ?? "dynamic_agent_client","ext_agent_host_id":host,"response_type":"code",
                                     "redirect_uri":redirect,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                                     "resource":inferenceResource,"state":state,"nonce":nonce,"code_challenge_method":"S256",
                                     "code_challenge":base64URL(Data(SHA256.hash(data:Data(verifier.utf8))))]
                        if previous == nil { query["agent_name_hint"] = "Road Trip Radio" } else { query["id_token_hint"] = hint }
                        if previous != nil && requestConsent { query["prompt"] = "consent" }
                        do { present(try Network.url(issuer + "/api/accounts/authorize",query)) }
                        catch { self.finish(.failure(error)) }
                    case .failed(let error): self.finish(.failure(error))
                    default: break
                    }
                }
            }
            socket.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self, self.listener === socket, let port = socket.port, self.connections.count < 12 else { connection.cancel(); return }
                    self.connections[ObjectIdentifier(connection)] = connection
                    connection.start(queue:.main); self.read(connection,port:port.rawValue,state:state)
                }
            }
            socket.start(queue:.main)
            timeout = Task {
                try? await Task.sleep(nanoseconds:300_000_000_000)
                if !Task.isCancelled { finish(.failure(RadioError("ChatGPT sign-in timed out."))) }
            }
        }
        present(nil)
        guard fields["error"] == nil, let code = fields["code"], !code.isEmpty,
              let client = fields["client_id"] ?? previous?.client, client != "dynamic_agent_client", !client.isEmpty,
              previous.map({ $0.client == client }) ?? true else { throw RadioError("ChatGPT sign-in was declined or incomplete.") }
        let tokens = try await CloudOAuth.exchange(["client_id":client,"grant_type":"authorization_code","code":code,"code_verifier":verifier,"redirect_uri":redirect])
        guard let identity = tokens.identity else { throw RadioError("ChatGPT did not return a signed identity.") }
        let registration = try await CloudOAuth.verify(identity,nonce:nonce,client:client)
        guard previous.map({ $0.subject == registration.subject }) ?? true else { throw RadioError("Choose the ChatGPT account used for this connection.") }
        return (registration,tokens)
    }
}
