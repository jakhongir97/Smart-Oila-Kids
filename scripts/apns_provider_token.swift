// Mints an APNs provider JWT (ES256) from an Apple .p8 key, per Apple's
// "Establishing a token-based connection to APNs". Prints only the token.
// usage: apnsjwt <path-to-.p8> <key-id> <team-id>
import Foundation
import CryptoKit

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: apnsjwt <p8> <keyId> <teamId>\n".utf8))
    exit(2)
}
let pem = try String(contentsOfFile: args[1], encoding: .utf8)
let keyID = args[2], teamID = args[3]

let key: P256.Signing.PrivateKey
do {
    key = try P256.Signing.PrivateKey(pemRepresentation: pem)
} catch {
    FileHandle.standardError.write(Data("could not read key: \(error)\n".utf8))
    exit(1)
}

// header.kid identifies the key; payload.iss is the team, iat is issue time.
let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
let payload = #"{"iss":"\#(teamID)","iat":\#(Int(Date().timeIntervalSince1970))}"#
let signingInput = "\(base64URL(Data(header.utf8))).\(base64URL(Data(payload.utf8)))"
// JWS needs the raw r||s pair, which is exactly `rawRepresentation`.
let signature = try key.signature(for: Data(signingInput.utf8))
print("\(signingInput).\(base64URL(signature.rawRepresentation))")
