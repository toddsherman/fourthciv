import Foundation
import Testing
@testable import FourthCivCore

struct ConversationIndexTests {
    // Graph fixtures intentionally skip signing: cryptographic validation belongs
    // to Event/Store. Invalid graphs below exercise the reader's defensive bounds.
    private func message(_ id: String, parent: String = "", time: Int64 = 100,
                         community: String = "commons", author: String = "key-a", name: String = "Worker",
                         kind: EventKind = .message) -> Event {
        Event(version: 1, id: id, kind: kind, author: author, attribution: Attribution(name: name),
              createdAt: time, nonce: "fixture", community: community, parent: parent,
              title: "", body: "Local message \(id)", signature: "")
    }

    @Test func backdatedRepliesFollowTheirParentsAndAvailableMessagesStayChronological() {
        let root = message("root", time: 500)
        let first = message("first", parent: root.id, time: 50)
        let nested = message("nested", parent: first.id, time: 20)
        let sibling = message("sibling", parent: root.id, time: 100)
        let laterNested = message("later", parent: first.id, time: 200)
        let unrelated = message("elsewhere", time: 10)
        let all = [laterNested, sibling, unrelated, nested, root, first]
        let index = ConversationIndex(messages: all)

        // The UI can search down to one matching reply while the complete index
        // still recovers the root, its siblings, and both generations of replies.
        let searchResults = all.filter { $0.id == nested.id }
        #expect(searchResults.count == 1)
        #expect(index.rootID(for: searchResults[0].id) == root.id)
        #expect(index.event(id: first.id) == first)
        #expect(index.conversation(containing: nested.id).map(\.id) == ["root", "first", "nested", "sibling", "later"])
        #expect(index.conversation(containing: unrelated.id) == [unrelated])
        #expect(ConversationIndex(messages: all.reversed()).conversation(containing: root.id) == index.conversation(containing: root.id))
    }

    @Test func equalTimesUseIDsAndDuplicateEventsAppearOnce() {
        let root = message("root")
        let a = message("a", parent: root.id)
        let b = message("b", parent: root.id)
        let c = message("c", parent: root.id)
        let index = ConversationIndex(messages: [c, root, b, a, b, root])
        #expect(index.conversation(containing: b.id).map(\.id) == ["root", "a", "b", "c"])
    }

    @Test func signingKeysDistinguishParticipantsWhenNamesRepeatOrChange() {
        let root = message("root", author: "key-a", name: "Shared name")
        let renamed = message("renamed", parent: root.id, author: "key-a", name: "New name")
        let otherKey = message("other", parent: root.id, author: "key-b", name: "Shared name")
        let index = ConversationIndex(messages: [root, renamed, otherKey])
        #expect(index.participantCount(containing: renamed.id) == 2)
        #expect(index.participantCount(containing: "absent") == 0)
    }

    @Test func incompleteAndCrossCommunityParentsDoNotMergeConversations() {
        let original = message("original", community: "first")
        let crossCommunity = message("cross", parent: original.id, community: "second")
        let child = message("child", parent: crossCommunity.id, community: "second")
        let orphan = message("orphan", parent: "missing", community: "second")
        let communityEvent = message("community", community: "", kind: .community)
        let replyToCommunity = message("reply-to-community", parent: communityEvent.id)
        let index = ConversationIndex(messages: [original, crossCommunity, child, orphan, communityEvent, replyToCommunity])
        #expect(index.conversation(containing: original.id) == [original])
        #expect(index.conversation(containing: child.id) == [crossCommunity, child])
        #expect(index.rootID(for: orphan.id) == orphan.id)
        #expect(index.conversation(containing: replyToCommunity.id) == [replyToCommunity])
        #expect(index.event(id: communityEvent.id) == nil)
        #expect(index.rootID(for: "absent") == nil)
        #expect(index.conversation(containing: "absent").isEmpty)
        #expect(ConversationIndex(messages: []).conversation(containing: "absent").isEmpty)
    }

    @Test func cyclesBecomeStableLocalRootsWithoutLosingDescendants() {
        let a = message("a", parent: "c", time: 100)
        let b = message("b", parent: "a", time: 200)
        let c = message("c", parent: "b", time: 300)
        let tail = message("tail", parent: "c", time: 0)
        let selfReply = message("self", parent: "self")
        let messages = [tail, selfReply, c, b, a]
        let index = ConversationIndex(messages: messages)
        #expect(index.rootID(for: tail.id) == a.id)
        #expect(index.conversation(containing: tail.id).map(\.id) == ["a", "b", "c", "tail"])
        #expect(index.conversation(containing: selfReply.id) == [selfReply])
        #expect(ConversationIndex(messages: messages.reversed()).conversation(containing: c.id) == index.conversation(containing: c.id))
    }

    @Test func twoThousandMessageChainAndWideConversationRemainComplete() {
        let chain: [Event] = (0..<2_000).map { (position: Int) -> Event in
            let id = String(position)
            let parent = position == 0 ? "" : String(position - 1)
            let time = Int64(2_000 - position)
            return message(id, parent: parent, time: time)
        }
        let chainIndex = ConversationIndex(messages: chain.reversed())
        #expect(chainIndex.conversation(containing: "1999") == chain)
        #expect(chainIndex.rootID(for: "1999") == "0")
        let root = message("root", time: 10_000)
        let replies: [Event] = (0..<1_999).map { (position: Int) -> Event in
            message(String(position), parent: root.id, time: Int64(position))
        }
        let wideIndex = ConversationIndex(messages: replies.reversed() + [root])
        #expect(wideIndex.conversation(containing: "1998") == [root] + replies)
    }
}
