import CryptoKit
import Foundation

/// A known native governing-text presentation only. Callers must supply ONLY
/// current trusted instruction fields under the native registered-history flag.
/// Raw native configuration, permissions and executor admission stay unchanged.
enum GroqNativePermissionPresentation {
    struct Replacement: Sendable {
        let partIndex: Int
        let sourceUTF8: Data
        let range: Range<Int>
        let replacementUTF8: Data
    }
    // Pinned first-party prompts/templates/permissions/approval_policy/on_request.md.
    // Full source INCLUDING final LF: 3661B / SHA85541a9738741407642b3c39bbe3781fbf8bb42f628d50e562c87738ab192b3a.
    static let fullSource = """
    # Escalation Requests

    Commands are run outside the sandbox if they are approved by the user, or match an existing rule that allows it to run unrestricted. The command string is split into independent command segments at shell control operators, including but not limited to:

    - Pipes: |
    - Logical operators: &&, ||
    - Command separators: ;
    - Subshell boundaries: (...), $(...)

    Each resulting segment is evaluated independently for sandbox restrictions and approval requirements.

    Example:

    git pull | tee output.txt

    This is treated as two command segments:

    ["git", "pull"]

    ["tee", "output.txt"]

    Commands that use more advanced shell features like redirection (>, >>, <), substitutions ($(...), ...), environment variables (FOO=bar), or wildcard patterns (*, ?) will not be evaluated against rules, to limit the scope of what an approved rule allows.

    ## How to request escalation

    IMPORTANT: To request approval to execute a command that will require escalated privileges:

    - Provide the `sandbox_permissions` parameter with the value `"require_escalated"`
    - Include a short question asking the user if they want to allow the action in `justification` parameter. e.g. "Do you want to download and install dependencies for this project?"
    - Optionally suggest a `prefix_rule` - this will be shown to the user with an option to persist the rule approval for future sessions.

    If you run a command that is important to solving the user's query, but it fails because of sandboxing or with a likely sandbox-related network error (for example DNS/host resolution, registry/index access, or dependency download failure), rerun the command with "require_escalated". ALWAYS proceed to use the `justification` parameter - do not message the user before requesting approval for the command.

    ## When to request escalation

    While commands are running inside the sandbox, here are some scenarios that will require escalation outside the sandbox:

    - You need to run a command that writes to a directory that requires it (e.g. running tests that write to /var)
    - You need to run a GUI app (e.g., open/xdg-open/osascript) to open browsers or files.
    - If you run a command that is important to solving the user's query, but it fails because of sandboxing or with a likely sandbox-related network error (for example DNS/host resolution, registry/index access, or dependency download failure), rerun the command with `require_escalated`. ALWAYS proceed to use the `sandbox_permissions` and `justification` parameters. do not message the user before requesting approval for the command.
    - You are about to take a potentially destructive action such as an `rm` or `git reset` that the user did not explicitly ask for.
    - Be judicious with escalating, but if completing the user's request requires it, you should do so - don't try and circumvent approvals by using other tools.

    ## prefix_rule guidance

    When choosing a `prefix_rule`, request one that will allow you to fulfill similar requests from the user in the future without re-requesting escalation. It should be categorical and reasonably scoped to similar capabilities. You should rarely pass the entire command into `prefix_rule`.

    ### Banned prefix_rules\u{20}
    Avoid requesting overly broad prefixes that the user would be ill-advised to approve. For example, do not request ["python3"], ["python", "-"], or other similar prefixes that would allow arbitrary scripting.
    NEVER provide a prefix_rule argument for destructive commands like rm.
    NEVER provide a prefix_rule if your command uses a heredoc or herestring.\u{20}

    ### Examples
    Good examples of prefixes:
    - ["npm", "run", "dev"]
    - ["gh", "pr", "check"]
    - ["cargo", "test"]
    """ + "\n"
    // Reviewed 1:1 equivalent including every unique clause and source example.
    static let compactSource = """
    # Escalation Requests
    Outside-sandbox commands follow user approval or an existing rule permitting unrestricted execution. Evaluate every command segment independently at shell controls, including pipes |, logical &&/||, separators ;, and subshell boundaries (...)/$(...). Example: git pull | tee output.txt evaluates ["git","pull"] and ["tee","output.txt"] separately. Advanced forms (redirection >, >>, <; substitutions $(...), ...; environment variables FOO=bar; wildcards *, ?) are not evaluated against rules, limiting approved-rule scope.

    For required escalation set sandbox_permissions="require_escalated" and justification to a short question asking user approval. Optionally propose prefix_rule for a reusable rule the user may persist.

    If an important command fails from sandboxing or a likely sandbox-related network error (including DNS/host resolution, registry/index access or dependency download), rerun it with require_escalated using BOTH sandbox_permissions and justification; ALWAYS request through those parameters, without messaging the user first.

    For sandboxed commands, escalation is required for privileged-directory writes (e.g. tests writing /var), GUI app launches (e.g. open/xdg-open/osascript to open browsers/files), the important sandbox-related failures above, and potentially destructive rm/git reset actions not explicitly requested. Be judicious, but request escalation when needed to finish the user's task; never circumvent approvals through other tools.

    prefix_rule should be categorical, reasonably scoped to similar future work, and rarely the whole command. Avoid overly broad prefixes, including arbitrary-script prefixes such as ["python3"], ["python","-"], or similar forms. Never provide prefix_rule for destructive commands such as rm or commands using a heredoc/herestring. Examples of scoped prefixes: ["npm","run","dev"], ["gh","pr","check"], ["cargo","test"].
    """ + "\n"
    private static let templatesAreCurrent = digest(Data(fullSource.utf8))
        == "85541a9738741407642b3c39bbe3781fbf8bb42f628d50e562c87738ab192b3a"
        && digest(Data(compactSource.utf8)) == "f306874f724edaa783a30df0593f228b6031e78a91c73502e51b6802482cbce2"
    // permissions_instructions.rs sandbox_text trims only these fixed template
    // ends, then renders network_access; append_section supplies each LF.
    private static let sandboxTemplates = [
        "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `danger-full-access`: No filesystem sandboxing - all commands are permitted. Network access is {{ network_access }}.",
        "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `workspace-write`: The sandbox permits reading files, and editing files in `cwd` and `writable_roots`. Editing files in other directories requires approval. Network access is {{ network_access }}.",
        "Filesystem sandboxing defines which files can be read or written. `sandbox_mode` is `read-only`: The sandbox only permits reading files. Network access is {{ network_access }}."
    ]
    private static let prefixes = sandboxTemplates.flatMap { template in
        ["enabled", "restricted"].map { network in
            Data(("\n" + template.replacingOccurrences(of: "{{ network_access }}", with: network) + "\n").utf8)
        }
    }

