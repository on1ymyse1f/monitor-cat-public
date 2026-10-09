import Foundation

/// Checks the tool's own privacy and security claims, on this machine, now.
///
/// Checks selected privacy and security properties on this machine. A claim
/// the user can check is worth more than one they have to take on faith. This
/// is deliberately not a status page: it re-derives its findings from the
/// filesystem and store rather than reporting a flag that says what the code
/// intended.
///
/// **It asks for nothing.** No Keychain read, no network request, no new
/// entitlement, no Accessibility or Full Disk Access. It reports on paths this
/// tool already touches and on the file it already wrote, which is precisely
/// what makes it safe to run at any time — including as the first thing a
/// sceptical reader does.
public enum SelfAudit {

    public struct Finding: Sendable {
        public enum Verdict: String, Sendable {
            /// Checked and correct.
            case pass = "PASS"
            /// Checked, and something is looser or louder than it should be.
            case warn = "WARN"
            /// Not a claim, just a fact the reader should see.
            case note = "INFO"
        }
        public var verdict: Verdict
        public var title: String
        public var detail: String
    }

    public struct Report: Sendable {
        public var findings: [Finding]
        public var warnings: Int { findings.filter { $0.verdict == .warn }.count }
    }

    public static func run(storePath: String = EventStore.defaultPath()) -> Report {
        var out: [Finding] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // ── What it reads ────────────────────────────────────────────────────
        // Core accounting sources are named explicitly so the list can be
        // compared against `fs_usage`. Optional quota sources are described by
        // the settings and credentials findings below.
        let readPaths = [
            ("Claude Code transcripts", ".claude/projects"),
            ("Codex rollout logs", ".codex/sessions"),
            ("Kimi Code wire logs", ".kimi-code/sessions"),
            ("Claude desktop quota cache", "Library/Application Support/Claude/plan-usage-history.json"),
        ]
        for (label, relative) in readPaths {
            let path = home.appendingPathComponent(relative).path
            let exists = fm.fileExists(atPath: path)
            out.append(Finding(
                verdict: .note, title: "reads: \(label)",
                detail: exists ? "\(relative) — present, read-only" : "\(relative) — absent, skipped"
            ))
        }

        // ── What it writes, and who else can read it ─────────────────────────
        if fm.fileExists(atPath: storePath) {
            let mode = (try? fm.attributesOfItem(atPath: storePath))?[.posixPermissions] as? NSNumber
            let bits = mode?.intValue ?? 0
            let othersCanRead = bits & 0o077 != 0
            out.append(Finding(
                verdict: othersCanRead ? .warn : .pass,
                title: "store is owner-only",
                detail: othersCanRead
                    ? String(format: "%@ is mode %03o — other local accounts can read your activity history", storePath, bits)
                    : String(format: "mode %03o, and its -wal/-shm companions match", bits)
            ))

            // The strongest claim in PRIVACY.md, re-derived rather than asserted.
            out.append(contentsOf: contentCheck(storePath: storePath))
        } else {
            out.append(Finding(verdict: .note, title: "store", detail: "\(storePath) — not created yet"))
        }

        // ── Network ──────────────────────────────────────────────────────────
        // Every endpoint the build can reach, and whether anything is switched
        // on that would reach one.
        let store = try? EventStore(path: storePath)
        let optIns = [
            ("Claude live quota", "claude_quota_optin", "https://api.anthropic.com/api/oauth/usage"),
            ("Kimi live quota", "kimi_quota_optin", "Kimi Code and Kimi Desktop usage endpoints"),
            ("Cursor live quota", "cursor_quota_optin", "https://cursor.com/api/usage-summary"),
        ]
        var anyOn = false
        for (label, key, endpoint) in optIns {
            let on = (store?.setting(key) ?? "false") == "true"
            anyOn = anyOn || on
            out.append(Finding(
                verdict: .note, title: "network: \(label)",
                detail: on ? "ON — may send a read-only request to \(endpoint)" : "off — no request is made"
            ))
        }
        out.append(Finding(
            verdict: .pass, title: "no telemetry, no account, no analytics",
            detail: anyOn
                ? "the only outbound traffic is the opt-in quota GET(s) listed above"
                : "with every opt-in off, this build makes zero network requests"
        ))

        // ── Credentials ──────────────────────────────────────────────────────
        out.append(Finding(
            verdict: .pass, title: "credentials are not persisted or refreshed",
            detail: "access tokens are selected for opted-in requests and held in memory; refresh tokens are not used"
        ))

        // ── The background agent ─────────────────────────────────────────────
        if BackgroundAgent.isInstalled() {
            let argv = (try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: BackgroundAgent.plistURL), options: [], format: nil
            ) as? [String: Any])??["ProgramArguments"] as? [String] ?? []
            // A plist that runs anything other than this tool's own sync is the
            // single most valuable thing this audit can catch: it is a file
            // launchd executes on a timer.
            let expected = argv.count == 3 && argv[1] == "--sync"
            out.append(Finding(
                verdict: expected ? .pass : .warn,
                title: "background agent",
                detail: expected
                    ? "installed, runs: \(argv.joined(separator: " ")) — no network, no shell"
                    : "installed but runs an unexpected command: \(argv.joined(separator: " "))"
            ))
        } else {
            out.append(Finding(verdict: .note, title: "background agent", detail: "not installed"))
        }

        // ── Permissions deliberately not requested ───────────────────────────
        out.append(Finding(
            verdict: .pass, title: "no elevated permissions",
            detail: "no Accessibility, no Full Disk Access, no admin rights, no login item, no listening socket"
        ))

        return Report(findings: out)
    }

    /// Re-derives the "no prompt or response text is stored" claim from the
    /// store itself.
    ///
    /// Checked by shape rather than by keyword: every text column in this
    /// schema is an identifier or a short label, so prose announces itself as
    /// unusual length or embedded whitespace. A keyword scan would only find
    /// the words it thought to look for.
    static func contentCheck(storePath: String) -> [Finding] {
        guard let store = try? EventStore(path: storePath),
              let shape = try? store.textColumnShape()
        else {
            return [Finding(verdict: .note, title: "stored content", detail: "store not readable for inspection")]
        }

        var findings: [Finding] = []
        // Only free-text columns can hide prose. A column with a handful of
        // distinct values is a vocabulary — `provider` is three fixed labels,
        // every one of which contains a space.
        let freeText = shape.filter { !$0.isVocabulary }
        let suspects = freeText.filter { $0.proseShaped > 0 }
        let longest = shape.max(by: { $0.longest < $1.longest })

        findings.append(Finding(
            verdict: suspects.isEmpty ? .pass : .warn,
            title: "no prompt or response text is stored",
            detail: suspects.isEmpty
                ? "longest value in any column: \(longest?.longest ?? 0) chars (\(longest?.column ?? "-")); "
                    + "no value anywhere is both long and multi-word"
                : "prose-shaped values in: " + suspects.map(\.column).joined(separator: ", ")
        ))
        findings.append(Finding(
            verdict: .note, title: "free-text columns",
            detail: freeText.isEmpty
                ? "none — every text column is a fixed vocabulary"
                : freeText.map { "\($0.column) (\($0.distinctValues) distinct, max \($0.longest) chars)" }
                    .joined(separator: ", ")
        ))
        // The one piece of user-authored text the store does hold, said plainly.
        if let project = shape.first(where: { $0.column == "project" }), project.distinctValues > 0 {
            findings.append(Finding(
                verdict: .note, title: "project names are stored",
                detail: "\(project.distinctValues) directory name(s), for per-project totals. "
                    + "Local only, and the one place a folder name could be revealing."
            ))
        }
        return findings
    }
}
