import Foundation
import Testing
@testable import MajorTomCLI
@testable import MajorTomCore

private func parse(_ args: String...) throws(CLIError) -> ParsedCommand {
    try CLI.parse(["majortom"] + args)
}

private func run(_ args: String...) throws -> Invocation {
    guard case .run(let inv) = try CLI.parse(["majortom"] + args) else {
        Issue.record("expected a runnable command for \(args)")
        throw CLIError("not runnable")
    }
    return inv
}

/// The parse error for `args`, or nil when it parsed.
private func failure(_ args: String...) -> CLIError? { failure(args) }

private func failure(_ args: [String]) -> CLIError? {
    do { _ = try CLI.parse(["majortom"] + args); return nil } catch { return error }
}

@Suite("CLI: argument parsing")
struct CLIArgumentsTests {
    @Test func issue2CommandKeepsTheItemFilter() throws {
        let inv = try run("clean", "--rule", "old-files", "--item=/path/to/file", "--execute")
        #expect(inv.command == "clean")
        #expect(inv.value("--rule") == "old-files")
        #expect(inv.all("--item") == ["/path/to/file"])
        #expect(inv.flags == ["--execute"])
    }

    @Test func equalsFormValues() throws {
        #expect(try run("clean", "--rule=npm-cache", "--item=x=y").all("--item") == ["x=y"])
        #expect(try run("scan", "--rule=a", "--rule", "b", "--large-mb=5").all("--rule") == ["a", "b"])
        #expect(try run("scan", "--large-mb=5").int("--large-mb") == 5)
        #expect(try run("clean", "--rule=npm-cache") == run("clean", "--rule", "npm-cache"))
    }

    @Test func unknownFlagsAreRejectedNamingTheArgument() {
        for (args, bad) in [(["scan", "--jsn"], "--jsn"), (["clean", "--rule", "npm-cache", "--exectue"], "--exectue"),
                            (["clean", "--rule", "npm-cache", "--items"], "--items"), (["rules", "--stale"], "--stale"),
                            (["projects", "--candidates"], "--candidates"), (["offload", "-x"], "-x"),
                            (["clean", "--rule", "old-files", "--large-mb", "0"], "--large-mb")] {
            let error = failure(args)
            #expect(error != nil, "\(args) should fail")
            #expect(error?.message.contains("unknown option: \(bad)") == true, "\(args): \(error?.message ?? "")")
            #expect(error?.message.contains("USAGE") == true)
            #expect(error?.message.contains("majortom \(args[0])") == true)
        }
    }

    @Test func unknownFlagWithEqualsIsRejected() {
        #expect(failure("clean", "--rule", "npm-cache", "--itme=foo")?.message.contains("unknown option: --itme") == true)
    }

