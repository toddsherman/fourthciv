import Foundation
import Darwin

/// Only fixed categories and numeric codes cross the diagnostic boundary. Error descriptions
/// can contain server-controlled text, URLs, credentials, or local paths and are never retained.
public struct DiagnosticFailure: Codable, Equatable {
    public enum Kind: String, Codable { case network, http, transfer, responseTooLarge, invalidData, storageBudget, syncBudget, fileAccess, cancelled, unexpected }
    public let kind: Kind
    public var httpStatus: Int? = nil
    public var networkCode: Int? = nil

    public static func capture(_ error: Error) -> Self {
        if let failure = error as? TransferFailure { return failure.diagnostic }
        if error is CancellationError { return Self(kind: .cancelled) }
        if error is DecodingError { return Self(kind: .invalidData) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return Self(kind: ns.code == NSURLErrorCancelled ? .cancelled : .network, networkCode: ns.code) }
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain { return Self(kind: .fileAccess) }
        if let error = error as? CivError {
            switch error.message {
            case "Storage budget reached; increase it in host settings", "Prototype event limit reached (2,000)": return Self(kind: .storageBudget)
            case "Daily sync-data budget reached; it resets at midnight UTC": return Self(kind: .syncBudget)
            case "Peer response too large": return Self(kind: .responseTooLarge)
            default: return Self(kind: .invalidData)
            }
        }
        return Self(kind: .unexpected)
    }
}

public enum DiagnosticAction: String, Codable {
    case nodeOpened, listenerReady, listenerFailed, nodeStopped, settingsChanged
    case syncStarted, syncSucceeded, syncFailed, localAccepted, localRejected
}

public struct DiagnosticTarget: Codable, Equatable {
    public enum Kind: String, Codable { case relay, localPeer }
    public let kind: Kind
    public let index: Int
}

public struct DiagnosticEntry: Codable {
    public let at: Date
    public let session: UUID
    public let configuration: Int
    public let action: DiagnosticAction
    public let target: DiagnosticTarget?
    public let failure: DiagnosticFailure?
    public let received: Int?
    public let sent: Int?
}

/// An atomic private file, including while the temporary file is being written.
enum DiagnosticFile {
    static func write(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".diagnostics-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CivError("Cannot save diagnostics") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw CivError("Cannot replace diagnostics") }
    }
}

@MainActor public final class DiagnosticLog {
    public private(set) var entries: [DiagnosticEntry] = []
    public private(set) var saved = true
    public private(set) var recoveredUnreadableHistory = false
    public let session = UUID()
    public private(set) var configuration = 0
    private let file: URL
    public init(directory: URL) {
        file = directory.appendingPathComponent("diagnostics.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 128 * 1_024 else { throw CivError("Diagnostic history too large") }
                entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(contentsOf: file))
            } catch { recoveredUnreadableHistory = true }
        }
        trim()
    }
    public func configurationChanged() { configuration += 1; record(.settingsChanged) }
    public func record(_ action: DiagnosticAction, target: DiagnosticTarget? = nil, failure: DiagnosticFailure? = nil,
                       received: Int? = nil, sent: Int? = nil) {
        entries.append(DiagnosticEntry(at: Date(), session: session, configuration: configuration, action: action,
                                       target: target, failure: failure, received: received, sent: sent))
        trim()
        do { try DiagnosticFile.write(JSONEncoder().encode(entries), to: file); saved = true }
        catch { saved = false } // Reporting must never prevent participation or startup.
    }
    private func trim() {
        let cutoff = Date().addingTimeInterval(-86_400)
        entries = Array(entries.filter { $0.at >= cutoff }.suffix(100))
    }
    public func recentEntries() -> [DiagnosticEntry] { trim(); return entries }
}

public struct RelayDiagnostic: Codable {
    public let index: Int
    public let isPilot: Bool
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastFailure: DiagnosticFailure?
    public var nextAttempt: Date?
    public var consecutiveFailures: Int
    public let acknowledgedEvents: Int
    public let pendingEvents: Int
}

public struct NodeDiagnostic: Codable {
    public let session: UUID
    public let configuration: Int
    public let status: String
    public let listening: Bool
    public let paused: Bool
    public let internetEnabled: Bool
    public let lanEnabled: Bool
    public let syncing: Bool
    public let syncSeconds: Int
    public let localPeerCount: Int
    public let eventCount: Int
    public let storageBytes: Int
    public let storageLimitBytes: Int
    public let syncBytesToday: Int
    public let dailySyncLimitBytes: Int
    public let historySaved: Bool
    public let recoveredUnreadableHistory: Bool
    public let relays: [RelayDiagnostic]
    public let recentActivity: [DiagnosticEntry]
}

public struct DiagnosticReport: Encodable {
    public let schemaVersion = 1
    public let capturedAt = Date()
    public let appVersion: String
    public let build: String
    public let buildConfiguration: String
    public let osVersion: String
    public let architecture: String
    public let node: NodeDiagnostic?
    public let startupFailure: DiagnosticFailure?
    public let scope = "Settings do not prove delivery. Relay acknowledgements do not prove receipt on another Mac. Targets are numbered within each session and configuration. History is limited to 100 entries from the last 24 hours; relay attempt times cover this session."

    public init(node: NodeDiagnostic?, startupFailure: DiagnosticFailure? = nil, bundle: Bundle = .main) {
        self.node = node; self.startupFailure = startupFailure
        appVersion = bundle.object(forInfoDictionaryKey: "FourthCivReleaseVersion") as? String ?? "development"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        #if DEBUG
        buildConfiguration = "debug"
        #else
        buildConfiguration = "release"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "other"
        #endif
    }
    public func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum BugReport {
    public static let issueURL = URL(string: "https://github.com/toddsherman/fourthciv/issues/new?template=bug_report.yml")!
    public static func markdown(summary: String, expected: String, steps: String, input: String, diagnostics: String) -> String {
        """
        # Fourth Civ bug report

        ## What happened
        \(summary)

        ## Expected behavior
        \(expected)

        ## Steps to reproduce
        \(steps)

        ## Optional input, command, or event ID (provided by reporter)
        \(input.isEmpty ? "Not included." : input)

        ## Diagnostics
        ```json
        \(diagnostics)
        ```
        """
    }
}
