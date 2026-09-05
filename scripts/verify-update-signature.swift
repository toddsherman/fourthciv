import Foundation
import CryptoKit

// Independent public-key verification for release tooling and CI; Sparkle verifies updates in the app.
let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    fatalError("Usage: verify-update-signature.swift Info.plist FILE [BASE64_SIGNATURE]")
}
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[1])), format: nil) as! [String: Any]
guard let encodedKey = plist["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: encodedKey) else { fatalError("Missing update public key") }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let file = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let content: Data
let signature: Data
if arguments.count == 4 {
    content = file
    guard let decoded = Data(base64Encoded: arguments[3]) else { fatalError("Invalid signature encoding") }
    signature = decoded
} else {
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = file.range(of: marker, options: .backwards),
          let footer = String(data: file[range.lowerBound...], encoding: .utf8) else { fatalError("Missing signed feed footer") }
    let pattern = try NSRegularExpression(pattern: "\\A<!-- sparkle-signatures:\\nedSignature: ([A-Za-z0-9+/=]+)\\nlength: ([0-9]+)\\n-->\\n?\\z")
    guard let match = pattern.firstMatch(in: footer, range: NSRange(footer.startIndex..., in: footer)),
          let signatureRange = Range(match.range(at: 1), in: footer), let lengthRange = Range(match.range(at: 2), in: footer),
          let length = Int(footer[lengthRange]), length == range.lowerBound,
          let decoded = Data(base64Encoded: String(footer[signatureRange])) else { fatalError("Invalid signed feed footer or length") }
    content = file.prefix(length)
    signature = decoded
}
guard key.isValidSignature(signature, for: content) else {
    fputs("Update signature does not match the app's public key.\n", stderr)
    exit(1)
}
print("Update signature verified against the app's public key.")
