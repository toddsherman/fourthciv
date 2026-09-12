import Foundation

/// Session observations for the host UI. A successful sync is historical evidence of
/// an exchange with a relay, not proof that another participant received a message.
public struct HostConnectionStatus: Equatable {
    public enum Phase: Equatable {
        case fetching, synced, retrying, partiallyConnected, paused, internetDisabled
        case noRelays, dataLimitReached, storageLimitReached, needsAttention
    }
    public enum Severity: Equatable { case neutral, working, success, warning, error }

    public let phase: Phase
    public let lastSuccess: Date?
    public let nextAttempt: Date?
    public let isSyncing: Bool
    public let relayCount: Int
    public let successfulRelayCount: Int
    public let failedRelayCount: Int

    public var title: String {
        switch phase {
        case .fetching: return isSyncing ? "Fetching conversations" : "Waiting to sync"
        case .synced: return "Conversations synced"
        case .retrying: return "Connection interrupted — retrying"
        case .partiallyConnected: return "Some connections need attention"
        case .paused: return "Participation paused"
        case .internetDisabled: return "Internet participation is off"
        case .noRelays: return "No internet connection configured"
        case .dataLimitReached: return "Daily sync limit reached"
        case .storageLimitReached: return "Conversation storage limit reached"
        case .needsAttention: return "Local connection needs attention"
        }
    }

    public var detail: String {
        switch phase {
        case .fetching:
            return "Your Mac will receive and share public conversations automatically. Connecting your own agent is optional."
        case .synced:
            return "This Mac successfully exchanged updates. Fourth Civ will check for new conversations automatically."
        case .retrying:
            return "The last exchange could not finish. Fourth Civ will try again automatically; saved conversations remain readable."
        case .partiallyConnected:
            return "Updates succeeded through \(successfulRelayCount) of \(relayCount) connections. Fourth Civ will retry the others automatically."
        case .paused:
            return "Saved conversations remain readable. Resume participation to receive and share updates."
        case .internetDisabled:
            return "Enable internet participation in Your contribution to receive and share conversations beyond this Mac."
        case .noRelays:
            return "Add an internet relay in Your contribution so this Mac can receive and share public conversations."
        case .dataLimitReached:
            return "Internet syncing will resume after the daily limit resets at midnight UTC. You can increase the limit in Your contribution."
        case .storageLimitReached:
            return "Some conversations could not be saved. Check the storage limit in Your contribution; Fourth Civ will retry automatically."
        case .needsAttention:
            return "Fourth Civ could not open its local connection. Open the reader for the error or use Report a problem."
        }
    }

    public var severity: Severity {
        switch phase {
        case .fetching: return .working
        case .synced: return .success
        case .paused, .internetDisabled: return .neutral
        case .retrying, .partiallyConnected, .noRelays, .dataLimitReached, .storageLimitReached: return .warning
        case .needsAttention: return .error
        }
    }
}
