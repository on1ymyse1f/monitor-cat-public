# AIMonitor for Windows

> Windows 版本已开发并纳入 CI：当前公开快照的 Windows 构建、打包和自检已通过。项目暂未提供签名安装包，也未把本地 CI 结果当作实体 Windows 机器上的人工界面验收。

中文说明见 [README.zh-CN.md](README.zh-CN.md)。

This directory contains the complete Windows implementation and its packaging.
The application entry point is `monitor_cat.py`; reusable accounting, storage,
quota and sync code lives under `aimonitor/`; `app.py` is the Tk desktop/tray
shell. The release is local-first and keeps the same confidence rule as macOS:
unknown data is `n/a`, never a made-up zero.

## Use the ZIP

1. Download `AIMonitor-Windows-x64.zip` and extract the complete `AIMonitor`
   folder.
2. Run `AIMonitor\AIMonitor.exe`.
3. Closing the window keeps the lightweight tray monitor running. Use the tray
   menu to reopen it or quit.

The release bundles Python, Tcl/Tk, Pillow and the tray adapter. End users do
not need Python or .NET installed. Keep the whole extracted folder together;
the executable is intentionally an onedir build rather than a slower one-file
self-extractor.

Windows data paths:

```text
%LOCALAPPDATA%\AIMonitor\aimonitor.db
%USERPROFILE%\.claude\projects\**\*.jsonl
%USERPROFILE%\.codex\sessions\**\rollout-*.jsonl
%USERPROFILE%\.kimi-code\sessions\**\wire.jsonl
%USERPROFILE%\.kimi-code\session_index.jsonl
%APPDATA%\kimi-desktop\daimon-share\daimon\runtime\kimi-code\home\sessions\**\wire.jsonl
%LOCALAPPDATA%\kimi-desktop\daimon-share\daimon\runtime\kimi-code\home\sessions\**\wire.jsonl
%APPDATA%\Cursor\User\globalStorage\state.vscdb
```

The app filters for accounting markers before decoding matching JSON lines. It
maps selected usage and attribution fields into the database; prompt and
response fields are not stored. The database also stores session ids, project
slugs, and source paths in checkpoints and some event ids, which can reveal
Windows account or project-directory names.

Claude desktop quota-cache files are checked under `%APPDATA%` and
`%LOCALAPPDATA%`. Optional online quota credentials are read only after their
separate settings are enabled:

| Provider | Credential source | Endpoint |
| --- | --- | --- |
| Claude | `.credentials.json` under `%USERPROFILE%\.claude` or the configured Claude secure-storage directory | `https://api.anthropic.com/api/oauth/usage` |
| Kimi | `%USERPROFILE%\.kimi-code\credentials\kimi-code.json` | `https://api.kimi.com/coding/v1/usages` |
| Cursor | `cursorAuth/accessToken` in Cursor's local `state.vscdb` | `https://cursor.com/api/usage-summary` |

All network settings are off by default. Requests are read-only, use existing
credentials, reject redirects, and do not store or refresh tokens. Claude and
Cursor checks use a 15-minute minimum interval while the app is running. Kimi
may refresh as soon as its credential file changes, in addition to the normal
interval. Timers reset when the app restarts, so an enabled quota source may
request again soon after launch. See [the privacy notes](../PRIVACY.md) for the
full data and storage description.

The daily PNG and HTML profile card are user-triggered exports. They contain
usage statistics; the HTML card does not include the Windows account name.
Review exported files before sharing them.

## Feature parity

| Capability | macOS | Windows |
|---|---:|---:|
| Claude Code, Codex CLI, Kimi Code accounting | yes | yes |
| Incremental checkpoints and schema-level dedup | yes | yes |
| Today totals, usage shares, token flow and live sessions | yes | yes |
| Provider-filtered timeline and model/cost breakdown | yes | yes |
| Codex local quota and Claude desktop-cache quota | yes | yes |
| Opt-in Claude/Kimi online quota (Kimi may refresh on credential change) | yes | yes |
| Opt-in Cursor account quota, 15-minute limit | CLI only | yes |
| Menu bar / system tray summary, sync and quit | yes | yes |
| Quota threshold notifications | yes | yes |
| System/light/dark and English/中文 | yes | yes |
| Retention, delete history and profile-card export | yes | yes |
| Today PNG share card | yes | yes |
| 15s idle / 2s visible-live cadence | yes | yes |

## Build requirements

- Windows 10 or 11, x64 (Windows 11 is exercised by CI)
- Python 3.12 x64
- PowerShell 5.1 or PowerShell 7

The build dependencies are isolated in `requirements-build.txt`: PyInstaller,
pystray, and Pillow. Runtime Python is bundled into the application.

## Build locally

From the repository root:

```powershell
py -3.12 -m venv .venv-windows
Set-ExecutionPolicy -Scope Process Bypass
& .\.venv-windows\Scripts\Activate.ps1
& .\windows\build_windows.ps1 -Python .\.venv-windows\Scripts\python.exe
```

The script performs these steps with explicit exit-code checks:

1. installs `requirements-build.txt` unless `-SkipInstall` is supplied;
2. generates `windows/build/AIMonitor.ico` from the shared `menubar-cat.png`;
3. runs PyInstaller in onedir mode;
4. executes `AIMonitor.exe --self-test` unless `-SkipSelfTest` is supplied;
5. compresses the complete onedir folder.

Outputs:

```text
windows/dist/AIMonitor/AIMonitor.exe
windows/dist/AIMonitor-Windows-x64.zip
```

The ZIP contains the `AIMonitor` onedir folder and all of its dependencies. Do
not copy only the executable out of that directory.

Cursor quota is account usage, not local token accounting. When enabled in
Settings, AIMonitor reads the current Cursor session from the local
`state.vscdb` database in read-only mode and makes one read-only request to
Cursor's official usage endpoint with a 15-minute minimum interval while the
app is running. Restarting the app resets that timer. ChatGPT Desktop and
Gemini Desktop remain unsupported because they do not expose a stable,
verifiable local quota source.

## Resources and dynamic imports

`AIMonitor.spec` packages the shared artwork from
`Sources/aimonitor-app/Resources` at the runtime-relative `Resources` path. It
also declares the dynamically selected `pystray._win32` backend, its Win32
utility module, Pillow image plugins, and Tk imports. Non-Windows pystray
backends are excluded from this Windows-only artifact.

## Tests and packaged self-test

Run the source-level suite with:

```powershell
python -m unittest discover -s windows/tests -v
```

The packaged smoke test is intentionally non-interactive and must terminate on
its own:

```powershell
$process = Start-Process `
  -FilePath .\windows\dist\AIMonitor\AIMonitor.exe `
  -ArgumentList @("--self-test") -Wait -PassThru
if ($process.ExitCode -ne 0) { exit $process.ExitCode }
```

GitHub Actions repeats the unit tests, builds on `windows-2025`, runs this
packaged self-test, and uploads `AIMonitor-Windows-x64.zip` as the
`AIMonitor-Windows-x64` artifact.

## Distribution boundary

The CI artifact is an unsigned test build. Successful unit tests, PyInstaller
packaging, and `--self-test` do not constitute Authenticode signing or a manual
Windows tray/GUI validation; SmartScreen may warn when the ZIP is downloaded.
