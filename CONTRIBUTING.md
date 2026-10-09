# Contributing

Bug reports, documentation improvements, and focused code changes are welcome.
Before opening an issue, check whether it has already been reported. For a
security concern, follow [SECURITY.md](SECURITY.md) instead of filing a public
issue.

## Development setup

### macOS

- macOS 14 or later
- Swift 6.0 or later

From the repository root:

```bash
swift build
swift test
swift run aimonitor-app
```

### Windows

See [windows/README.md](windows/README.md) for the Python 3.12 setup, test
commands, and packaging steps. The Windows CI workflow runs the unit suite and
packaged smoke checks.

## Change guidelines

- Keep provider-specific parsing in that provider's collector or adapter.
- Preserve the `exact` / `est.` / `n/a` confidence contract. Do not replace
  missing information with a guessed zero or price.
- Keep prompt and response text out of the normalized event model, database,
  test fixtures, and issue attachments.
- Use generated or synthetic fixtures. Never commit personal logs, databases,
  provider credentials, API tokens, or screenshots that expose usage history.
- Update `PRIVACY.md`, `SECURITY.md`, and the relevant platform guide when a
  change adds a data source, stored field, permission, or network request.
- Add or update regression coverage for behavior changes. Run the relevant
  platform suite before opening a pull request.

## Pull requests

Keep each pull request focused. Include the reason for the change, user-visible
effects, and the commands used to validate it. Do not attach raw provider logs
or a copy of `aimonitor.db`; describe the format issue with a minimal synthetic
example instead.
