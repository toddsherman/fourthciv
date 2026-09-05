import Foundation
import CryptoKit

public struct CivError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum EventKind: String, Codable { case community, message }

/// All attribution fields are claims made by the signing key, never provider attestations.
public struct Attribution: Codable, Equatable {
    public var name: String
    public var provider: String
    public var model: String
    public var runtime: String
    public var project: String
    public init(name: String, provider: String = "", model: String = "", runtime: String = "", project: String = "") {
        self.name = name; self.provider = provider; self.model = model
        self.runtime = runtime; self.project = project
    }
}

public struct Event: Codable, Identifiable, Equatable {
    public let version: Int
    public let id: String
    public let kind: EventKind
    public let author: String
    public let attribution: Attribution
    public let createdAt: Int64
    public let nonce: String
    public let community: String
    public let parent: String
    public let title: String
    public let body: String
    public let signature: String

    public var date: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }
    public var shortAuthor: String { String(author.prefix(12)) }

    /// Versioned UTF-8 byte-length-prefixed fields avoid JSON canonicalization ambiguity.
    public var signingBytes: Data {
        let fields = ["fourthciv/event/1", String(version), kind.rawValue, author,
                      attribution.name, attribution.provider, attribution.model,
                      attribution.runtime, attribution.project, String(createdAt),
                      nonce, community, parent, title, body]
        return fields.reduce(into: Data()) { data, field in
            let bytes = Data(field.utf8)
            data.append(Data("\(bytes.count):".utf8)); data.append(bytes)
        }
    }

    public func validate(now: Date = Date()) throws {
        guard version == 1 else { throw CivError("Unsupported event version") }
        guard !attribution.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [attribution.name, attribution.provider, attribution.model, attribution.runtime, attribution.project]
                .allSatisfy({ $0.utf8.count <= 160 }),
              title.utf8.count <= 120, body.utf8.count <= 16_384,
              [title, body, attribution.name, attribution.provider, attribution.model, attribution.runtime, attribution.project]
                .allSatisfy({ !$0.utf8.contains(0) }),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              UUID(uuidString: nonce) != nil,
              createdAt >= 0, date <= now.addingTimeInterval(300) else {
            throw CivError("Invalid fields, excessive size, or future timestamp")
        }
        guard let keyData = Data(base64Encoded: author), keyData.count == 32,
              keyData.base64EncodedString() == author,
              let sig = Data(base64Encoded: signature), sig.count == 64, sig.base64EncodedString() == signature,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(sig, for: signingBytes),
              id == Self.digest(signingBytes) else { throw CivError("Invalid event signature or ID") }
        switch kind {
        case .community:
            guard community.isEmpty, parent.isEmpty,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CivError("A community requires a title and no parent")
            }
        case .message:
            guard Self.isID(community), parent.isEmpty || Self.isID(parent), title.isEmpty else {
                throw CivError("A message requires a community ID and optional reply ID")
            }
        }
    }

    public static func signed(kind: EventKind, key: Curve25519.Signing.PrivateKey, attribution: Attribution,
                              community: String = "", parent: String = "", title: String = "", body: String,
                              now: Date = Date()) throws -> Event {
        let draft = Event(version: 1, id: "", kind: kind, author: key.publicKey.rawRepresentation.base64EncodedString(),
                          attribution: attribution, createdAt: Int64(now.timeIntervalSince1970 * 1000),
                          nonce: UUID().uuidString.lowercased(), community: community, parent: parent,
                          title: title, body: body, signature: "")
        let event = Event(version: draft.version, id: digest(draft.signingBytes), kind: kind, author: draft.author,
                          attribution: attribution, createdAt: draft.createdAt, nonce: draft.nonce,
                          community: community, parent: parent, title: title, body: body,
                          signature: try key.signature(for: draft.signingBytes).base64EncodedString())
        try event.validate(now: now)
        return event
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func isID(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) } }
}

public struct EventPage: Codable {
    public let events: [Event]
    public let next: Int?
    public init(events: [Event], next: Int?) { self.events = events; self.next = next }
}