    @Test func valuedFlagMissingItsValue() {
        #expect(failure("clean", "--rule")?.message.contains("--rule needs a value") == true)
        #expect(failure("clean", "--rule", "npm-cache", "--item")?.message.contains("--item needs a value") == true)
        #expect(failure("clean", "--rule=")?.message.contains("--rule needs a value") == true)
        // The next option is not swallowed as the value.
        #expect(failure("clean", "--rule", "npm-cache", "--item", "--execute")?.message
            .contains("--item needs a value") == true)
        #expect(failure("scan", "--old-days")?.message.contains("--old-days needs a value") == true)
    }

    @Test func repeatedSingleValueFlags() {
        #expect(failure("clean", "--rule", "a", "--rule", "b")?.message.contains("--rule given more than once") == true)
        #expect(failure("clean", "--rule", "a", "--rule=a")?.message.contains("--rule given more than once") == true)
        #expect(failure("clean", "--rule", "a", "--action", "x", "--action", "y")?.message
            .contains("--action given more than once") == true)
        #expect(failure("scan", "--large-mb", "1", "--large-mb=2")?.message.contains("--large-mb given more than once") == true)
        #expect(failure("scan", "--json", "--json")?.message.contains("--json given more than once") == true)
    }

    @Test func repeatableFlagsCollectEveryValue() throws {
        #expect(try run("clean", "--rule", "r", "--item", "a", "--item=b").all("--item") == ["a", "b"])
    }

    @Test func booleanFlagsRejectAValue() {
        #expect(failure("clean", "--rule", "r", "--execute=false")?.message.contains("--execute doesn't take a value") == true)
        #expect(failure("scan", "--json=1")?.message.contains("--json doesn't take a value") == true)
    }

    @Test func unexpectedPositionalArguments() {
        #expect(failure("clean", "--rule", "r", "/path/to/file")?.message.contains("unexpected argument: /path/to/file") == true)
        #expect(failure("scan", "extra")?.message.contains("unexpected argument: extra") == true)
        #expect(failure("history", "--")?.message.contains("unexpected argument: --") == true)
        #expect(failure("rules", "-")?.message.contains("unexpected argument: -") == true)
    }

    @Test func numericFlagsAreValidatedUpFront() {
        #expect(failure("scan", "--large-mb", "lots")?.message.contains("--large-mb needs a whole number") == true)
        #expect(failure("scan", "--old-days=-3")?.message.contains("--old-days needs a whole number") == true)
    }

    @Test func cleanNeedsARule() {
        let e = failure("clean", "--execute")
        #expect(e?.message.contains("clean needs exactly one --rule") == true)
        #expect(e?.message.contains("USAGE") == true)
    }

    @Test func actionCannotBeNarrowedByItemFilters() {
        #expect(failure("clean", "--rule", "pnpm-store", "--action", "prune", "--item", "x")?.message
            .contains("can't be combined") == true)
        #expect(failure("clean", "--rule", "pnpm-store", "--action=prune", "--flagged")?.message
            .contains("can't be combined") == true)
    }

    @Test func executeIsTheOnlyWayToARealClean() throws {
        #expect(try run("clean", "--rule", "r").has("--execute") == false)
        #expect(try run("clean", "--rule", "r", "--json", "--flagged").has("--execute") == false)
        #expect(try run("clean", "--rule", "r", "--execute").has("--execute"))
    }

    @Test func helpAnywhereWins() throws {
        #expect(try parse("--help") == .help(command: nil))
        #expect(try parse("-h") == .help(command: nil))
        #expect(try parse("help") == .help(command: nil))
        #expect(try parse("help", "clean") == .help(command: "clean"))
        #expect(try parse("--help", "scan") == .help(command: "scan"))
        #expect(try parse("scan", "--help") == .help(command: "scan"))
        #expect(try parse("scan", "-h", "--json") == .help(command: "scan"))
        // Even next to bad or dangerous arguments, help does nothing else.
        #expect(try parse("clean", "--rule", "old-files", "--execute", "--help") == .help(command: "clean"))
        #expect(try parse("clean", "--bogus", "-h") == .help(command: "clean"))
        #expect(try parse("clean", "--item", "--help") == .help(command: "clean"))
    }

    @Test func helpTextIsPerCommand() {
        let clean = CLI.help(for: "clean")
        #expect(clean.contains("majortom clean --rule <id>"))
        #expect(clean.contains("DRY RUN"))
        #expect(!clean.contains("majortom scan [--rule"))
        #expect(CLI.help(for: nil).contains("majortom offload"))
        for spec in CLI.commands { #expect(CLI.usage.contains(spec.synopsis)) }
    }

    @Test func unknownCommandsFail() {
        #expect(failure("sacn")?.message.contains("unknown command: sacn") == true)
        #expect(failure("sacn")?.message.contains("USAGE") == true)
        #expect(failure("sacn", "--help")?.message.contains("unknown command: sacn") == true)
        #expect(failure("help", "sacn")?.message.contains("unknown command: sacn") == true)
        #expect(failure("--json")?.message.contains("unknown command: --json") == true)
        #expect(failure()?.message.contains("USAGE") == true)
    }
}
