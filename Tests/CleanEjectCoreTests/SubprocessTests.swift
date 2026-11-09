import XCTest
@testable import CleanEjectCore

final class SubprocessTests: XCTestCase {
    /// More than a pipe buffer in each direction at once must not deadlock.
    func testPassesLargeInputThrough() async throws {
        let input = Data((0..<500_000).map { _ in UInt8.random(in: 0x41...0x5A) })

        let result = try await Subprocess.run("/bin/cat", [], input: input)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(Data(result.output.utf8), input)
    }

    func testCollectsStatusAndErrorOutput() async throws {
        let result = try await Subprocess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])

        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.output, "out\n")
        XCTAssertEqual(result.errorOutput, "err\n")
    }

    func testRunsInAnEmptyDirectory() async throws {
        let result = try await Subprocess.run("/bin/pwd", ["-P"])
        XCTAssertEqual(result.output, "/private/var/empty\n")
    }

    func testRunsWithAUTF8Locale() async throws {
        let result = try await Subprocess.run("/usr/bin/env", [])
        XCTAssertTrue(result.output.split(separator: "\n").contains("LC_ALL=en_US.UTF-8"), result.output)
    }

    func testCancellationTerminatesTheProcess() async throws {
        let started = Date()
        let task = Task {
            try await Subprocess.run("/bin/sleep", ["30"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the process must be terminated, not waited for")
    }
}
