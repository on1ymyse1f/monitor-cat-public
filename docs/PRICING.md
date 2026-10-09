# 模型定价记录

## GPT-6 Sol / Luna · 2026-09-23

OpenAI 官方 Standard、短上下文（输入不超过 272K tokens）API 单价，单位为美元 / 每百万 tokens：

| AIMonitor 模型 ID | 输入 | 缓存输入 | 缓存写入 | 输出 |
| --- | ---: | ---: | ---: | ---: |
| `gpt-6-sol` | $2.00 | $0.20 | $2.50 | $10.00 |
| `gpt-6-luna` | $0.10 | $0.01 | $0.125 | $0.50 |

来源：[OpenAI API Pricing](https://developers.openai.com/api/docs/pricing)、
[2026-09-22 发布记录](https://developers.openai.com/api/docs/changelog)。
缓存写入按输入价的 1.25 倍计算。输入超过 272K tokens 时，官方对整次请求的
输入及缓存费率收取 2 倍、输出费率收取 1.5 倍；AIMonitor 的本地增量日志
无法还原整次请求的上下文长度，因此只计算短上下文 Standard API 等价成本。
Fast、Batch、Flex 和区域处理费率也无法从本地 token 增量可靠判定。

新增价格只用于后续采集；已有记录需要按精确模型 ID 定向重算：

```sh
swift run aimonitor --recost "/path/to/aimonitor.db" --models gpt-6-sol,gpt-6-luna
```

## 先前定价更新 · 2026-09-07

本次联网核对并加入了数据库中可对应到官方模型的未定价 ID。金额均为
美元 / 每百万 tokens，展示的是 API 等价成本，不是订阅账单。

| AIMonitor 模型 ID | 官方对应模型 | 输入 | 缓存输入 | 输出 | 状态 |
| --- | --- | ---: | ---: | ---: | --- |
| `gpt-5.4` | OpenAI GPT-5.4 API | $2.50 | $0.25 | $15.00 | 已加入 |
| `kimi-code/k3` | Kimi Code `k3` / Kimi K3 | $3.00 | $0.30 | $15.00 | 已加入 |
| `k3-agent` | Kimi K3 Agent | $3.00 | $0.30 | $15.00 | 已加入 |
| `k2d6-agent` | Kimi K2.6 Agent | $0.95 | $0.16 | $4.00 | 已加入 |
| `kimi-code/kimi-for-coding` | Kimi K2.7 Code | $0.95 | $0.19 | $4.00 | 已加入 |
| `gpt-reserve` | OpenAI Luna Reserve → GPT-5.6 Luna | $0.20 | $0.02 | $1.20 | 已加入 |

官方来源：

- [OpenAI GPT-5.4 model page](https://developers.openai.com/api/docs/models/gpt-5.4)
- [OpenAI Luna Reserve in Codex and ChatGPT Work](https://help.openai.com/en/articles/20001499-luna-reserve-in-codex-and-chatgpt-work)
- [Kimi API Platform model cards](https://platform.kimi.ai/)
- [Kimi Code model IDs](https://www.kimi.com/code/docs/en/kimi-code/)
- [Kimi Code configuration examples](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files)
- [Kimi Code membership/credit billing](https://www.kimi.com/en/help/agent/agent-quota-and-billing)

映射边界：Kimi 官方说明 Kimi Code/Kimi Work 使用会员积分和额度，而不是公开的
逐请求订阅发票；因此上述 Kimi 数值只能作公开 API 单价对照。`k3-agent` 和
`k2d6-agent` 是本机桌面端日志里的内部模型 ID，分别根据 Kimi 官方说明映射到
K3 Agent 和 K2.6 Agent。OpenAI 官方说明 `gpt-reserve` 是 Luna Reserve 的内部
标识，备用使用只运行 GPT-5.6 Luna，所以这里沿用 GPT-5.6 Luna 的公开 API
单价；它不是 Reserved Tier 的容量费，也不是额外的 API 余额。

缓存输入不会再统一套用 0.1 倍：Kimi K2.6/K2.7 Code 的官方缓存输入价分别为
$0.16/$0.19；K3 为 $0.30。OpenAI GPT-5.4 的缓存输入价为 $0.25。

长上下文、Fast、Batch、Flex、区域处理和订阅额度折扣不从本地增量日志反推；
实际账单仍然是 `n/a`。历史成本已通过 `--recost` 按每条事件的原始时间戳重算。

## 已有历史

价格在采集时写入数据库，更新 App 不会自动重写所有历史。退出 App 并备份数据后，可用源码构建的命令行工具只重算指定的**精确模型 ID**：

```sh
swift run aimonitor --recost "/path/to/aimonitor.db" --models gpt-5.4,gpt-reserve,kimi-code/k3,k3-agent,k2d6-agent,kimi-code/kimi-for-coding
```

日期快照如需重算，须显式加入逗号分隔列表。空列表或非法参数会被拒绝；不传 `--models` 则保持原有的全库重算行为。历史 token 数、会话、时间戳和其他模型成本不因定向重算而改变。
