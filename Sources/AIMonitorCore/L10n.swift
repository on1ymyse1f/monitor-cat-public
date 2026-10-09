import Foundation

/// Minimal two-language string table. Lives in the core so the menu bar and
/// the dashboard app share one source of truth.
public enum Language: String, CaseIterable, Sendable {
    case system, en, zh

    /// Effective concrete language for a configured value.
    public var resolved: Language {
        if self != .system { return self }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
    }
}

public enum L10n {
    public enum Key: String, CaseIterable, Sendable {
        // Root
        case appTitle, tabToday, tabTimeline, tabModels, tabSettings
        // The settlement slip (Receipt tab).
        case tabReceipt, receiptShop, receiptShopNight, receiptSpanDay, receiptSpanWeek
        case receiptCashier, receiptCashierName, receiptNo, receiptItem, receiptAmount
        case receiptPartlyPriced, receiptDaily, receiptClosed, receiptTodayMark
        case receiptTokens, receiptUnpricedNote, receiptTotal, receiptNoPrice, receiptDisclaimer
        case receiptThanks, receiptThanksNight, receiptPaid, receiptClosedStamp, receiptChime, receiptEmpty
        case receiptPrinting
        // Dashboard
        case tokensToday, time, cost, requests, activeNow
        case thisSession, idle, moreSessions, clockAhead
        case usage, tokenFlow, quota
        case noUsageToday, noUsageInRange, noQuotaData, exhaustedIn
        case remaining, share, shareDone
        // Range picker
        case rangeToday, range7D, range30D, rangeAll
        // Timeline / models
        case allProviders, noEvents, requestsSuffix, unpriced
        case costByModel, totalCost, other
        // Settings
        case collectorsAccess, claudeCollectorNote, codexCollectorNote, kimiCollectorNote, cursorCollectorNote, storageNote
        case retention, retention7, retention30, retention90, retentionYear, retentionForever
        case notifications, notificationsDetail
        case claudeQuota, claudeQuotaDetail, kimiQuota, kimiQuotaDetail, cursorQuota, cursorQuotaDetail
        case exportCard, exportCardDone
        case appearance, appearanceSystem, appearanceLight, appearanceDark
        case language, languageSystem
        case deleteAll, deleteConfirm, deleteNote
        // Menu bar
        case openDashboard, syncNow, quit, today
        // Quota misc
        case resetUnknown
        // Live-quota health. A provider the user switched on and that then
        // returns nothing must say why — silence reads as "no usage".
        case quotaChecking, quotaUnavailable
        case quotaNeedsKimiRunning
        case quotaNoToken, quotaTokenExpired, quotaServerError, quotaUnexpectedResponse
        // The kitten's page: greetings by hour, the footer, the motion switch.
        case greetingMorning, greetingAfternoon, greetingEvening, greetingNight
        case localFirst, animations, animationsDetail, catPet
        // Themes and local character packs.
        case theme, themeObservatory, themeNocturne, characterPackNone, themeAlwaysDark, appearanceMode
        case themeAubade, themeAlwaysLight
        // Aubade's own voice: a cheerful photo diary of the day, in original words.
        case dayMorning, dayAfternoon, dayEvening, dayLate
        case dayIdle, dayQuiet, dayCritical, dayNapping, dayWorking, dayBlind, dayFresh, dayPet
        case dayHappy, dayCalm
        case dayFooter
        case receiptShopDay, receiptThanksDay, receiptChimeDay
        // Nocturne's own voice: a guardian's night, in original words.
        case nightMorning, nightAfternoon, nightEvening, nightLate
        case nightIdle, nightQuiet, nightCritical, nightNapping, nightWorking, nightBlind, nightFresh, nightPet
        case nightHappy, nightCalm
        case nightFooter
        case moonNew, moonWaxingCrescent, moonFirstQuarter, moonWaxingGibbous
        case moonFull, moonWaningGibbous, moonLastQuarter, moonWaningCrescent
    }

