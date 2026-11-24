import Foundation

/// 各订阅/平台当前支持的模型与价格（静态资料，数据来自官方页面，见各 sourceURL）。
/// 不进 CLI 编译单元；供 App「模型」页与大号小组件页脚使用。
enum ModelCatalog {
    /// 资料核对日期（展示用）
    static let asOf = "2026-09-10"

    struct ExternalLink: Identifiable {
        let label: String
        let url: URL
        var id: String { label }
    }

    // MARK: 方舟 Coding Plan（火山引擎）

    struct ArkPlan {
        let title = "方舟 Coding Plan"
        let subtitle = "火山引擎 · 多模型订阅，可自由切换或 Auto 调度"
        let models = [
            "Doubao-Seed-2.1-turbo",
            "DeepSeek-V4 / DeepSeek-V4-Flash",
            "GLM-5.3",
            "Kimi-K2.7",
            "MiniMax-M3",
            "Auto 智能调度（自动选择模型）",
        ]
        let notes = [
            "额度按 5 小时 / 7 天 / 月 三个窗口滚动重置",
            "模型阵容动态更新，以官方活动页为准",
        ]
        let sourceURL = URL(string: "https://www.volcengine.com/activity/codingplan")!
        /// 大号小组件页脚用的一行摘要
        var summary: String { "GLM-5.3 · Kimi-K2.7 · Doubao-Seed-2.1-turbo · MiniMax-M3 · DeepSeek-V4 · Auto" }
    }
    static let ark = ArkPlan()

    // MARK: GLM Coding Plan（智谱）

    struct CreditRate: Identifiable {
        let model: String
        let input: String
        let cached: String
        let output: String
        var id: String { model }
    }

    struct GLMPlan {
        let title = "GLM Coding Plan"
        let subtitle = "智谱 BigModel · Lite / Pro / Max 三档套餐"
        let models = [
            "GLM-5.3（所有套餐）",
            "GLM-5.3-Flash（所有套餐）",
            "GLM-5.2 / GLM-5.1 → 自动切换至 GLM-5.3",
            "GLM-5-Turbo / GLM-4.7 → 自动切换至 GLM-5.3-Flash",
        ]
        /// 积分抵扣系数（每万 tokens）：输入 / 缓存命中 / 输出
        let creditRates = [
            CreditRate(model: "GLM-5.3", input: "6.9", cached: "1.7", output: "24"),
            CreditRate(model: "GLM-5.3-Flash", input: "2.3", cached: "0.56", output: "8"),
        ]
        let notes = [
            "5 小时 / 7 天 双窗口积分额度，非高峰时段仅扣 50% 积分",
            "附带 MCP：联网搜索、网页读取、开源仓库读取（1.2 积分 / 次）",
            "支持 Claude Code、Cline、Roo Code、Kilo Code 等 10+ 编码工具",
        ]
        let sourceURL = URL(string: "https://docs.bigmodel.cn/cn/coding-plan/overview")!
        var summary: String { "GLM-5.3 · GLM-5.3-Flash（旧版 5.2 / 5.1 / 4.7 自动切换）" }
    }
    static let glm = GLMPlan()

    // MARK: DeepSeek 按量计费

    struct DeepSeekModel: Identifiable {
        let name: String
        let version: String
        let context: String
        /// 每百万 tokens 人民币价格：(空闲时段, 高峰时段)
        let inputCacheHit: (offPeak: String, peak: String)
        let inputCacheMiss: (offPeak: String, peak: String)
        let output: (offPeak: String, peak: String)
        let concurrency: String
        var id: String { name }
    }

