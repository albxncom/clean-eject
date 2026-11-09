import Foundation

@main
enum Main {
    static func main() async {
        let console = Console(
            out: { FileHandle.standardOutput.write(Data($0.utf8)) },
            err: { FileHandle.standardError.write(Data($0.utf8)) },
            errIsTerminal: isatty(STDERR_FILENO) == 1
        )
        let runner = Runner(console: console)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            console.err(Help.text)
            exit(ExitCode.usage)
        }
        exit(await runner.run(arguments: arguments))
    }
}
