import Foundation

/// Runs one of the command-line tools that ship with macOS and collects what it prints.
enum Subprocess {
    struct Result: Sendable {
        let status: Int32
        let output: String
        let errorOutput: String
    }

    /// Runs with LC_ALL=en_US.UTF-8. The working directory is /var/empty, which macOS keeps empty and read-only, so a relative
    /// argument never names a real file (zip, for one, handles a name that exists on disk differently).
    /// `input` goes to standard input unless `standardInput` replaces that pipe with an open file.
    /// Cancelling the task terminates the process and throws `CancellationError`.
    static func run(
        _ executable: String,
        _ arguments: [String],
        input: Data = Data(),
        standardInput: FileHandle? = nil
    ) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        // zip and unzip read and print names in the locale's encoding. An app started from Finder has no
        // LANG, and unzip then prints every non-ASCII byte as "?", which zip reads as a wildcard.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = standardInput ?? inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        let result = await withTaskCancellationHandler {
            collect(process, input: standardInput == nil ? input : nil, inputPipe, outputPipe, errorPipe)
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        return result
    }

    /// Writes standard input and drains standard error on their own threads while this one reads
    /// standard output, so a tool that fills one pipe while waiting on another cannot deadlock.
    private static func collect(_ process: Process, input: Data?, _ inputPipe: Pipe, _ outputPipe: Pipe, _ errorPipe: Pipe) -> Result {
        let group = DispatchGroup()
        let errorOutput = Buffer()
        DispatchQueue.global().async(group: group) {
            errorOutput.data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        if let input {
            let writer = inputPipe.fileHandleForWriting
            // A tool that exits before reading all of its input must not take this process down with SIGPIPE.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async(group: group) {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        let output = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        group.wait()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            errorOutput: String(decoding: errorOutput.data, as: UTF8.self)
        )
    }

    /// Written by one reader thread and read only after `DispatchGroup.wait()`, which orders the two.
    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }
}