    struct DeepSeekPlatform {
        let title = "DeepSeek 开放平台"
        let subtitle = "按量计费 · 价格单位：元 / 百万 tokens（空闲 / 高峰）"
        let models = [
            DeepSeekModel(name: "deepseek-v4-flash", version: "DeepSeek-V4-Flash-0731", context: "1M 上下文 · 最大 384K 输出",
                          inputCacheHit: ("0.05", "0.10"), inputCacheMiss: ("1.5", "3.0"), output: ("4.5", "9.0"), concurrency: "2500"),
            DeepSeekModel(name: "deepseek-v4-pro", version: "DeepSeek-V4-Pro-0813", context: "1M 上下文 · 最大 384K 输出",
                          inputCacheHit: ("0.15", "0.30"), inputCacheMiss: ("4.5", "9.0"), output: ("13.5", "27.0"), concurrency: "500"),
            DeepSeekModel(name: "deepseek-v4-flash-vision-exp", version: "DeepSeek-V4-Flash-Vision-Exp", context: "1M 上下文 · 支持图像输入",
                          inputCacheHit: ("0.05", "0.10"), inputCacheMiss: ("1.5", "3.0"), output: ("4.5", "9.0"), concurrency: "2500"),
        ]
        let notes = [
            "高峰时段：北京时间周一至周五 9:00–12:00、14:00–18:00；其余为空闲时段，价格为高峰的一半",
            "三款模型均支持思考 / 非思考模式切换、JSON Output、Tool Calls、Anthropic 兼容接口",
            "费用直接从充值余额或赠送余额扣减；价格可能变动，以官方页面为准",
        ]
        let sourceURL = URL(string: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing/")!
    }
    static let deepseek = DeepSeekPlatform()

    // MARK: OpenCode Go

    struct OpenCodeGoModel: Identifiable {
        let name: String
        /// 每百万 tokens 美元价格
        let input: String
        let output: String
        let cachedRead: String
        /// 该模型每月可用额度上限（美元）
        let monthlyLimit: String
        var id: String { name }
    }

