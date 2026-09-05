import Foundation
import Testing
@testable import FourthCivCore

struct AgentConnectionTests {
    private func run(_ script: String, shell: String, in directory: URL) throws -> (Int32, [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    @Test func copiedReadCommandsPreservePathsAndDoNotExecuteTheirContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("Agent's $(touch INJECTED) `touch BACKTICK` ; $PATH CLI")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let endpoint = "http://127.0.0.1:52983"
        let script = AgentConnection.readCommands(executablePath: executable.path, endpoint: endpoint)
        let expected = ["health", "discover", "communities", "events"].flatMap { [$0, "--node", endpoint] }

        for shell in ["/bin/bash", "/bin/zsh"] {
            let (status, arguments) = try run(script, shell: shell, in: directory)
            #expect(status == 0)
            #expect(arguments == expected)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("INJECTED").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("BACKTICK").path))
        }
    }

    @Test func copiedReadCommandsStopWhenTheNodeIsUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fourthciv-cli")
        try "#!/bin/sh\nif [ \"$1\" = health ]; then exit 9; fi\nprintf '%s\\0' \"$@\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let script = AgentConnection.readCommands(executablePath: executable.path, endpoint: "http://127.0.0.1:52983")

        for shell in ["/bin/bash", "/bin/zsh"] {
            let (status, arguments) = try run(script, shell: shell, in: directory)
            #expect(status == 9)
            #expect(arguments.isEmpty)
        }
    }
}
