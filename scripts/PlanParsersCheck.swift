import Foundation

/// 解析口径自检：用各家真实响应的形态驱动纯解析函数，不联网、不需要凭据。
///
/// swiftc -O Shared/Models.swift Shared/QueryService.swift scripts/PlanParsersCheck.swift \
///        -o build/planparsers && ./build/planparsers
///
/// 这里的 fixture 取自 cc-switch `src-tauri/src/services/coding_plan.rs` 的单元测试样例
/// （官方文档 / 实测响应），字段名与嵌套层级保持一致；上游改形态时先改这里。
@main
struct PlanParsersCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("✅ \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("❌ \(label)" + (extra.isEmpty ? "" : " —— \(extra)"))
        }
    }

    static func close(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool {
        abs(a - b) < eps
    }

    static func main() {
        checkKimi()
        checkMiniMax()
        checkZenMux()
        checkOllamaCloud()
        checkMimo()
        checkCommandCode()
        checkWindowOrdering()
        checkPrimaryWindow()

        print("")
        if failures == 0 {
            print("全部通过")
        } else {
            print("\(failures) 项失败")
            exit(1)
        }
    }

    // MARK: Kimi For Coding

    static func checkKimi() {
        // limits[].detail = 5 小时窗口（次数），usage = 周窗口；两处都给「剩余」
        let body: [String: Any] = [
            "limits": [
                ["window": ["duration": 5, "unit": "hour"],
                 "detail": ["limit": 100, "remaining": 25,
                            "resetTime": "2026-11-25T08:00:00Z"]] as [String: Any],
            ],
            "usage": ["limit": 1000, "remaining": 400,
                      "resetTime": "2026-11-30T00:00:00Z"] as [String: Any],
        ]
        let windows = QueryService.parseKimiUsage(body)
        expect(windows.count == 2, "Kimi: 解析出 5 小时 + 周两个窗口", "得到 \(windows.count)")
        if windows.count == 2 {
            expect(windows[0].name == QuotaWindow.fiveHour, "Kimi: 第一个窗口是 5 小时")
            expect(close(windows[0].percent, 75), "Kimi: 5h 已用 75%（limit 100 / remaining 25）",
                   "得到 \(windows[0].percent)")
            expect(close(windows[0].used ?? -1, 75), "Kimi: 5h used 换算正确")
            expect(close(windows[0].total ?? -1, 100), "Kimi: 5h total 是 limit")
            expect(windows[0].resetTime != nil, "Kimi: 5h 解析出重置时间")
            expect(windows[1].name == QuotaWindow.weekly, "Kimi: 第二个窗口是周")
            expect(close(windows[1].percent, 60), "Kimi: 周已用 60%",
                   "得到 \(windows[1].percent)")
        }

        // 只有 usage（老套餐 / 无 5 小时窗口）时不能整体失败
        let weeklyOnly: [String: Any] = ["usage": ["limit": 500, "remaining": 500]]
        let only = QueryService.parseKimiUsage(weeklyOnly)
        expect(only.count == 1 && only[0].name == QuotaWindow.weekly,
               "Kimi: 缺 limits 时只出周窗口，不整体失败")

        // limit 为 0 / 缺失 → 跳过该窗口
        let broken: [String: Any] = [
            "limits": [["detail": ["limit": 0, "remaining": 0]] as [String: Any]],
            "usage": ["remaining": 10] as [String: Any],
        ]
        expect(QueryService.parseKimiUsage(broken).isEmpty, "Kimi: 无有效 limit 时返回空而不是瞎算")
    }

    // MARK: MiniMax

    static func checkMiniMax() {
        let body: [String: Any] = [
            "model_remains": [
                ["model_name": "video", "current_interval_remaining_percent": 10.0] as [String: Any],
                ["model_name": "general",
                 "current_interval_remaining_percent": 62.0,
                 "end_time": 1_800_000_000_000,
                 "current_weekly_status": 1,
                 "current_weekly_remaining_percent": 30.0,
                 "weekly_end_time": 1_800_600_000_000] as [String: Any],
            ],
        ]
        let windows = QueryService.parseMiniMaxTiers(body)
        expect(windows.count == 2, "MiniMax: general 出 5h + 周两窗口", "得到 \(windows.count)")
        if windows.count == 2 {
            expect(close(windows[0].percent, 38), "MiniMax: 5h 已用 38%（剩余 62 反转）",
                   "得到 \(windows[0].percent)")
            expect(close(windows[1].percent, 70), "MiniMax: 周已用 70%（剩余 30 反转）",
                   "得到 \(windows[1].percent)")
        }

        // 周桶 status=3 → 该套餐无周限额，跳过
        let noWeekly: [String: Any] = [
            "model_remains": [["model_name": "general",
                               "current_interval_remaining_percent": 100.0,
                               "current_weekly_status": 3,
                               "current_weekly_remaining_percent": 100.0] as [String: Any]],
        ]
        let single = QueryService.parseMiniMaxTiers(noWeekly)
        expect(single.count == 1 && single[0].name == QuotaWindow.fiveHour,
               "MiniMax: weekly_status=3 只留 5h 窗口")

        // status=2 = 周额度已耗尽，仍要展示（不能当成没订阅）
        let exhausted: [String: Any] = [
            "model_remains": [["model_name": "general",
                               "current_interval_remaining_percent": 50.0,
                               "current_weekly_status": 2,
                               "current_weekly_remaining_percent": 0.0] as [String: Any]],
        ]
        let exh = QueryService.parseMiniMaxTiers(exhausted)
        expect(exh.count == 2 && close(exh[1].percent, 100),
               "MiniMax: weekly_status=2 展示成 100% 已用")

        // 只有 video、没有 general → 空（不能拿 video 顶替）
        let videoOnly: [String: Any] = [
            "model_remains": [["model_name": "video",
                               "current_interval_remaining_percent": 50.0] as [String: Any]],
        ]
        expect(QueryService.parseMiniMaxTiers(videoOnly).isEmpty,
               "MiniMax: 只有 video 时返回空")
    }

    // MARK: ZenMux

    static func checkZenMux() {
        // usage_percentage 实测是 0-1 分数
        let data: [String: Any] = [
            "quota_5_hour": ["usage_percentage": 0.42,
                             "used_value_usd": 4.2, "max_value_usd": 10.0,
                             "resets_at": "2026-11-25T08:00:00Z"] as [String: Any],
            "quota_7_day": ["usage_percentage": 0.13,
                            "used_value_usd": 6.5, "max_value_usd": 50.0,
                            "resets_at": "2026-11-30T00:00:00Z"] as [String: Any],
            "plan": ["tier": "pro"] as [String: Any],
        ]
        let windows = QueryService.parseZenMuxTiers(data)
        expect(windows.count == 2, "ZenMux: 两个窗口", "得到 \(windows.count)")
        if windows.count == 2 {
            expect(close(windows[0].percent, 42), "ZenMux: 0-1 分数放大成 42%",
                   "得到 \(windows[0].percent)")
            expect(close(windows[1].percent, 13), "ZenMux: 周窗口 13%",
                   "得到 \(windows[1].percent)")
            expect(windows[0].unit == "USD", "ZenMux: 有 max_value_usd 时单位是 USD")
            expect(close(windows[0].remaining ?? -1, 5.8, 1e-6),
                   "ZenMux: 剩余 = total - used = 5.8")
        }

        // 0-100 形态（>1 的值）不能被继续放大
        let percentForm: [String: Any] = [
            "quota_5_hour": ["usage_percentage": 42.0] as [String: Any],
        ]
        let scaled = QueryService.parseZenMuxTiers(percentForm)
        expect(scaled.count == 1 && close(scaled[0].percent, 42),
               "ZenMux: 已是 0-100 时不重复放大", "得到 \(scaled.first?.percent ?? -1)")

        // 全 0 时判不出形态，但不该放大成 0 → 仍然是 0
        let zeros: [String: Any] = [
            "quota_5_hour": ["usage_percentage": 0.0] as [String: Any],
            "quota_7_day": ["usage_percentage": 0.0] as [String: Any],
        ]
        expect(QueryService.parseZenMuxTiers(zeros).allSatisfy { $0.percent == 0 },
               "ZenMux: 全 0 时保持 0")

        expect(QueryService.parseZenMuxTiers([:]).isEmpty, "ZenMux: 空 data 返回空")
    }

    // MARK: Ollama Cloud

    static func checkOllamaCloud() {
        let monthly: [String: Any] = [
            "included": [
                "balance_usd": 72.5,
                "allowance_usd": 100.0,
                "period": ["from": "2026-11-01T00:00:00Z",
                           "until": "2026-12-01T00:00:00Z"] as [String: Any],
            ] as [String: Any],
            "purchased": ["balance_usd": 25.0] as [String: Any],
        ]
        let tiers = QueryService.parseOllamaCloudTiers(monthly)
        expect(tiers.count == 1, "Ollama Cloud: 新套餐出一个月度档", "得到 \(tiers.count)")
        if let first = tiers.first {
            expect(first.name == QuotaWindow.monthly, "Ollama Cloud: 新套餐是月度档")
            expect(close(first.percent, 27.5), "Ollama Cloud: 已用 27.5%",
                   "得到 \(first.percent)")
            expect(first.resetTime != nil, "Ollama Cloud: 解析出周期结束时间")
        }

        let legacy: [String: Any] = [
            "included": [
                "session": ["remaining_percent": 80.0,
                            "resets_at": "2026-11-10T13:00:00Z"] as [String: Any],
                "weekly": ["remaining_percent": 35.5,
                           "resets_at": "2026-11-14T00:00:00Z"] as [String: Any],
            ] as [String: Any],
        ]
        let old = QueryService.parseOllamaCloudTiers(legacy)
        expect(old.count == 2, "Ollama Cloud: 老套餐出 5h + 周", "得到 \(old.count)")
        if old.count == 2 {
            expect(close(old[0].percent, 20), "Ollama Cloud: session 剩余 80 → 已用 20",
                   "得到 \(old[0].percent)")
            expect(close(old[1].percent, 64.5), "Ollama Cloud: weekly 剩余 35.5 → 已用 64.5",
                   "得到 \(old[1].percent)")
        }

        // allowance_usd = 0 → 按量付费账户，没有套餐额度
        let payg: [String: Any] = ["included": ["allowance_usd": 0.0] as [String: Any]]
        expect(QueryService.parseOllamaCloudTiers(payg).isEmpty,
               "Ollama Cloud: allowance 0 时不出档位（由调用方给按量付费提示）")
        expect(QueryService.parseOllamaCloudTiers([:]).isEmpty, "Ollama Cloud: 空响应返回空")
    }

    // MARK: 小米 MiMo Token Plan

    static func checkMimo() {
        // 官方文档示例（mimo.mi.com/docs/zh-CN/api/asset/credits-get）
        let body: [String: Any] = [
            "object": "token_plan",
            "plan_code": "pro",
            "period": ["start_at": "2026-09-21 23:59:59",
                       "end_at": "2027-09-21 23:59:59"] as [String: Any],
            "quota": ["total_credits": 10_000_000,
                      "used_credits": 1_500_000,
                      "remaining_credits": 8_500_000] as [String: Any],
        ]
        let tiers = QueryService.parseMimoTokenPlanTiers(body)
        expect(tiers.count == 1, "MiMo: 出一个额度档", "得到 \(tiers.count)")
        if let first = tiers.first {
            expect(first.name == QuotaWindow.credits, "MiMo: 档位名是「额度」而不是「月」")
            expect(close(first.percent, 15), "MiMo: 已用 15%", "得到 \(first.percent)")
            expect(close(first.total ?? -1, 10_000_000), "MiMo: 总额取 total_credits")
            if let reset = first.resetTime {
                // 2027-09-21 23:59:59 UTC
                let expected = Date(timeIntervalSince1970: 1_821_571_199)
                expect(close(reset.timeIntervalSince1970, expected.timeIntervalSince1970, 1),
                       "MiMo: 无 T 无时区的时间按 UTC 解析",
                       "得到 \(reset.timeIntervalSince1970)，期望 \(expected.timeIntervalSince1970)")
            } else {
                expect(false, "MiMo: 应解析出周期结束时间")
            }
        }

        // 只给 remaining_credits 也能算
        let remainingOnly: [String: Any] = [
            "quota": ["total_credits": 200, "remaining_credits": 50] as [String: Any],
        ]
        let derived = QueryService.parseMimoTokenPlanTiers(remainingOnly)
        expect(derived.count == 1 && close(derived[0].percent, 75),
               "MiMo: 只有 remaining 时已用 = 75%",
               "得到 \(derived.first?.percent ?? -1)")

        // 超用封顶 100%
        let over: [String: Any] = [
            "quota": ["total_credits": 100, "used_credits": 120] as [String: Any],
        ]
        expect(close(QueryService.parseMimoTokenPlanTiers(over)[0].percent, 100),
               "MiMo: 超用封顶 100%")

        // 无额度 / 缺字段 → 空
        for (label, body) in [
            ("空响应", [String: Any]()),
            ("total_credits=0", ["quota": ["total_credits": 0, "used_credits": 0] as [String: Any]]),
            ("只有 total", ["quota": ["total_credits": 100] as [String: Any]]),
        ] {
            expect(QueryService.parseMimoTokenPlanTiers(body).isEmpty,
                   "MiMo: \(label) 返回空而不是瞎算")
        }
    }

    // MARK: CommandCode（GOAT 等套餐）

    /// fixture 取自 2026-11-27 实测的 /alpha 响应（GOAT 周期内），字段层级与真实报文一致。
    static func checkCommandCode() {
        let credits: [String: Any] = [
            "credits": ["monthlyCredits": 32.3878278101,
                        "purchasedCredits": 0, "freeCredits": 0],
            "windowLimits": [
                "limited": true,
                "fiveHour": ["used": 0.1034115348, "cap": 14],
                "weekly": ["used": 5.6383312296, "cap": 35],
            ],
        ]
        let monthly = QueryService.parseCommandCode(
            credits: credits, spent: 37.878413964299995,
            planID: "individual-goat", periodEnd: nil)
        expect(monthly.ok, "CommandCode: 有窗口时解析成功", "得到 \(monthly.errorMessage ?? "")")
        expect(monthly.subtitle == "GOAT", "CommandCode: planId individual-goat → GOAT")
        expect(monthly.windows.count == 3, "CommandCode: 出 5h + 周 + 月三档", "得到 \(monthly.windows.count)")

        let byName = Dictionary(uniqueKeysWithValues: monthly.windows.map { ($0.name, $0) })
        expect(close(byName[QuotaWindow.fiveHour]?.percent ?? -1, 0.1034115348 / 14 * 100),
               "CommandCode: 5h = used/cap")
        expect(close(byName[QuotaWindow.weekly]?.percent ?? -1, 5.6383312296 / 35 * 100),
               "CommandCode: 周 = used/cap")

        // 核心：credits 是「剩余」，总额 = 已花 + 剩余。按 spent/剩余 会算成 117% 被截到 100%。
        let month = byName[QuotaWindow.monthly]
        expect(close(month?.percent ?? -1, 37.878413964299995 / (37.878413964299995 + 32.3878278101) * 100),
               "CommandCode: 月 = 已花 ÷(已花 + 剩余)，不是 ÷ 剩余",
               "得到 \(month?.percent ?? -1)")
        expect(close(month?.total ?? -1, 37.878413964299995 + 32.3878278101),
               "CommandCode: 月总额 = 已花 + 剩余")
        expect(close(month?.remainingOverride ?? -1, 32.3878278101),
               "CommandCode: 月剩余取 credits 池")
        expect((month?.percent ?? 100) < 60,
               "CommandCode: 还有 $32 余额时不能显示成满额",
               "得到 \(month?.percent ?? -1)")

        // 纯按量（limited=false）：不出滚动窗口，只出月度档
        let payg: [String: Any] = [
            "credits": ["monthlyCredits": 20.0, "purchasedCredits": 0, "freeCredits": 0],
            "windowLimits": ["limited": false],
        ]
        let paygUsage = QueryService.parseCommandCode(credits: payg, spent: 50, planID: "provider", periodEnd: nil)
        expect(paygUsage.windows.count == 1 && paygUsage.windows[0].name == QuotaWindow.monthly,
               "CommandCode: limited=false 不出滚动窗口")

        // cap 缺省 / 为 0 的窗口跳过
        let noCap: [String: Any] = [
            "credits": ["monthlyCredits": 10.0],
            "windowLimits": ["limited": true,
                             "fiveHour": ["used": 1, "cap": 0],
                             "weekly": ["used": 2, "cap": 0]],
        ]
        let noCapUsage = QueryService.parseCommandCode(credits: noCap, spent: 5, planID: "", periodEnd: nil)
        expect(noCapUsage.windows.count == 1 && noCapUsage.windows[0].name == QuotaWindow.monthly,
               "CommandCode: cap<=0 的窗口跳过，只剩月度档")

        // 池与窗口都为空 → 明确失败，而不是给一个空壳成功
        let empty: [String: Any] = ["credits": [:]]
        expect(!QueryService.parseCommandCode(credits: empty, spent: 0, planID: "", periodEnd: nil).ok,
               "CommandCode: 无池无窗口时返回失败")

        // ── 套餐 vs 付费分池：买了充值不能稀释套餐使用率
        //    套餐 50 已花 + 20 剩余（总额 70），另充值 30 未花
        let mixed: [String: Any] = [
            "credits": ["monthlyCredits": 20.0, "purchasedCredits": 30.0, "freeCredits": 0],
            "windowLimits": ["limited": false],
        ]
        let split = QueryService.parseCommandCode(
            credits: mixed, spent: 68, planID: "individual-goat", periodEnd: nil,
            monthlySpent: 50)
        let splitMonthly = split.windows.first { $0.name == QuotaWindow.monthly }
        expect(close(splitMonthly?.percent ?? -1, 50.0 / 70.0 * 100),
               "CommandCode: 充值不稀释套餐月使用率（套餐 50/70 = 71.4%）",
               "得到 \(splitMonthly?.percent ?? -1)")
        expect(close(splitMonthly?.remainingOverride ?? -1, 20),
               "CommandCode: 月剩余只算 monthly 池，不含充值")
        expect(close(split.paidBalance ?? -1, 30),
               "CommandCode: 付费额度单独记为 paidBalance = purchased + free")
        expect(!split.windows.contains { $0.name == QuotaWindow.credits },
               "CommandCode: 付费额度不塞进 windows（否则菜单栏会显示「付费 0%」）")

        // 无充值时不出现付费额度，避免每行都多一个 $0.00
        expect(monthly.paidBalance == nil, "CommandCode: 无充值时不生成付费额度")

        // 纯按量 + 只有充值余额：不报「套餐未生效」，靠 paidBalance 托底
        let paygPaid: [String: Any] = [
            "credits": ["monthlyCredits": 0, "purchasedCredits": 12.5],
            "windowLimits": ["limited": false],
        ]
        let paygPaidUsage = QueryService.parseCommandCode(
            credits: paygPaid, spent: 7.5, planID: "provider", periodEnd: nil,
            monthlySpent: 0)
        expect(paygPaidUsage.ok && close(paygPaidUsage.paidBalance ?? -1, 12.5),
               "CommandCode: 纯按量只有付费余额时仍成功，paidBalance=12.5")

        // summary 缺分池字段 → 按剩余占比摊销，不能整体失败
        let fallback = QueryService.parseCommandCode(
            credits: mixed, spent: 68, planID: "", periodEnd: nil)
        expect(fallback.ok, "CommandCode: 缺分池字段时摊销兜底而不是失败")
        let monthlySpentApprox = 68 * (20.0 / 50.0)
        expect(close(fallback.windows.first { $0.name == QuotaWindow.monthly }?.percent ?? -1,
                     monthlySpentApprox / (monthlySpentApprox + 20) * 100),
               "CommandCode: 摊销后套餐已花 = 68 ×(20/50)")
    }

    // MARK: 展示排序

    static func checkWindowOrdering() {
        let names = [QuotaWindow.credits, QuotaWindow.monthly,
                     QuotaWindow.weekly, QuotaWindow.fiveHour]
        let sorted = names.sorted { $0 < $1 }
        expect(sorted == [QuotaWindow.fiveHour, QuotaWindow.weekly,
                          QuotaWindow.monthly, QuotaWindow.credits],
               "窗口展示顺序：5小时 → 7天 → 月 → 额度", "得到 \(sorted)")
    }

    // MARK: 主窗口选取

    /// primaryWindow 要取「使用率最高」，否则 CommandCode 的月 53.9% 会被 5h 的 0.7% 顶掉
    static func checkPrimaryWindow() {
        func usage(_ percents: [(String, Double)]) -> ProviderUsage {
            ProviderUsage(kind: .commandCode, ok: true,
                          windows: percents.map { QuotaWindow(name: $0.0, percent: $0.1) })
        }
        let cc = usage([(QuotaWindow.fiveHour, 0.74), (QuotaWindow.weekly, 16.11), (QuotaWindow.monthly, 53.91)])
        expect(cc.primaryWindow?.name == QuotaWindow.monthly,
               "主窗口：取使用率最高的月档，不是排第一的 5h",
               "得到 \(cc.primaryWindow?.name ?? "nil")")
        let hot = usage([(QuotaWindow.fiveHour, 92), (QuotaWindow.weekly, 30), (QuotaWindow.monthly, 40)])
        expect(hot.primaryWindow?.name == QuotaWindow.fiveHour,
               "主窗口：5h 最紧张时取 5h")
        expect(usage([]).primaryWindow == nil, "主窗口：无窗口时为 nil")
    }
}
