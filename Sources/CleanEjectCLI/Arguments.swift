import CleanEjectCore

/// What the command line asks for; produced by `Command.parse`, nothing has run yet.
enum Command: Equatable {
    case help
    case list(json: Bool)
    /// `preview` (a dry run that lists every path) and `clean`.
    case run(RunOptions)
    case eject(paths: [String], json: Bool)
}

struct RunOptions: Equatable {
    var paths: [String] = []
    /// A fresh app install's defaults; the flags change them.
    var rules = HiddenFileRules()
    var dryRun = false
    var eject = false
    var verbose = false
    var json = false
}

/// A malformed command line: the message is printed with a hint to `--help`, exit 2, nothing runs.
struct UsageError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

extension Command {
    /// Parses the arguments after the program name. Options may appear anywhere after the command;
    /// `--` ends them. `-h`/`--help` anywhere asks for help.
    static func parse(_ arguments: [String]) throws(UsageError) -> Command {
        guard let name = arguments.first else { throw UsageError("missing command") }
        let rest = Array(arguments.dropFirst())
        if ["help", "-h", "--help"].contains(name) { return .help }
        if rest.prefix(while: { $0 != "--" }).contains(where: { $0 == "-h" || $0 == "--help" }) { return .help }

        switch name {
        case "list":
            var json = false
            var operands = OperandReader(rest)
            while let option = try operands.nextOption() {
                guard option == "--json" else { throw unknown(option, for: name) }
                json = true
            }
            if let extra = operands.paths.first { throw UsageError("list takes no paths, got '\(extra)'") }
            return .list(json: json)

        case "eject":
            var json = false
            var operands = OperandReader(rest)
            while let option = try operands.nextOption() {
                guard option == "--json" else { throw unknown(option, for: name) }
                json = true
            }
            guard !operands.paths.isEmpty else { throw UsageError("eject needs at least one volume path") }
            try rejectEmpty(operands.paths)
            return .eject(paths: operands.paths, json: json)

        case "preview", "clean":
            let isClean = name == "clean"
            var options = RunOptions(dryRun: !isClean, verbose: !isClean)
            var operands = OperandReader(rest)
            while let option = try operands.nextOption() {
                switch option {
                case "--json": options.json = true
                case "--merge-appledouble": options.rules.mergeAppleDouble = true
                case "--prevent-recreation": options.rules.preventRecreation = true
                case "--skip":
                    for ruleName in try operands.value(for: option).split(separator: ",", omittingEmptySubsequences: false) {
                        guard let rule = HiddenFileRules.Rule.toggleable.first(where: { $0.machineName == ruleName }) else {
                            throw UsageError("unknown rule '\(ruleName)' for --skip; rules: "
                                + HiddenFileRules.Rule.toggleable.map(\.machineName).joined(separator: ", "))
                        }
                        options.rules[keyPath: rule.toggle] = false
                    }
                case "--eject" where isClean: options.eject = true
                case "--dry-run" where isClean: options.dryRun = true
                case "-v" where isClean, "--verbose" where isClean: options.verbose = true
                default: throw unknown(option, for: name)
                }
            }
            guard !operands.paths.isEmpty else { throw UsageError("\(name) needs at least one path") }
            try rejectEmpty(operands.paths)
            if options.eject && options.dryRun {
                throw UsageError("--eject cannot be combined with --dry-run: a dry run never ejects")
            }
            options.paths = operands.paths
            return .run(options)

        default:
            throw UsageError("unknown command '\(name)'")
        }
    }

    /// An empty argument (an unset shell variable) would otherwise mean the current directory.
    private static func rejectEmpty(_ paths: [String]) throws(UsageError) {
        if paths.contains("") { throw UsageError("empty path argument") }
    }

    private static func unknown(_ option: String, for command: String) -> UsageError {
        UsageError("unknown option '\(option)' for \(command)")
    }
}

/// Walks the arguments after the command: options are handed out one by one, everything else (and
/// everything after `--`) is collected as a path.
private struct OperandReader {
    private var arguments: ArraySlice<String>
    /// A value given inline as `--option=value`, consumed by the next `value(for:)`.
    private var inlineValue: String?
    private(set) var paths: [String] = []

    init(_ arguments: [String]) {
        self.arguments = arguments[...]
    }

    mutating func nextOption() throws(UsageError) -> String? {
        if inlineValue != nil { throw UsageError("unexpected value in '\(pendingOption)=\(inlineValue!)'") }
        while let argument = arguments.popFirst() {
            if argument == "--" {
                paths += arguments
                arguments = []
                return nil
            }
            guard argument.hasPrefix("-"), argument != "-" else {
                paths.append(argument)
                continue
            }
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                pendingOption = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
                return pendingOption
            }
            pendingOption = argument
            return argument
        }
        return nil
    }

    private var pendingOption = ""

    mutating func value(for option: String) throws(UsageError) -> String {
        if let inlineValue {
            self.inlineValue = nil
            return inlineValue
        }
        guard let value = arguments.popFirst(), value != "--" else { throw UsageError("\(option) needs a value") }
        return value
    }
}

enum Help {
    static var text: String {
        let width = HiddenFileRules.Rule.toggleable.map(\.machineName.count).max() ?? 0
        let rules = HiddenFileRules.Rule.toggleable.map { rule in
            "  " + rule.machineName.padding(toLength: width + 2, withPad: " ", startingAt: 0) + description(of: rule)
        }
        return """
            Usage: cleaneject <command> [options] [--] <path>...

            Removes macOS metadata junk from external volumes, folders and ZIP archives with the
            same rules and refusals as CleanEject.app. Settings come only from the options below;
            the app's settings are not read.

            Commands:
              list                 List mounted external volumes
              preview <path>...    List everything that would be removed, grouped by rule; changes nothing
              clean <path>...      Remove it now and print a per-rule summary
              eject <path>...      Eject volumes without cleaning them
              help                 Show this help

            A path is a volume (its mount point), a folder or a .zip archive; any other file stands for
            the folder that contains it. Folders get only the ds-store and appledouble rules. System
            locations, the startup volume, internal disks and symbolic links are refused. All paths are
            checked first; if any is refused, nothing runs.

            Options:
              --skip <rule>[,<rule>...]  Keep what these rules would remove (repeatable)
              --merge-appledouble        Merge ._ sidecar data into its file before removing it (APFS, HFS+)
              --prevent-recreation       Volumes: write .metadata_never_index and .fseventsd/no_log
              --eject                    clean: eject each volume afterwards (volumes only)
              --dry-run                  clean: change nothing, report what would be removed
              -v, --verbose              clean: also list every path
              --json                     Print one JSON document on stdout
              -h, --help                 Show this help
              --                         End of options

            Rules (all on by default):
            \(rules.joined(separator: "\n"))

            Removing .Spotlight-V100 needs Full Disk Access for your terminal app
            (System Settings > Privacy & Security > Full Disk Access).

            Exit status: 0 success, 1 a path was refused or a removal or eject failed, 2 usage error.

            """
    }

    private static func description(of rule: HiddenFileRules.Rule) -> String {
        switch rule {
        case .dsStore: ".DS_Store in every folder"
        case .appleDouble, .macosxFolder: "._* AppleDouble files in every folder, __MACOSX in archives"
        case .spotlight: ".Spotlight-V100 (Spotlight index) at the top level"
        case .fsevents: ".fseventsd (file system events journal) at the top level"
        case .trashes: ".Trashes at the top level"
        case .temporaryItems: ".TemporaryItems at the top level"
        case .apdisk: ".apdisk at the top level"
        }
    }
}
