# Privacy

AI Monitor processes provider usage data on the user's device. The app has no
account, telemetry, cloud sync, analytics upload, crash reporter, network
listener, or traffic interception.

## Local sources

The collectors discover these sources when present. Environment variables can
override some roots; see the platform guide for details.

| Provider/source | macOS | Windows |
| --- | --- | --- |
| Claude Code usage | `~/.claude/projects/**/*.jsonl` | `%USERPROFILE%\.claude\projects\**\*.jsonl` |
| Codex CLI usage | `~/.codex/sessions/**/rollout-*.jsonl` | `%USERPROFILE%\.codex\sessions\**\rollout-*.jsonl` |
| Kimi Code usage | `~/.kimi-code/sessions/**/wire.jsonl` and `~/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions/**/wire.jsonl` | `%USERPROFILE%\.kimi-code\sessions\**\wire.jsonl` and Kimi Desktop session directories under `%APPDATA%` or `%LOCALAPPDATA%` |
| Claude desktop quota cache | `~/Library/Application Support/Claude/plan-usage-history.json` | Claude cache candidates under `%APPDATA%` and `%LOCALAPPDATA%` |
| Cursor quota credential source | Cursor's local `globalStorage/state.vscdb`, opened read-only | Cursor's `globalStorage/state.vscdb` under `%APPDATA%` or `%LOCALAPPDATA%`, opened read-only |

The Kimi collector also reads its session index to associate a usage record
with a project when that index is available. The Windows source roots and
environment overrides are listed in [windows/README.md](windows/README.md).

## Parsing and stored data

Collectors filter log lines for accounting markers before decoding a matching
line. A matching JSON line is decoded in memory; only selected usage and
attribution fields are mapped into AI Monitor's records. Prompt and response
text are not sent to providers and are not stored in the AI Monitor database.
The original provider logs remain on disk and are not modified by collection.

The local database stores timestamps, provider and model names, session ids,
project slugs, token counters, estimated API-equivalent costs, quota snapshots,
settings, and file checkpoints. Checkpoints contain source paths, sizes, and
read offsets. Some event identifiers also contain a source path, so stored
metadata can reveal a local account name or project directory.

Default database locations:

- macOS: `~/Library/Application Support/AIMonitor/aimonitor.db`
- Windows: `%LOCALAPPDATA%\AIMonitor\aimonitor.db`

SQLite may also create `-wal` and `-shm` companion files while the app is open.
Windows supports `AIMONITOR_DATA_DIR` and `AIMONITOR_DB` overrides.

## Network and credentials

All live quota settings are off by default. Enabling one lets that provider's
existing credential be used for a read-only request to its usage endpoint:

| Provider | macOS credential source | Windows credential source | Endpoint |
| --- | --- | --- | --- |
| Claude | Claude Code access token from the login Keychain | `claudeAiOauth.accessToken` from `.credentials.json` under `%USERPROFILE%\.claude` or the configured secure-storage directory | `https://api.anthropic.com/api/oauth/usage` |
| Kimi | Kimi Code access token or the Kimi Desktop app's own session cookie | `access_token` from `%USERPROFILE%\.kimi-code\credentials\kimi-code.json` | macOS CLI: GET `https://api.kimi.com/coding/v1/usages`; macOS desktop: POST `https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`; Windows: GET `https://api.kimi.com/coding/v1/usages` |
| Cursor | Current access token from Cursor's local state database | Current access token from Cursor's local state database | `https://cursor.com/api/usage-summary` |

Quota requests have a timeout. The Windows implementation rejects redirects;
the macOS Swift implementation currently uses `URLSession`'s standard redirect
handling. AI Monitor does not refresh credentials or write them to its
database. Claude and Cursor requests use a 15-minute minimum interval while the
app process is running. Kimi requests normally use the same interval, but a
newly issued Kimi CLI token can trigger an earlier request on both platforms.
On Windows, a changed Kimi credential file triggers that immediate refresh.
These timers are held in memory; restarting the app resets them and can cause
another request soon after launch when a quota setting is enabled.

The Claude desktop cache is read locally without network access. If it contains
a usable quota reading, the app does not make the optional Claude request.

Quota observations are marked aging and eventually hidden based on the length
of the quota window: the app treats readings as live for up to 5% of a window
and hides them after 25%. A source that supplies no window length uses a
one-hour fallback. Historical quota snapshots can remain in the database after
they disappear from the live dashboard.

## Exports

Exports are created only when the user requests them. The Windows daily PNG
contains token, activity, request, and provider-share totals. The Windows HTML
profile card includes usage statistics. It does not include the Windows account
name. Review an export before sharing it; exported files are outside the app's
database and retention controls.

## Retention and deletion

The retention setting offers 7, 30, or 90 days, one year, or forever. Cleanup
runs when the user changes the setting; it is not a background sweep. Applying
the setting removes timestamped usage events older than the chosen period. It
does not remove source logs, quota snapshots, checkpoints, or events without a
timestamp. This is a local database cleanup, not secure erasure.

The delete-history control removes indexed usage events, quota snapshots, and
checkpoints. It preserves general preferences, and SQLite may retain deleted
bytes in database or WAL files. The next sync can rebuild indexed data from
provider logs that remain on disk. To remove AI Monitor's local database files,
quit the app and delete its database and SQLite companion files; this does not
delete provider logs or exports.