    public static func text(_ key: Key, _ lang: Language) -> String {
        let zh = lang.resolved == .zh
        switch key {
        case .appTitle: return "AI Monitor"
        case .tabToday: return zh ? "今日" : "Today"
        case .tabTimeline: return zh ? "时间线" : "Timeline"
        case .tabModels: return zh ? "模型" : "Models"
        case .tabSettings: return zh ? "设置" : "Settings"
        case .tabReceipt: return zh ? "小票" : "Receipt"
        case .receiptShop: return zh ? "猫娘观测所 · 便利店" : "CAT OBSERVATORY MART"
        case .receiptShopNight: return zh ? "夜想 · 月下小铺" : "NOCTURNE · MOONLIT SHOP"
        case .receiptSpanDay: return zh ? "今日" : "Today"
        case .receiptSpanWeek: return zh ? "近 7 天" : "7 days"
        case .receiptCashier: return zh ? "收银" : "Cashier"
        case .receiptCashierName: return zh ? "猫娘" : "Catgirl"
        case .receiptNo: return zh ? "单号" : "No."
        case .receiptItem: return zh ? "品名" : "ITEM"
        case .receiptAmount: return zh ? "金额" : "AMOUNT"
        case .receiptPartlyPriced: return zh ? "部分未定价" : "partly unpriced"
        case .receiptDaily: return zh ? "日结明细" : "DAILY"
        case .receiptClosed: return zh ? "休息" : "closed"
        case .receiptTodayMark: return zh ? "今日" : "today"
        case .receiptTokens: return zh ? "token 合计" : "Tokens"
        case .receiptUnpricedNote: return zh ? "%d 项未定价，不计入金额" : "%d unpriced, not in the total"
        case .receiptTotal: return zh ? "合计" : "TOTAL"
        case .receiptNoPrice: return zh ? "无标价" : "no price"
        case .receiptDisclaimer: return zh
            ? "※ 按 API 标价折算，并非实际扣款"
            : "※ API list-price equivalent, not a bill"
        case .receiptThanks: return zh ? "谢谢惠顾喵 ♡" : "Thanks, come again ♡"
        case .receiptThanksNight: return zh ? "今夜也辛苦了 ♭" : "Rest well tonight ♭"
        case .receiptPaid: return zh ? "已结算" : "PAID"
        case .receiptClosedStamp: return zh ? "休" : "CLOSED"
        case .receiptChime: return zh ? "叮♪" : "KA-CHING!"
        case .receiptEmpty: return zh ? "— 本期无消费 —" : "— nothing sold —"
        case .receiptPrinting: return zh ? "嗞嗞嗞…" : "BRRRT…"
        case .tokensToday: return zh ? "今日 token" : "tokens today"
        case .thisSession: return zh ? "本次会话" : "this session"
        case .idle: return zh ? "空闲" : "idle"
        case .moreSessions: return zh ? "另有 %d 个会话在运行" : "%d more running"
        case .clockAhead: return zh ? "时钟快 %@" : "clock +%@"
        case .time: return zh ? "时长" : "time"
        case .cost: return zh ? "费用" : "cost"
        case .requests: return zh ? "请求" : "requests"
        case .activeNow: return zh ? "正在进行" : "Active now"
        case .usage: return zh ? "用量分布" : "Usage"
        case .tokenFlow: return zh ? "流量" : "Token flow"
        case .quota: return zh ? "额度" : "Quota"
        case .noUsageToday: return zh ? "今天还没有记录到用量。" : "No usage recorded today."
        case .noUsageInRange: return zh ? "该时间范围内没有用量。" : "No usage in this range."
        case .noQuotaData: return zh ? "暂无额度数据——提供商未上报或尚未使用。" : "No quota data — providers either don't report it or weren't used yet."
        // A projection, not a deadline — the "~" / "约" says so in one
        // character. The sentence it replaced ("At current pace, exhausted
        // in 22h 14m") ran past a two-column quota card and was cut off.
        case .exhaustedIn: return zh ? "约 %@ 后耗尽" : "Runs out in ~%@"
        case .remaining: return zh ? "剩余" : "left"
        case .share: return zh ? "生图分享" : "Share as image"
        case .shareDone: return zh ? "已保存到桌面" : "Saved to Desktop"
        case .rangeToday: return zh ? "今日" : "Today"
        case .range7D: return "7D"
        case .range30D: return "30D"
        case .rangeAll: return zh ? "全部" : "All"
        case .allProviders: return zh ? "全部提供商" : "All providers"
        case .noEvents: return zh ? "暂无事件。" : "No events yet."
        case .requestsSuffix: return zh ? "次请求" : "requests"
        case .unpriced: return zh ? "未定价" : "unpriced"
        case .costByModel: return zh ? "按模型成本" : "Cost by model"
        case .totalCost: return zh ? "总成本" : "total cost"
        case .other: return zh ? "其他" : "other"
        case .collectorsAccess: return zh ? "各采集器的访问范围" : "What each collector can access"
        case .claudeCollectorNote: return zh
            ? "读取 ~/.claude/projects 下的会话记录。匹配用量标记的 JSON 行会在内存中解析；只存储 token 数、模型、时间戳、项目名和请求 ID，不存储 prompt 或回复内容。"
            : "Reads ~/.claude/projects transcripts. Matching JSON lines are decoded in memory; only token counts, model, timestamps, project slug, and request ids are stored. Prompt and response text is not stored."
        case .codexCollectorNote: return zh
            ? "读取 ~/.codex/sessions 下的 rollout 日志及其中内嵌的额度数据。auth.json 从不打开，凭证从不触碰。"
            : "Reads ~/.codex/sessions rollout logs and the quota data embedded in them. auth.json is never opened; no credential is ever refreshed."
        case .kimiCollectorNote: return zh
            ? "读取 ~/.kimi-code/sessions 下的 wire 日志中的 usage 记录。匹配行会在内存中解析；只存储用量字段。开启在线额度后，才会读取本地凭证用于额度请求。"
            : "Reads usage records from wire logs under ~/.kimi-code/sessions. Matching lines are decoded in memory and only usage fields are stored. Local credentials are read for quota requests only when live quota is enabled."
        case .cursorCollectorNote: return zh
            ? "Cursor 不在本地保存可与其他工具逐请求对齐的 token 记录。可选在线额度只读 Cursor 自身状态库中的当前登录，不读取浏览器 Cookie。"
            : "Cursor does not persist per-request token records comparable to the other tools. Optional live quota reads Cursor's own login state only; browser cookies are not inspected."
        case .kimiQuota: return zh ? "Kimi 在线额度" : "Kimi live quota"
        case .kimiQuotaDetail: return zh
            ? "开启后，启动应用或检测到新 Kimi Code 令牌时可能查询额度；运行期间通常至少间隔 15 分钟，但新令牌可提前触发。重启会重置计时。若 CLI 令牌过期，会尝试读取 Kimi Desktop 自身 Cookies 库中的 kimi-auth（不读取浏览器 Cookie）。凭证不落盘、不主动刷新。"
            : "When enabled, quota may be checked on launch or when a new Kimi Code token is detected. Requests normally have a 15-minute minimum interval while running, but a new token can trigger one sooner; restarting resets the timer. If the CLI token has expired, the app tries kimi-auth from Kimi Desktop's own Cookies DB (never browser cookies). Credentials are not persisted or refreshed by this app."
        case .cursorQuota: return zh ? "Cursor 在线额度" : "Cursor live quota"
        case .cursorQuotaDetail: return zh
            ? "只读 Cursor.app 的 state.vscdb 当前访问令牌，向 cursor.com 的 usage-summary 端点发一个 GET。数据库以只读模式打开；不读取浏览器 Cookie、不落盘令牌、不刷新登录。运行期间至少间隔 15 分钟；重启会重置计时。"
            : "Reads Cursor.app's current access token from state.vscdb and issues one GET to cursor.com's usage-summary endpoint. The database is read-only; no browser cookies, token persistence, or refresh. Requests are 15 minutes apart while running; restarting resets the timer."
        case .exportCard: return zh ? "导出使用名片" : "Export profile card"
        case .exportCardDone: return zh ? "名片已导出：" : "Card exported:"
        case .storageNote: return zh
            ? "用量历史和设置保存在 ~/Library/Application Support/AIMonitor。无遥测、无账号；在线额度查询需单独开启，默认关闭。"
            : "Usage history and settings stay in ~/Library/Application Support/AIMonitor. No telemetry or account; live quota requests are separately opt-in and off by default."
        case .retention: return zh ? "保留时长" : "Retention"
        case .retention7: return zh ? "7 天" : "7 days"
        case .retention30: return zh ? "30 天" : "30 days"
        case .retention90: return zh ? "90 天" : "90 days"
        case .retentionYear: return zh ? "1 年" : "1 year"
        case .retentionForever: return zh ? "永久" : "Forever"
        case .notifications: return zh ? "通知" : "Notifications"
        case .notificationsDetail: return zh ? "额度达到 80% / 90% / 100% 时提醒" : "Quota alerts at 80% / 90% / 100%"
        case .claudeQuota: return zh ? "Claude 在线额度" : "Claude live quota"
        case .claudeQuotaDetail: return zh
            ? "额度优先读取 Claude 桌面端本地缓存——离线且无需开启此项。此开关仅控制备用联网查询：缓存不可用时，从钥匙串读取 OAuth 访问令牌并向额度接口发一个 GET。联网查询在运行期间至少间隔 15 分钟；重启会重置计时。凭证不落盘、不主动刷新。关闭后不产生 Claude 额度请求。"
            : "Quota is read first from the Claude desktop app's local cache — offline and without opt-in. This switch controls the online fallback: if the cache is unavailable, the app reads an OAuth access token from Keychain and sends one GET to the usage endpoint, with a minimum 15-minute interval while running. Restarting resets the timer. Credentials are not persisted or refreshed by this app. Off means no Claude quota request."
        case .appearance: return zh ? "外观" : "Appearance"
        case .appearanceSystem: return zh ? "跟随系统" : "System"
        case .appearanceLight: return zh ? "浅色" : "Light"
        case .appearanceDark: return zh ? "深色" : "Dark"
        case .language: return zh ? "语言" : "Language"
        case .languageSystem: return zh ? "跟随系统" : "System"
        case .deleteAll: return zh ? "删除全部分析数据" : "Delete all analytics data"
        case .deleteConfirm: return zh ? "再点一次确认" : "Click again to confirm"
        case .deleteNote: return zh
            ? "删除所有事件、额度快照和检查点。下次同步将从头重新读取日志。"
            : "Removes every event, quota snapshot, and checkpoint. The next sync re-reads the logs from scratch."
        case .openDashboard: return zh ? "打开仪表盘" : "Open Dashboard"
        case .syncNow: return zh ? "立即同步" : "Sync now"
        case .quit: return zh ? "退出" : "Quit"
        case .today: return zh ? "今日" : "Today"
        case .resetUnknown: return zh ? "重置时间未知" : "reset unknown"
        case .quotaChecking: return zh ? "查询中…" : "checking…"
        case .quotaUnavailable: return zh ? "暂无数据" : "unavailable"
        case .quotaNeedsKimiRunning:
            return zh
                ? "Kimi 的令牌只有 15 分钟有效期。额度会在你使用 Kimi Code 时自动更新。"
                : "Kimi's token lasts 15 minutes. Quota refreshes while you are using Kimi Code."
        case .quotaNoToken: return zh
            ? "钥匙串里没有订阅令牌。若通过 API key 或第三方网关使用，官方额度接口无法查询。"
            : "No subscription token in the Keychain. If you sign in with an API key or a gateway, the official quota endpoint can't be queried."
        case .quotaTokenExpired: return zh
            ? "令牌已过期。运行一次该 CLI 即可刷新——本应用从不主动刷新令牌。"
            : "Token expired. Run the CLI once to refresh it — this app never refreshes tokens itself."
        case .quotaServerError: return zh ? "服务端返回错误。" : "The provider returned an error."
        case .quotaUnexpectedResponse: return zh ? "响应格式无法识别。" : "The response wasn't in a recognizable shape."
        case .greetingMorning: return zh ? "早上好" : "Good morning"
        case .greetingAfternoon: return zh ? "下午好" : "Good afternoon"
        case .greetingEvening: return zh ? "晚上好" : "Good evening"
        case .greetingNight: return zh ? "夜深了" : "Up late"
        case .localFirst: return zh ? "本地优先 · 在线额度需手动开启" : "Local-first · quota requests are opt-in"
        case .animations: return zh ? "动画" : "Animations"
        case .animationsDetail: return zh
            ? "关闭后猫娘保持静止、页面不做过渡；系统「减弱动态效果」与低电量模式始终优先。"
            : "Off: the kitten holds still and pages don't animate. The system's Reduce Motion and Low Power Mode always win."
        case .catPet: return zh ? "喵～" : "nya~"
        case .theme: return zh ? "主题" : "Theme"
        case .themeObservatory: return zh ? "猫娘观测所" : "Cat Observatory"
        case .themeNocturne: return zh ? "夜想" : "Nocturne"
        case .themeAubade: return zh ? "晨曲" : "Aubade"
        case .themeAlwaysLight: return zh ? "晨曲始终为浅色。" : "Aubade is always light."
        case .dayMorning: return zh ? "早安，拍下今天吧" : "Good morning"
        case .dayAfternoon: return zh ? "午后的光正好" : "Lovely light"
        case .dayEvening: return zh ? "傍晚，整理相册" : "Album time"
        case .dayLate: return zh ? "还不睡吗？" : "Still up?"
        case .dayIdle: return zh ? "我在旁边看着哦" : "I'm right here watching"
        case .dayQuiet: return zh ? "今天好安静呀" : "Such a quiet day"
        case .dayCritical: return zh ? "额度快见底啦！" : "Quota's almost gone!"
        case .dayNapping: return zh ? "我先眯一会儿…" : "Just a little nap…"
        case .dayWorking: return zh ? "咔嚓，记下来了！" : "Click — got that one!"
        case .dayBlind: return zh ? "镜头起雾了…" : "My lens fogged up…"
        case .dayFresh: return zh ? "相册还是空的呢" : "The album's still empty"
        case .dayPet: return zh ? "嘿嘿，被你发现了☆" : "Hehe, you found me☆"
        case .dayHappy: return zh ? "今天也很顺利！" : "Going great today!"
        case .dayCalm: return zh ? "一切正常～" : "All normal~"
        case .dayFooter: return zh ? "今天也留个纪念 · 数据只留在这台 Mac" : "A keepsake a day · nothing leaves this Mac"
        case .receiptShopDay: return zh ? "晨曲 · 晴空照相馆" : "AUBADE · PHOTO KIOSK"
        case .receiptThanksDay: return zh ? "今天也拍好啦 ☆" : "Snapped for the album ☆"
        case .receiptChimeDay: return zh ? "咔嚓☆" : "SNAP!"
        case .characterPackNone: return zh
            ? "未安装角色包：此主题暂用猫娘。用 scripts/make-character-skin.py 把表情图集做成角色包（晨曲加 --skin aubade --cutout），放在 ~/Library/Application Support/AIMonitor/Skins/ 下即可（只在本机，不进仓库）。"
            : "No character pack installed: this theme uses the kitten for now. Turn an expression sheet into a pack with scripts/make-character-skin.py (for Aubade add --skin aubade --cutout); packs live in ~/Library/Application Support/AIMonitor/Skins/ (on this Mac only, never in the repository)."
        case .themeAlwaysDark: return zh ? "夜想始终为深色。" : "Nocturne is always dark."
        case .appearanceMode: return zh ? "明暗" : "Mode"
        case .nightMorning: return zh ? "晨光熹微" : "First light"
        case .nightAfternoon: return zh ? "午后微光" : "Afternoon lull"
        case .nightEvening: return zh ? "夜幕降临" : "Night falls"
        case .nightLate: return zh ? "长夜未央" : "The long night goes on"
        case .nightIdle: return zh ? "我在守望着" : "keeping watch"
        case .nightQuiet: return zh ? "今夜很安静" : "a quiet night"
        case .nightCritical: return zh ? "所剩无几了♭" : "nearly gone♭"
        case .nightNapping: return zh ? "晚安♭" : "good night♭"
        case .nightWorking: return zh ? "正在记住这一切" : "remembering it all"
        case .nightBlind: return zh ? "镜中起雾了" : "the mirror's clouded"
        case .nightFresh: return zh ? "还没有可追忆的" : "nothing to remember yet"
        case .nightPet: return zh ? "……谢谢你♭" : "…thank you♭"
        case .nightHappy: return zh ? "今夜也很顺利♪" : "all is well tonight♪"
        case .nightCalm: return zh ? "嗯，一切如常" : "all as it should be"
        case .nightFooter: return zh ? "长夜漫漫 · 数据只留在这台 Mac" : "A long night · nothing leaves this Mac"
        case .moonNew: return zh ? "新月" : "New moon"
        case .moonWaxingCrescent: return zh ? "蛾眉月" : "Waxing crescent"
        case .moonFirstQuarter: return zh ? "上弦月" : "First quarter"
        case .moonWaxingGibbous: return zh ? "盈凸月" : "Waxing gibbous"
        case .moonFull: return zh ? "满月" : "Full moon"
        case .moonWaningGibbous: return zh ? "亏凸月" : "Waning gibbous"
        case .moonLastQuarter: return zh ? "下弦月" : "Last quarter"
        case .moonWaningCrescent: return zh ? "残月" : "Waning crescent"
        }
    }
}