    struct OpenCodeGoPlan {
        let title = "OpenCode Go"
        let subtitle = "$10 / 月（首月 $5）· 额度 $12 / 5 小时 · $30 / 周 · $60 / 月"
        let models = [
            OpenCodeGoModel(name: "Omen Alpha", input: "$0.20", output: "$0.66", cachedRead: "$0.04", monthlyLimit: "$100"),
            OpenCodeGoModel(name: "GLM-5.3-Flash", input: "$0.15", output: "$0.50", cachedRead: "$0.03", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "GLM-5.3", input: "$1.40", output: "$4.40", cachedRead: "$0.26", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "GLM-5.2", input: "$1.40", output: "$4.40", cachedRead: "$0.26", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "GLM-5.1", input: "$1.40", output: "$4.40", cachedRead: "$0.26", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Kimi K3", input: "$3.00", output: "$15.00", cachedRead: "$0.30", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "Kimi K2.7 Code", input: "$0.95", output: "$4.00", cachedRead: "$0.19", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Kimi K2.6", input: "$0.95", output: "$4.00", cachedRead: "$0.16", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "LongCat-2.0", input: "$0.30", output: "$1.20", cachedRead: "$0.006", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "MiMo V2.5", input: "$0.14", output: "$0.28", cachedRead: "$0.0028", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "MiMo V2.5 Pro", input: "$0.435", output: "$0.87", cachedRead: "$0.0036", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "MiniMax M3", input: "$0.30", output: "$1.20", cachedRead: "$0.06", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "MiniMax M2.7", input: "$0.30", output: "$1.20", cachedRead: "$0.06", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "MiniMax M2.5", input: "$0.30", output: "$1.20", cachedRead: "$0.06", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Muse Spark 1.3 Contributor", input: "$0.10", output: "$0.20", cachedRead: "$0.002", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Muse Spark 1.2 Contributor", input: "$0.10", output: "$0.20", cachedRead: "$0.002", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Qwen3.8 Max", input: "$2.00", output: "$6.00", cachedRead: "$0.25", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "Qwen3.8 Flash", input: "$0.15", output: "$0.47", cachedRead: "$0.016", monthlyLimit: "$30"),
            OpenCodeGoModel(name: "Qwen3.7 Max", input: "$2.50", output: "$7.50", cachedRead: "$0.50", monthlyLimit: "$30"),
            OpenCodeGoModel(name: "Qwen3.7 Plus（≤256K）", input: "$0.40", output: "$1.60", cachedRead: "$0.04", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Qwen3.7 Plus（>256K）", input: "$1.20", output: "$4.80", cachedRead: "$0.12", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Qwen3.6 Plus（≤256K）", input: "$0.50", output: "$3.00", cachedRead: "$0.05", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Qwen3.6 Plus（>256K）", input: "$2.00", output: "$6.00", cachedRead: "$0.20", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "DeepSeek V4.1 Flash（空闲 / 高峰）", input: "$0.15 / $0.30", output: "$0.60 / $1.20", cachedRead: "$0.003 / $0.006", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "DeepSeek V4 Pro（空闲 / 高峰）", input: "$0.66 / $1.32", output: "$1.98 / $3.96", cachedRead: "$0.022 / $0.044", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "DeepSeek V4 Flash（空闲 / 高峰）", input: "$0.15 / $0.30", output: "$0.60 / $1.20", cachedRead: "$0.003 / $0.006", monthlyLimit: "$30"),
            OpenCodeGoModel(name: "DeepSeek V4 Flash Vision Exp（空闲 / 高峰）", input: "$0.15 / $0.30", output: "$0.60 / $1.20", cachedRead: "$0.003 / $0.006", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "Hy4 preview", input: "$0.834", output: "$2.501", cachedRead: "$0.042", monthlyLimit: "$30"),
            OpenCodeGoModel(name: "Hy3", input: "$0.14", output: "$0.58", cachedRead: "$0.035", monthlyLimit: "$60"),
            OpenCodeGoModel(name: "Grok 4.6（≤200K）", input: "$2.00", output: "$6.00", cachedRead: "$0.50", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "Grok 4.6（>200K）", input: "$4.00", output: "$12.00", cachedRead: "$1.00", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "GPT 5.6 Luna（≤272K）", input: "$0.20", output: "$1.20", cachedRead: "$0.02", monthlyLimit: "$15"),
            OpenCodeGoModel(name: "GPT 5.6 Luna（>272K）", input: "$0.40", output: "$1.80", cachedRead: "$0.04", monthlyLimit: "$15"),
        ]
        let notes = [
            "一个 API Key 可配合 OpenCode、Claude Code（经 cc-switch）、Codex、Kilo Code 等任意代理使用",
            "价格单位：美元 / 百万 tokens；「月上限」为该模型单独的每月可用额度",
            "GLM、Kimi、Qwen、DeepSeek、MiniMax、MiMo 等模型 0 天数据留存，数据不用于训练",
        ]
        let sourceURL = URL(string: "https://opencode.ai/docs/go/")!
        let homeURL = URL(string: "https://opencode.ai/go")!
        /// 大号小组件页脚用的一行摘要
        var summary: String {
            "GLM-5.3 · Kimi K3/K2.7 · Qwen3.8 · DeepSeek-V4 · MiniMax-M3 · MiMo V2.5"
        }
    }
    static let opencodeGo = OpenCodeGoPlan()

    // MARK: CommandCode（GOAT / Pro / Max 套餐）

    struct CommandCodePlan {
        let title = "CommandCode"
        let subtitle = "能力型订阅套餐 · 一次订阅调用多厂模型（走 Anthropic / OpenAI 兼容网关）"
        let models = [
            "deepseek/deepseek-v4.1-flash（1M 上下文）",
            "z-ai/glm-5.3-flash（1M 上下文）",
            "moonshotai/Kimi-K3.1-Pro（约 1M 上下文）",
            "xiaomi/mimo-v2.6-flash / mimo-v2.6-pro（1M 上下文）",
            "Qwen/Qwen3.8-27B（256K 上下文）",
            "claude-fable-5-2（1M 上下文）",
        ]
        let notes = [
            "额度以美元的 credits 池计算：5 小时 / 周 为滚动窗口，月度按订阅周期（见账单页）",
            "credits 接口返回的是「剩余」，所以本应用的月度使用率按 已花 ÷(已花 + 剩余) 计算",
            "查询走官方 CLI 内部使用的 /alpha 私有路由，字段口径随上游可能变动，失败时面板会直接给出原因",
        ]
        let sourceURL = URL(string: "https://commandcode.ai")!
        /// 大号小组件页脚用的一行摘要
        var summary: String {
            "DeepSeek-V4.1 · GLM-5.3 · Kimi-K3.1 · MiMo-V2.6 · Qwen3.8 · Claude"
        }
    }
    static let commandCode = CommandCodePlan()
}
