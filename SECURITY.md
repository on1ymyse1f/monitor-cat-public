# Security

## Threat model

AI Monitor reads local AI-tool accounting records and writes a local SQLite
database. The main assets are usage history, provider credentials used by
optional quota checks, and the integrity of the monitored applications.

## Security behavior

- **Offline by default.** Log collection, reporting, and the Claude desktop
  quota-cache path do not make network requests.
- **Quota requests require opt-in.** Claude, Kimi, and Cursor have separate
  settings. Each reads an existing provider credential and does not refresh or
  store it in the AI Monitor database. Claude and Cursor use a 15-minute
  minimum interval while the app process is running. Kimi can request
  immediately when a newly issued token is detected on either platform;
  Windows watches the credential file timestamp. The timers reset when the app
  restarts. The sources and request behavior are described in
  [PRIVACY.md](PRIVACY.md).
- **Redirect handling is platform-specific.** Windows rejects redirects for
  credential-bearing requests. The macOS Swift providers currently use
  `URLSession`'s standard redirect handling.
- **No listener or traffic interception.** There is no proxy, IPC endpoint,
  MITM, root certificate, or TLS decryption.
- **Prepared SQL.** Database queries use bound parameters.
- **Defensive parsing.** Malformed and truncated records are skipped, unknown
  fields are tolerated, and one failed file does not stop other collectors.
- **Least privilege.** The macOS app does not request Accessibility, Full Disk
  Access, or administrator permissions. It reads user-owned logs and optional
  provider quota sources, then writes its own Application Support database.

## Dependencies and distribution

The Swift package has no third-party package dependencies and uses system
frameworks and SQLite. Windows build-time dependencies are listed in
`windows/requirements-build.txt`; the packaged app does not require a separate
Python installation.

The local macOS installer applies an ad-hoc signature. The Windows CI package
is unsigned. Before distributing official binaries, maintainers should verify
the source revision and checksums, sign the Windows build with Authenticode,
and sign, harden, and notarize the macOS app with Developer ID.

## Report a vulnerability

Please use GitHub's private vulnerability reporting feature from the
repository's **Security** tab. Do not disclose credentials, local logs, or
exploit details in a public issue. If private reporting is unavailable, open a
public issue asking for a private contact route without including vulnerability
details.

For ordinary format or parsing problems, open a bug report with a minimal
synthetic example. Do not attach provider logs, database files, or tokens.
