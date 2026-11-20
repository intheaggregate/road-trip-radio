import CryptoKit
import Foundation

// The real login listener, PKCE exchange and identity verifier run against an isolated test issuer.
typealias Object = [String:Any]
struct RadioError: Error { let message: String; init(_ message: String) { self.message = message } }
enum Vault {
    static var values = [String:Data]()
    static func data(_ key: String) -> Data? { values[key] }
    static func save(_ data: Data?, key: String) throws { values[key] = data }
}
private func b64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
}
private func openssl(_ arguments: [String], input: Data = Data()) throws -> Data {
    let process = Process(), stdin = Pipe(), stdout = Pipe()
    process.executableURL = URL(fileURLWithPath:"/usr/bin/openssl"); process.arguments = arguments
    process.standardInput = stdin; process.standardOutput = stdout
    try process.run(); stdin.fileHandleForWriting.write(input); stdin.fileHandleForWriting.closeFile()
    let bytes = stdout.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw RadioError("Test key operation failed") }
    return bytes
}
enum Network {
    static let keyFile = CommandLine.arguments[1]
    static var query = [String:String]()
    static var badNonce = false
    static let client = "oaiapp_radio_fixture"
    static func url(_ base: String, _ fields: [String:String]) throws -> URL {
        var parts = URLComponents(string:base)!
        parts.queryItems = fields.map { URLQueryItem(name:$0.key,value:$0.value) }
        return parts.url!
    }
    static func json(_ request: URLRequest) async throws -> Object {
        if request.url?.path == "/.well-known/jwks.json" {
            let modulus = try openssl(["rsa","-in",keyFile,"-modulus","-noout"])
            let hex = String(decoding:modulus,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines).split(separator:"=").last!
            var bytes = Data(), i = hex.startIndex
            while i < hex.endIndex { let j = hex.index(i,offsetBy:2); bytes.append(UInt8(hex[i..<j],radix:16)!); i = j }
            return ["keys":[["kty":"RSA","kid":"fixture","use":"sig","n":b64(bytes),"e":"AQAB"]]]
        }
        guard request.url?.path == "/api/accounts/oauth/token" else { throw RadioError("Unexpected external call") }
        var form = URLComponents()
        form.percentEncodedQuery = String(data:request.httpBody!,encoding:.utf8)!
        let fields = Dictionary(uniqueKeysWithValues:form.queryItems!.map { ($0.name,$0.value!) })
        precondition(fields["redirect_uri"] == query["redirect_uri"] && fields["client_id"] == client)
        precondition(b64(Data(SHA256.hash(data:Data(fields["code_verifier"]!.utf8)))) == query["code_challenge"])
        let now = Int(Date().timeIntervalSince1970)
        let claims: Object = ["iss":"https://auth.openai.com","aud":client,"sub":"fixture-user","nonce":badNonce ? "unexpected" : query["nonce"]!,"iat":now,"exp":now+60]
        let header = b64(try JSONSerialization.data(withJSONObject:["alg":"RS256","kid":"fixture"]))
        let payload = header + "." + b64(try JSONSerialization.data(withJSONObject:claims))
        let signature = try openssl(["dgst","-sha256","-sign",keyFile],input:Data(payload.utf8))
        return ["access_token":"fixture","refresh_token":"fixture-refresh","scope":"chatgpt.tokens.use.direct","id_token":payload + "." + b64(signature),"expires_in":900]
    }
}

@main struct VerifyCloudLogin {
    @MainActor static func attempt(_ previous: CloudRegistration?) async throws -> CloudRegistration {
        let login = CloudLogin()
        let (identity,tokens) = try await login.authorize(previous:previous,hint:nil) { url in
            guard let url else { return }
            let fields = Dictionary(uniqueKeysWithValues:URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.map { ($0.name,$0.value!) })
            Network.query = fields
            precondition(fields["client_id"] == (previous?.client ?? "dynamic_agent_client"))
            precondition(fields["ext_agent_host_id"]!.hasPrefix("urn:uuid:"))
            let redirect = fields["redirect_uri"]!
            precondition(URL(string:redirect)?.host == "127.0.0.1")
            Task {
                do {
                    let invalid = try Network.url(redirect,["state":"unrelated","code":"fixture"])
                    let (_,rejected) = try await URLSession.shared.data(from:invalid)
                    precondition((rejected as? HTTPURLResponse)?.statusCode == 400)
                    let valid = try Network.url(redirect,["state":fields["state"]!,"code":"fixture","client_id":Network.client])
                    _ = try await URLSession.shared.data(from:valid)
                } catch { login.cancel() }
            }
        }
        precondition(tokens.permitsPicks && identity.subject == "fixture-user")
        return identity
    }
    @MainActor static func main() async throws {
        let identity = try await attempt(nil)
        let firstHost = Network.query["ext_agent_host_id"], firstNonce = Network.query["nonce"]
        Network.badNonce = true
        do { _ = try await attempt(identity); fatalError("Mismatched identity nonce accepted") }
        catch let error as RadioError { precondition(error.message.contains("verified")) }
        precondition(firstHost == Network.query["ext_agent_host_id"] && firstNonce != Network.query["nonce"])
        print("Verified loopback, state, PKCE, signed identity, returning account, and nonce rejection.")
    }
}
