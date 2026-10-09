# AI Monitor Station

AI Monitor Station (`aimonitor`) is a local-first usage monitor for AI coding
tools on macOS and Windows. It reads accounting metadata already written by
those tools, stores a local history, and reports token use, API-equivalent cost,
and quota when a provider exposes a verifiable source.

Every figure has a confidence marker:

| Marker | Meaning |
| --- | --- |
| `exact` | Taken from provider accounting without lossy reconstruction. |
| `est.` | Reconstructed from local records; the report explains the caveat. |
| `n/a` | Not derivable from available data. It is reported as unavailable, not zero. |

## Supported platforms

- **macOS 14 or later**, Apple Silicon and Intel. The native Swift app provides
  a menu bar monitor and dashboard. Requires Swift 6 to build from source.
- **Windows 10 or 11, x64.** The Windows app runs from a PyInstaller package.
  See the [English Windows guide](windows/README.md) or the
  [中文 Windows 说明](windows/README.zh-CN.md) for build and use instructions.

The source repository does not currently provide signed, notarized release
installers. See [distribution status](#distribution-status).

## macOS: build and run

```bash
swift build -c release
swift test

# Command-line report
swift run aimonitor
swift run aimonitor --since 7
swift run aimonitor --json

# Menu bar monitor and dashboard
swift run aimonitor-app

# Optional local app bundle install; default destination is ~/Applications
./install.sh
```

To choose another app bundle path, set `APP_PATH`:

```bash
APP_PATH="$HOME/Applications/AIMonitor-preview.app" ./install.sh
```

The installer uses an ad-hoc signature for local use. It does not install a
developer certificate or notarize the app.

The CLI also supports pricing inspection, historical repricing, quota checks,
timeline reports, and an accounting verification mode. Run `swift run aimonitor`
with the relevant command-line option; the source of each price is documented
in [docs/PRICING.md](docs/PRICING.md).

## What it reads

| Provider | Local accounting | Quota | Cost |
| --- | --- | --- | --- |
| Claude Code | Token records; totals remain estimated because local fields do not establish a complete count. | Claude desktop cache when available; optional online fallback. | API-equivalent estimate. |
| Codex CLI | Token and quota records from Codex session logs. | From local logs. | Estimate for models with a verified rate; otherwise unavailable. |
| Kimi Code | Per-turn usage records from Kimi CLI or desktop logs. | Optional online check. | API-equivalent estimate for recognized model ids. |
| Cursor | No comparable local token ledger. | Optional account quota check. | Unavailable. |

API-equivalent cost is a comparison against published API rates; it is not a
provider invoice or a subscription charge. The app reports unavailable values
when the source does not support a defensible number. More detail is in
[the pricing notes](docs/PRICING.md).

## Privacy

Usage history stays in a local SQLite database under the user's Application
Support directory. Collectors retain accounting metadata such as token counts,
timestamps, model names, project slugs, and session ids. Prompt and response
text is not stored in the database.

The default configuration makes no network requests. Claude, Kimi, and Cursor
quota requests are separate opt-ins. When enabled, a provider's existing local
credential is used for a read-only quota request; AI Monitor does not refresh
or persist that credential. The app has no telemetry, account, cloud sync,
network listener, or traffic interception.

See [PRIVACY.md](PRIVACY.md) for data sources and storage details, and
[SECURITY.md](SECURITY.md) for the threat model and vulnerability reporting.
The probe (`swift run aimonitor-probe`) prints log-format key paths without
printing log values. Review its output before sharing it, since paths may
identify local projects.

## How accounting works

- Claude Code's progressive snapshots are folded by request id; the largest
  complete snapshot is retained.
- Codex cumulative counters are converted to deltas. Forked and subagent
  sessions seed the inherited counter baseline to avoid counting parent usage
  again.
- Model labels found later in a Codex rollout are applied to earlier events in
  that same file before pricing.
- Cache-write TTLs and provider-specific input-token conventions are kept
  separate in the normalized token breakdown.
- Incremental checkpoints and database constraints make sync restart-safe and
  replay-resistant.
- Quota projections are shown only when the stored observations support them.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the data flow and
[docs/OPEN_SOURCE_RESEARCH.md](docs/OPEN_SOURCE_RESEARCH.md) for research notes.

## Development

The Swift test suite uses generated fixtures. Do not add personal logs,
databases, credentials, or screenshots containing usage details to issues or
pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and review
guidance. GitHub Actions builds and runs the existing platform suites on pushes
and pull requests.

## Distribution status

`install.sh` builds the macOS app locally and applies an ad-hoc signature. The
Windows CI package is also unsigned. These are development artifacts, not
official signed releases. Public distribution requires release review and
artifact checksums, plus Developer ID signing and notarization for macOS and
Authenticode signing for Windows.

## License

Original project code is licensed under the [MIT License](LICENSE). The
character references and themed artwork described in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) are not granted under that
license.
