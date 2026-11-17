import Foundation

// Strict argument parsing for the `majortom` CLI (no third-party dependency needed for six subcommands).
//
// Every command lists the flags it accepts. Anything else (an unknown or misspelt flag, a valued flag without its
// value, a repeated single-value flag, `=value` on a boolean flag, a stray positional argument) is an error, so a
// flag the parser doesn't understand can never be dropped silently and widen what `clean` selects.

/// A usage error. `message` is complete (it already includes the relevant usage text); the CLI prints it to
/// stderr and exits non-zero.
public struct CLIError: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The flags one command accepts.
public struct CommandSpec: Sendable {
    public var name: String
    /// One-line synopsis, e.g. `majortom rules [--json]`.
    public var synopsis: String
    /// Extra explanation printed under the synopsis by `majortom <command> --help`.
    public var details: String
    /// Flags that take a value and may be repeated (`--rule a --rule b`).
    public var repeatable: Set<String> = []
    /// Flags that take exactly one value.
    public var single: Set<String> = []
    /// Single-value flags whose value must be a whole number >= 0.
    public var numeric: Set<String> = []
    /// Flags that take no value.
    public var booleans: Set<String> = []

    var valued: Set<String> { repeatable.union(single) }

    public var usage: String {
        "USAGE\n  \(synopsis)" + (details.isEmpty ? "" : "\n\n\(details)")
    }
}

public enum CLI {
    public static let helpFlags: Set<String> = ["--help", "-h"]

    public static let commands: [CommandSpec] = [
        CommandSpec(
            name: "scan",
            synopsis: "majortom scan [--rule <id>]... [--items] [--json] [--large-mb N] [--old-days N] [--old-min-mb N]",
            details: """
            Scans every enabled rule (or only the --rule ones) and reports what could be reclaimed. Read-only.
            --large-mb / --old-days / --old-min-mb override the Files thresholds from Settings
            for this run only (they are not saved).
            """,
            repeatable: ["--rule"], single: ["--large-mb", "--old-days", "--old-min-mb"],
            numeric: ["--large-mb", "--old-days", "--old-min-mb"], booleans: ["--items", "--json"]),
        CommandSpec(
            name: "rules", synopsis: "majortom rules [--json]",
            details: "Lists every rule with its id, tier and impact.",
            booleans: ["--json"]),
        CommandSpec(
            name: "clean",
            synopsis: "majortom clean --rule <id> [--item <id>]... [--flagged] [--action <id>] [--execute] [--json]",
            details: """
            clean is a DRY RUN unless --execute is given. Without --item or --flagged, every cleanable
            item of the rule is selected (protected and report-only items are never touched).
            Each --item must name exactly one cleanable item of the rule (by id or display name;
            see `majortom scan --rule <id> --json`), otherwise nothing is cleaned. --flagged keeps
            only flagged items. --action runs a rule-level action instead and can't be combined
            with --item or --flagged.
            """,
            repeatable: ["--item"], single: ["--rule", "--action"], booleans: ["--flagged", "--execute", "--json"]),
        CommandSpec(
            name: "history", synopsis: "majortom history [--json]",
            details: "Lists past cleans and how much space each reclaimed.",
            booleans: ["--json"]),
        CommandSpec(
            name: "projects", synopsis: "majortom projects [--stale] [--dirs] [--json]",
            details: """
            projects lists projects under the configured roots with their strippable
            directories (sizes, restore commands, git warnings). It never changes anything;
            hibernating is done from the app's review sheet.
            """,
            booleans: ["--stale", "--dirs", "--json"]),
        CommandSpec(
            name: "offload", synopsis: "majortom offload [--candidates] [--json]",
            details: """
            offload shows whether the NAS destination is a mounted network share, and what
            has been offloaded (with each archive's restore command). --candidates also lists
            what could be offloaded (stale projects, Xcode Archives, large cold files) with
            sizes. It never copies, moves or deletes anything; offloading and restoring are
            done from the app.
            """,
            booleans: ["--candidates", "--json"]),
    ]

    public static func spec(_ name: String) -> CommandSpec? { commands.first { $0.name == name } }

    public static var usage: String {
        """
        majortom — Ground Control's command line

        USAGE
        \(commands.map { "  " + $0.synopsis }.joined(separator: "\n"))
          majortom help [<command>]      (or --help / -h anywhere)

        clean is a DRY RUN unless --execute is given. Without --item or --flagged, every
        cleanable item of the rule is selected (protected and report-only items are never
        touched); an --item that matches nothing is an error, never "everything".

        projects and offload only list; hibernating, offloading and restoring are done in the app.
        Run `majortom <command> --help` for details.
        """
    }