    static func replacement(in trustedValues: [String], enabled: Bool) -> Replacement? {
        guard enabled, templatesAreCurrent, trustedValues.count <= 128 else { return nil }
        let values = trustedValues.map { Data($0.utf8) }
        guard values.reduce(0, { $0 + $1.count }) <= WebModelResponseCodec.maximumPromptBytes else { return nil }
        let opening = Data("<permissions instructions>".utf8), closing = Data("</permissions instructions>".utf8)
        var found: (Int, Range<Int>, Range<Int>)?
        for (index, bytes) in values.enumerated() {
            let start = bytes.range(of: opening), end = bytes.range(of: closing)
            guard start != nil || end != nil else { continue }
            guard found == nil, let start, let end, start.upperBound <= end.lowerBound,
                  bytes.range(of: opening, in: start.upperBound..<bytes.count) == nil,
                  bytes.range(of: closing, in: end.upperBound..<bytes.count) == nil else { return nil }
            found = (index, start, end)
        }
        guard let (index, start, end) = found else { return nil }
        let bytes = values[index], body = bytes.subdata(in: start.upperBound..<end.lowerBound)
        guard let prefix = prefixes.first(where: { body.starts(with: $0) }) else { return nil }
        let lower = start.upperBound + prefix.count, template = Data(fullSource.utf8)
        guard template.count <= end.lowerBound - lower else { return nil }
        let range = lower..<(lower + template.count)
        guard bytes.subdata(in: range) == template,
              bytes.range(of: template, in: range.upperBound..<end.lowerBound) == nil else { return nil }
        return Replacement(partIndex: index, sourceUTF8: bytes, range: range,
            replacementUTF8: Data(compactSource.utf8))
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
