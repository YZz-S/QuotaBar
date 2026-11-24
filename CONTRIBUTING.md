# 贡献指南

感谢你愿意改进 QuotaBar。这个项目规模不大，流程也就保持简单。

## 开发环境

- macOS 15+，Xcode 16+（工程用 `MACOSX_DEPLOYMENT_TARGET = 15.0`）
- Windows 端只需要 Python 3.10+，无第三方依赖

## 提交前自检

```bash
# 1) 终端自检：不依赖 Xcode 工程，直接验证凭据识别与全部接口解析
swiftc -O Shared/Models.swift Shared/ProvidersStore.swift Shared/QueryService.swift \
       Shared/SnapshotCache.swift scripts/UsageCheck.swift -o build/usagecheck && ./build/usagecheck

# 2) 解析口径自检：用各家真实响应形态驱动纯解析函数（不联网、不需要凭据）
swiftc -O Shared/Models.swift Shared/QueryService.swift \
       scripts/PlanParsersCheck.swift -o build/planparsers && ./build/planparsers

# 3) 完整构建（要求两个 target 都通过）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project QuotaBar.xcodeproj -target QuotaBar \
  -configuration Release SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build

# 4) 改了 Windows 端
python3 windows/api_usage.py --list
python3 windows/api_usage.py --no-color
```

**改动涉及 macOS 与 Windows 两端时，请两边都跑通再提交** —— 两端的解析口径是刻意对齐的（同样的字段、同样的百分比算法），只改一边会让两边显示不一致。

## 新增一个供应商

照现有实现补五处，缺一处界面就会显示不完整：

1. `Shared/Models.swift` — `ProviderKind` 加 case、`displayName`、`consoleURL`；`ProviderCredentials` 的 `keyDescription` / `isComplete` 加分支
2. `Shared/ProvidersStore.swift` — `identify()` 里加凭据识别规则（主机名按标签边界匹配、需要路径前缀的写清楚），并把新 kind 加进 `ProviderKind.displayOrder`
3. `Shared/QueryService.swift` — `fetch()` 的 switch 加分支 + 实现 `fetchXxx`；**解析逻辑拆成纯函数**（如 `parseMiniMaxTiers`）便于 `scripts/PlanParsersCheck.swift` 校验
4. `Shared/ViewHelpers.swift` — `iconSymbol` 与 `brandColor`
5. `App/QuotaAlertCenter.swift` — 若是窗口型，`AlertConfig` 加阈值字段并在 `windowThreshold(for:)` 里返回；同步 `App/SettingsView.swift` 的两处表单（手动 Key 输入 + 阈值滑块）

Windows 端对应 `windows/api_usage.py` 的 `KIND_ORDER` / `DISPLAY_NAME` / `_identify` / `FETCHERS` / `THRESHOLD_KEY` / `credential_brief`。

字段口径与端点可参考 cc-switch 自己的实现：`src-tauri/src/services/coding_plan.rs`（Kimi / 智谱 / MiniMax / ZenMux / 火山 / OpenCode Go / CommandCode / Ollama Cloud / MiMo 全在里面）。

## 解析接口时的两条硬规则

**1. 百分比口径必须实测验证，不能照抄。** 同一个字段名在不同套餐下语义可能相反。已有教训：CommandCode 的 `billing/credits` 返回的是**剩余**池而不是总额，照抄"已花 ÷ 剩余"会把 44% 算成 78%，周期后段尤其失真。新增解析前，请先用 curl 拉真实响应，确认每个数字到底是"已用"还是"剩余"。

**2. 宽松解析，不要因为一个字段缺失就整体失败。** 这些接口会变。取值用 `JSONUtil` 的多字段候选（`JSONUtil.double(dict, "a", "b")`），窗口节点缺失就当该窗口未订阅、跳过。只有真正无法解释时才报错，且错误信息要能让人知道下一步查哪里。

## 不要提交的东西

- 任何真实 API Key、AK/SK、webhook 地址（`git grep -nE 'sk-[A-Za-z0-9_-]{20,}'` 自查）
- `build/`、`.DS_Store`、`xcuserdata/`
- 你自己 Team ID 之外的签名配置改动（除非是文档改进）

## 提交信息

用 `feat: / fix: / docs: / refactor:` 前缀，正文说清"为什么"而不只是"改了什么"。如果一个改动修的是口径或算法错误，把实测数据写进去 —— 这是后来人判断该不该信这段代码的唯一依据。

## 提问与报 bug

开 issue 时请附上：

- 哪个供应商、哪个窗口显示不对
- 错误提示原文（面板会显示接口返回的原因，不会静默失败）
- 若方便，用 curl 拉一次响应并**脱敏**后贴出来（去掉 key 与账户标识）