    /// The help text for a command, or the general usage.
    public static func help(for command: String?) -> String {
        guard let command, let spec = spec(command) else { return usage }
        return spec.usage
    }
}

/// What the command line asks for.
public enum ParsedCommand: Equatable, Sendable {
    /// Print help (for `command`, or the general usage when nil) and exit 0.
    case help(command: String?)
    case run(Invocation)
}

/// A validated invocation of one command.
public struct Invocation: Equatable, Sendable {
    public var command: String
    public var flags: Set<String> = []
    public var values: [String: [String]] = [:]

    public init(command: String, flags: Set<String> = [], values: [String: [String]] = [:]) {
        self.command = command
        self.flags = flags
        self.values = values
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }
    /// The value of a single-value flag.
    public func value(_ flag: String) -> String? { values[flag]?.first }
    public func all(_ flag: String) -> [String] { values[flag] ?? [] }
    /// A numeric flag's value (already validated by the parser).
    public func int(_ flag: String) -> Int? { value(flag).flatMap { Int($0) } }
}

extension CLI {
    /// Parses `argv` (including the program name at index 0). Throws `CLIError` (with usage) on anything it
    /// does not fully understand; never ignores an argument.
    public static func parse(_ argv: [String]) throws(CLIError) -> ParsedCommand {
        let args = Array(argv.dropFirst())
        guard let first = args.first else { throw CLIError(usage) }

        // --help / -h anywhere wins: print help, do nothing else.
        if args.contains(where: { helpFlags.contains($0) }) {
            if helpFlags.contains(first) {
                // `majortom --help [command]`
                let next = args.dropFirst().first { !helpFlags.contains($0) }
                if let next, !next.hasPrefix("-"), spec(next) != nil { return .help(command: next) }
                return .help(command: nil)
            }
            if first == "help" { return .help(command: nil) }
            guard spec(first) != nil else { throw unknownCommand(first) }
            return .help(command: first)
        }

        if first == "help" {
            let rest = args.dropFirst()
            guard rest.count <= 1 else { throw CLIError("help takes at most one command\n\n\(usage)") }
            guard let topic = rest.first else { return .help(command: nil) }
            guard spec(topic) != nil else { throw unknownCommand(topic) }
            return .help(command: topic)
        }
        guard let spec = spec(first) else { throw unknownCommand(first) }

        var inv = Invocation(command: first)
        func fail(_ message: String) -> CLIError {
            CLIError("majortom \(spec.name): \(message)\n\n\(spec.usage)")
        }

        var i = 1
        while i < args.count {
            let arg = args[i]
            i += 1
            guard arg.hasPrefix("-"), arg != "-", arg != "--" else {
                throw fail("unexpected argument: \(arg)")
            }
            guard arg.hasPrefix("--") else { throw fail("unknown option: \(arg)") }

            var name = arg
            var inline: String?
            if let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }

            if spec.booleans.contains(name) {
                if inline != nil { throw fail("\(name) doesn't take a value (got \(arg))") }
                if inv.flags.contains(name) { throw fail("\(name) given more than once") }
                inv.flags.insert(name)
            } else if spec.valued.contains(name) {
                let value: String
                if let inline {
                    value = inline
                } else {
                    // A following option is not a value: `--rule --execute` must not swallow `--execute`.
                    guard i < args.count, !args[i].hasPrefix("-") else { throw fail("\(name) needs a value") }
                    value = args[i]
                    i += 1
                }
                if value.isEmpty { throw fail("\(name) needs a value") }
                if spec.single.contains(name), inv.values[name] != nil {
                    throw fail("\(name) given more than once")
                }
                if spec.numeric.contains(name) {
                    guard let n = Int(value), n >= 0 else { throw fail("\(name) needs a whole number (got \(value))") }
                }
                inv.values[name, default: []].append(value)
            } else {
                throw fail("unknown option: \(name)")
            }
        }

        try validate(inv, spec: spec, fail: fail)
        return .run(inv)
    }

    /// Cross-flag rules that keep a command from meaning more than it says.
    private static func validate(_ inv: Invocation, spec: CommandSpec,
                                 fail: (String) -> CLIError) throws(CLIError) {
        guard spec.name == "clean" else { return }
        if inv.value("--rule") == nil { throw fail("clean needs exactly one --rule <id>") }
        // An action is rule-wide; item filters can't narrow it, so refuse rather than ignore them.
        if inv.value("--action") != nil, inv.values["--item"] != nil || inv.has("--flagged") {
            throw fail("--action runs a rule-level action and can't be combined with --item or --flagged")
        }
    }

    private static func unknownCommand(_ name: String) -> CLIError {
        CLIError("unknown command: \(name)\n\n\(usage)")
    }
}
