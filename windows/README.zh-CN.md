# AIMonitor Windows 版

Windows 版已经开发完成，代码位于 `windows/`，包含桌面窗口、系统托盘、日志采集、本地 SQLite 存储、额度查询、导出和 PyInstaller 打包流程。

当前公开快照的 Windows CI 已完成以下检查：

- Windows x64 打包
- Windows 单元测试
- 打包后的 `AIMonitor.exe --self-test`
- UI 页面构造 smoke check

当前仍是开发分发状态：没有 Authenticode 签名安装包，也没有在真实 Windows 设备上完成手工托盘和界面验收。下载 ZIP 后出现 SmartScreen 提示属于预期现象。

## 直接使用构建产物

仓库目前没有正式 Release 安装包。获取 CI 构建产物：

1. 打开仓库的 **Actions** 页面。
2. 进入 **Windows CI** 的成功运行记录。
3. 在页面底部下载 `AIMonitor-Windows-x64` artifact。
4. 解压完整的 `AIMonitor` 文件夹。
5. 运行 `AIMonitor\AIMonitor.exe`。

不要只复制 `.exe` 文件。它是 onedir 包，需要和同目录依赖及 `Resources` 文件夹一起保留。关闭窗口后程序会继续在系统托盘运行，可以从托盘重新打开或退出。

## 本地构建

要求：

- Windows 10 或 11，x64
- Python 3.12 x64
- PowerShell 5.1 或 PowerShell 7

在仓库根目录执行：

```powershell
py -3.12 -m venv .venv-windows
Set-ExecutionPolicy -Scope Process Bypass
& .\.venv-windows\Scripts\Activate.ps1
& .\windows\build_windows.ps1 -Python .\.venv-windows\Scripts\python.exe
```

构建脚本会安装 `windows/requirements-build.txt` 中的依赖，生成图标，运行 PyInstaller，执行打包自检，并生成：

```text
windows/dist/AIMonitor/AIMonitor.exe
windows/dist/AIMonitor-Windows-x64.zip
```

如果已经安装过依赖，可以使用 `-SkipInstall`；如果只想跳过打包自检，可以使用 `-SkipSelfTest`。脚本只会清理 `windows/build/` 和 `windows/dist/` 这两个生成目录。

## 已支持功能

| 功能 | 状态 |
| --- | --- |
| Claude Code、Codex CLI、Kimi Code 用量采集 | 已支持 |
| 增量同步、断点续读和重复记录去重 | 已支持 |
| 今日统计、提供商占比、Token 流量和实时会话 | 已支持 |
| 时间线、模型和成本明细 | 已支持 |
| Codex 本地额度和 Claude 桌面缓存额度 | 已支持 |
| Claude、Kimi、Cursor 在线额度 | 可选，默认关闭 |
| 系统托盘、同步、退出和主题切换 | 已支持 |
| 英文/中文界面 | 已支持 |
| 数据保留、删除历史和档案卡导出 | 已支持 |
| 每日 PNG 分享卡 | 已支持 |
| ChatGPT Desktop、Gemini Desktop 额度 | 暂不支持 |

## 本地数据和隐私

默认不联网。日志采集和本地额度读取只访问本机已有文件，数据保存于：

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

程序只把用量和归属字段写入数据库，不保存 prompt 或回复正文。但数据库会保存会话 ID、项目名、检查点和部分源文件路径，路径可能暴露 Windows 用户名或项目目录。原始日志不会被修改。

Claude、Kimi 和 Cursor 的在线额度均为单独开关，默认关闭。开启后只使用现有凭证发起只读请求，不主动刷新或保存凭证；Windows 会拒绝带凭证请求的重定向。Claude 和 Cursor 在程序运行期间至少间隔 15 分钟，Kimi 检测到凭证文件变化时可以提前刷新；重启程序会重置计时。

完整说明见 [PRIVACY.md](../PRIVACY.md) 和 [SECURITY.md](../SECURITY.md)。

## 开发检查

源码级测试：

```powershell
python -m unittest discover -s windows/tests -v
```

打包后的非交互式自检：

```powershell
$process = Start-Process `
  -FilePath .\windows\dist\AIMonitor\AIMonitor.exe `
  -ArgumentList @("--self-test") -Wait -PassThru
if ($process.ExitCode -ne 0) { exit $process.ExitCode }
```

GitHub Actions 会在 Windows runner 上执行这些检查并上传 ZIP artifact。成功通过 CI 不等于完成签名、SmartScreen 信誉积累或真实设备上的人工界面验收。
