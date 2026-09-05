import Foundation
import CryptoKit
import Testing
@testable import FourthCivCore

struct CoreTests {
    let attribution = Attribution(name: "Test agent", provider: "Unverified provider")

    func altered(_ event: Event, field: String, value: Any) throws -> Event {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        json[field] = value
        return try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func signaturesBindContentAndAttribution() throws {
        let event = try Event.signed(kind: .community, key: .init(), attribution: attribution, title: "A town", body: "Public discussions")
        try event.validate()
        for (field, value) in [("body", "Altered"), ("title", "Changed"), ("author", Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())] {
            let changed = try altered(event, field: field, value: value)
            #expect(throws: (any Error).self) { try changed.validate() }
        }
        var claims = attribution; claims.provider = "Trusted provider"
        let changed = try altered(event, field: "attribution", value: JSONSerialization.jsonObject(with: JSONEncoder().encode(claims)))
        #expect(throws: (any Error).self) { try changed.validate() }
        #expect(event.id.count == 64)
    }

    @Test func utf8LengthAndAmbiguousFieldsHaveDistinctSignatures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let event = try Event.signed(kind: .community, key: key, attribution: Attribution(name: "🌱"), title: "村", body: "line 1\nline 2: hello")
        try event.validate()
        #expect(String(decoding: event.signingBytes, as: UTF8.self).contains("4:🌱"))
        let decoded = try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(event))
        #expect(decoded.signingBytes == event.signingBytes)
        #expect(throws: (any Error).self) {
            _ = try Event.signed(kind: .community, key: key, attribution: attribution, title: "X", body: String(repeating: "🌱", count: 4_097))
        }
    }

    @Test @MainActor func persistenceReplayAndReferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = Curve25519.Signing.PrivateKey()
        let town = try Event.signed(kind: .community, key: key, attribution: attribution, title: "Town", body: "Description")
        let otherTown = try Event.signed(kind: .community, key: key, attribution: attribution, title: "Other", body: "Description")
        let message = try Event.signed(kind: .message, key: key, attribution: attribution, community: town.id, body: "A question")
        var store: EventStore? = try EventStore(directory: dir)
        #expect(throws: (any Error).self) { try store!.insert(message) }
        #expect(try store!.insert(town))
        #expect(try !store!.insert(town))
        #expect(try store!.insert(message))
        #expect(try store!.insert(otherTown))
        let badReply = try Event.signed(kind: .message, key: key, attribution: attribution, community: otherTown.id, parent: message.id, body: "Cross-community reply")
        #expect(throws: (any Error).self) { try store!.insert(badReply) }
        #expect(throws: (any Error).self) { _ = try EventStore(directory: dir) }
        #expect(store!.page(offset: Int.max).events.isEmpty)
        store = nil
        let reopened = try EventStore(directory: dir)
        #expect(reopened.events == [town, message, otherTown])
        #expect(reopened.page(offset: 0, limit: 1).next == 1)
        #expect(reopened.page(offset: 1, limit: 1, kind: .community).events == [otherTown])
        #expect(reopened.page(offset: 1, limit: 1, kind: .community).next == nil)
    }

    @Test @MainActor func failedWriteDoesNotChangeMemoryOrDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try EventStore(directory: dir, limitBytes: 10)
        let town = try Event.signed(kind: .community, key: .init(), attribution: attribution, title: "Town", body: "Description")
        #expect(throws: (any Error).self) { try store.insert(town) }
        #expect(store.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("events.json").path))
    }

    @Test func rejectsFutureAndOversizedClaims() throws {
        let event = try Event.signed(kind: .community, key: .init(), attribution: attribution, title: "Town", body: "Description", now: Date().addingTimeInterval(600))
        #expect(throws: (any Error).self) { try event.validate() }
        #expect(throws: (any Error).self) {
            _ = try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: String(repeating: "a", count: 161)), title: "Town", body: "Description")
        }
    }

    @Test func incrementalHTTPAndHostileFraming() throws {
        let partial = Data("POST /v1/events HTTP/1.1\r\nHost: 127.0.0.1:49400\r\nContent-Length: 2\r\n\r\n{".utf8)
        #expect(try HTTPRequest.parse(partial) == nil)
        var full = partial; full.append(Data("}".utf8))
        #expect(try HTTPRequest.parse(full)?.body == Data("{}".utf8))
        for raw in [
            "POST /v1/events HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            "POST /v1/events HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /v1/events HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST /v1/events HTTP/1.1\r\nContent-Length: 90000\r\n\r\n",
            "POST /v1/events HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}trailing"
        ] { #expect(throws: (any Error).self) { _ = try HTTPRequest.parse(Data(raw.utf8)) } }
    }

    @Test func endpointsCannotReachOtherHosts() throws {
        #expect(try LocalEndpoint.validate("http://127.0.0.1:49401").port == 49401)
        for endpoint in ["https://example.com", "http://192.168.1.2:80", "http://127.0.0.1:80@evil.test", "http://127.0.0.1:49401/path", "http://127.0.0.1:49401?next=evil", "http://localhost:49401"] {
            #expect(throws: (any Error).self) { _ = try LocalEndpoint.validate(endpoint) }
        }
    }

    @Test func lanAccessRequiresExplicitOptInAndPrivateAddresses() throws {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.7", "169.254.1.2"] {
            #expect(throws: (any Error).self) { _ = try LocalEndpoint.validate("http://\(host):49400") }
            #expect(try LocalEndpoint.validate("http://\(host):49400", allowLAN: true).host == host)
        }
        for host in ["172.15.0.1", "172.32.0.1", "192.169.0.1", "8.8.8.8", "0.0.0.0", "10.0.0.01", "10.0.0.256", "[::1]", "example.com", "10.0.0.1.evil.test"] {
            #expect(throws: (any Error).self) { _ = try LocalEndpoint.validate("http://\(host):49400", allowLAN: true) }
        }
    }

    @Test func oldSettingsRemainLocalOnly() throws {
        let data = Data(#"{"paused":false,"storageMiB":16,"peers":[],"syncSeconds":10}"#.utf8)
        let settings = try JSONDecoder().decode(NodeSettings.self, from: data)
        #expect(!settings.lanEnabled)
    }
}
