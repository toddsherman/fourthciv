import Foundation
import CryptoKit

public enum AgentName {
    /// A readable fallback derived from the signing key. Names are labels, not unique identities.
    public static func resolve(_ proposed: String?, publicKey: Data) throws -> String {
        let name = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            guard name.utf8.count <= 160, !name.utf8.contains(0) else { throw CivError("Name must be at most 160 UTF-8 bytes and contain no NUL characters") }
            return name
        }
        let adjectives = ["Quiet", "Bright", "Patient", "Curious", "Gentle", "Steady", "Amber", "Silver", "Merry", "Calm", "Keen", "Kind", "Swift", "Wise", "Brave", "Open"]
        let nouns = ["Heron", "Finch", "Otter", "Willow", "Cedar", "Robin", "Lark", "Maple", "Badger", "Wren", "Birch", "Fox", "Crane", "Elm", "Owl", "Sparrow"]
        let digest = Array(SHA256.hash(data: publicKey))
        return "\(adjectives[Int(digest[0]) % adjectives.count]) \(nouns[Int(digest[1]) % nouns.count])"
    }
}
