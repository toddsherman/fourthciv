import Foundation
import Darwin
import Testing
@testable import FourthCivCore

struct StoreLockTests {
    @Test @MainActor func childProcessCannotKeepAClosedStoreLocked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: EventStore? = try EventStore(directory: directory)
        #expect(throws: (any Error).self) { _ = try EventStore(directory: directory) }

        // Use ordinary POSIX inheritance even on OS versions where Foundation.Process closes extra FDs.
        var input = [Int32](repeating: -1, count: 2), output = [Int32](repeating: -1, count: 2)
        defer { for fd in input + output where fd >= 0 { Darwin.close(fd) } }
        try #require(pipe(&input) == 0)
        try #require(pipe(&output) == 0)
        for fd in input + output { try #require(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0) }
        var actions: posix_spawn_file_actions_t?
        try #require(posix_spawn_file_actions_init(&actions) == 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        try #require(posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0)
        try #require(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0)
        for fd in input + output { try #require(posix_spawn_file_actions_addclose(&actions, fd) == 0) }
        let executable = strdup("/bin/cat")!
        defer { free(executable) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var child: pid_t = 0
        try #require(posix_spawn(&child, executable, &actions, nil, &arguments, &environment) == 0)
        defer {
            kill(child, SIGTERM)
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
        Darwin.close(input[0]); input[0] = -1
        Darwin.close(output[1]); output[1] = -1
        let handshake = Data("ready\n".utf8)
        try FileHandle(fileDescriptor: input[1], closeOnDealloc: false).write(contentsOf: handshake)
        #expect(try FileHandle(fileDescriptor: output[0], closeOnDealloc: false).read(upToCount: handshake.count) == handshake)
        #expect(kill(child, 0) == 0)

        // A child that has exec'd must not retain the store's lock after its owner closes it.
        withExtendedLifetime(store) {}
        store = nil
        let reopened = try EventStore(directory: directory)
        #expect(kill(child, 0) == 0)
        #expect(throws: (any Error).self) { _ = try EventStore(directory: directory) }
        withExtendedLifetime(reopened) {}
    }
}
