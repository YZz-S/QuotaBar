# API Usage 小组件（macOS WidgetKit）

一个原生 macOS 桌面/通知中心小组件，**自动复用你在 [cc-switch](https://github.com/farion1231/cc-switch) 中配置的用量查询方式**，展示三个套餐的实时用量：

| Provider | 指标 | 查询方式 |
|---|---|---|
| 火山方舟 Coding Plan | 5小时 / 7天 / 月 三窗口：使用率、剩余额度、下次重置时间 | OpenAPI V4 签名（AK/SK），`GetCodingPlanUsage` 失败回落 `GetAFPUsage` |
| 智谱 GLM Coding Plan | 5小时 / 7天 双窗口：剩余积分（API `remaining`）、已用/总量、下次重置时间 | `GET /api/monitor/usage/quota/limit`，`Authorization: <apiKey>`（无 Bearer），解析逻辑与 cc-switch 里的自定义 JS 一致（unit:3→5小时，unit:6→7天） |
| DeepSeek | 账户余额（CNY）+ 服务可用状态 | `GET /user/balance`，`Authorization: Bearer <key>` |
| OpenCode Go | 5小时 / 7天 / 月 三窗口使用率与重置时间 | `GET https://opencode.ai/zen/go/v1/usage`，`Authorization: Bearer sk-…` |
| CommandCode（GOAT / Pro / Max…） | 5小时 / 周 / 月 使用率 + credits 余额（USD） | 官方 CLI 的 `/alpha` 私有路由：`whoami` → `billing/credits` + `billing/subscriptions` → `usage/summary` |

> **CommandCode 的月度口径**：`billing/credits` 返回的是**剩余**池，不是总额。所以月度使用率按 `已花 ÷(已花 + 剩余)` 计算（实测 GOAT 周期内 30.90 已花 + 39.35 剩余 = 70.25 总额）。若直接把剩余当总额，百分比会在周期后段严重高估。

容器 App 另有「模型」页：方舟 / GLM Coding Plan 当前支持的模型、DeepSeek 三款模型的高峰/空闲价格表、OpenCode Go 全量模型价格与月上限、CommandCode 套餐模型清单（静态资料，`Shared/ModelCatalog.swift`，标注核对日期与官方链接）。

## 只显示指定供应商

「用量」页每个供应商前有复选框，设置页「菜单栏与显示范围」区块也能改（两处同步，写入 App Group 容器的 `display.json`）：

- 勾选结果同时作用于「用量」页卡片、三个尺寸的小组件、警戒通知与菜单栏
- 默认**未勾选就不查询**（连请求都不发），避免把没订阅的渠道刷成红色失败；需要留数据但不想展示时，打开「未勾选的供应商也照常查询」
- 全部取消勾选等价于「全部显示」，不会出现空态

## 菜单栏（状态栏）显示

应用常驻菜单栏：图标 + 用量数值，按数值上色（<50% 绿 / ≥50% 橙 / ≥80% 红）。点开菜单可以：

- 看每家明细（所有窗口 + 余额 + 重置倒计时），点击直达对应控制台
- 切换「显示哪些供应商」「菜单栏显示哪些窗口」（5小时 / 7天 / 月 任选）
- 切换排布：**每家单独一个菜单栏项**（默认，DeepSeek 余额和各家百分比可同时看到）或合并为一项（自动取使用率最高的）
- 钉住某一家固定显示、立即刷新、打开主窗口、退出

关掉主窗口应用不退出，菜单栏继续常驻。查询失败的供应商不会在菜单栏占一个「查询失败」气泡，只留在菜单里。


## 工作原理

```
容器 App（未沙箱）
  ├─ 读 ~/.cc-switch/cc-switch.db（只读 SQLite）→ 按 meta.usage_script 识别凭据
  │    · volcengine: usage_script.accessKeyId/secretAccessKey，region 从 ANTHROPIC_BASE_URL 推导
  │    · zhipu:      usage_script.apiKey / baseUrl
  │    · deepseek:   settings_config.env.ANTHROPIC_AUTH_TOKEN（base_url 含 api.deepseek.com）
  └─ 导出到 App Group 容器 credentials.json（0600）并触发小组件刷新

小组件扩展（沙箱 + network.client + App Group，~15 分钟系统预算刷新一次）
  ├─ 读 App Group 容器里的 credentials.json
  ├─ 并发查询三个接口（CryptoKit 做 V4 签名）
  ├─ 写缓存 snapshot.json（同一容器，App 启动时也读它）
  └─ 渲染；网络失败时显示缓存值并标注
```

App Group 容器路径：`~/Library/Group Containers/D35P9V7J8X.group.ApiUsageShow/Library/Application Support/ApiUsageShow/`。

- **零配置**：凭据跟随 cc-switch；在 cc-switch 里改 key 后重新打开一次本 App 即同步给小组件。也可在 App「设置」页**手动填写 API Key**（覆盖自动识别，写入同一容器）。
- **小组件必须沙箱**：macOS 的插件注册（pkd）拒绝收录未沙箱的 appex，因此 widget 通过 App Group 与未沙箱的 App 交换数据。
- 尺寸：小号 = 使用率最高的窗口进度环 + 剩余/重置；中号 = 左栏火山三窗口，右栏智谱双窗口 + DeepSeek 余额；大号 = 三家全部窗口 + 支持模型摘要。每个分区点击跳对应控制台。
- **手动刷新**：三种尺寸都有 ↻ 按钮（交互式小组件，`RefreshUsageIntent`）。按钮查询后写快照，系统自动重载时间线；`getTimeline` 发现快照在 2 分钟内就直接复用，不重复请求。
- **警戒通知**（App「设置」页）：火山 / 智谱 / OpenCode Go / CommandCode 任一窗口使用率 ≥ 阈值、DeepSeek 余额 ≤ 阈值时发本地通知；由 App 负责检查（启动后 5 秒一次，之后按 5/15/30/60 分钟轮询），小组件扩展本身无法发通知。勾选「登录时自动启动」可让检查常驻。每个窗口只在从低于阈值跨到高于阈值时提醒一次。
- 应用图标由 `scripts/make_icons.swift` 用 CoreGraphics 生成（`swift scripts/make_icons.swift icons` 输出 4 个候选），选定后替换 `App/Assets.xcassets/AppIcon.appiconset/` 里的图片即可。

## 构建

```bash
# 终端自检（独立跑五个查询，验证凭据与解析，不依赖 Xcode 工程）
swiftc -O Shared/Models.swift Shared/ProvidersStore.swift Shared/QueryService.swift \
       Shared/SnapshotCache.swift scripts/UsageCheck.swift -o build/usagecheck && ./build/usagecheck

# 构建 App + Widget Extension（DEVELOPER_DIR 避免切 xcode-select）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ApiUsageShow.xcodeproj -target ApiUsageShow \
  -configuration Release SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build

# 安装并注册
cp -R build/Release/ApiUsageShow.app /Applications/
open /Applications/ApiUsageShow.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ApiUsageShow.app
```

添加小组件：桌面或通知中心右键 →「编辑」→ 搜索「API 用量」。

## ⚠️ 签名说明（重要）

macOS 26 上要让小组件出现在小组件库，必须同时满足两点（缺一都会"App 能装、小组件加不上"）：

1. **开发者证书签名**（ad-hoc `-` 不行）：Xcode → Settings → Accounts 登录 Apple ID（免费个人团队即可）→ Manage Certificates 生成 Apple Development 证书。工程里 `DEVELOPMENT_TEAM` 要填证书的**真实 Team ID**（`security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject` 里的 `OU=`），而不是证书名称括号里的账号标识——两者可能不同，填错会报 `No signing certificate "Mac Development" found`。
2. **widget 扩展必须开启 App Sandbox**：`Widget/ApiUsageShowWidget.entitlements` 声明 `app-sandbox` + `network.client` + `application-groups`；App 只带 `application-groups`（保持未沙箱以读取 cc-switch 数据库）。App Group ID 必须以 Team ID 为前缀。

换机器 / 换 Apple ID 时只需替换 `project.pbxproj` 里的 `DEVELOPMENT_TEAM`、两个 entitlements 与 `Shared/SnapshotCache.swift` 里 `AppGroup.identifier` 的 Team ID 前缀，再执行上面的构建与安装步骤。安装后可用 `pluginkit -m -v -i com.apiusage.show.widget` 确认扩展已被系统收录。

## 项目结构

```
ApiUsageShow.xcodeproj/project.pbxproj   # 手写工程：App + Widget Extension 两 target
App/          ApiUsageShowApp(TabView + AppDelegate), StatusView(用量 + 供应商勾选),
              ModelsView(模型), SettingsView(手动 Key + 菜单栏/显示范围 + 警戒通知),
              StatusBarController(菜单栏常驻项与菜单), QuotaAlertCenter(定时检查 + 本地通知),
              Assets.xcassets(AppIcon), ApiUsageShow.entitlements
Widget/       ApiUsageWidgetBundle / ApiUsageWidget(时间线 + RefreshUsageIntent) / WidgetViews.swift,
              Info.plist, ApiUsageShowWidget.entitlements
Shared/       Models(+DotEnv), ProvidersStore(cc-switch DB + 手动配置 + App Group 导出),
              QueryService(五厂商), SnapshotCache(App Group 容器),
              DisplayPreferences(显示哪些供应商/窗口的共用偏好),
              ViewHelpers(共用窗口行视图), ModelCatalog(模型/价格静态资料)
scripts/      UsageCheck.swift（终端独立自检）, make_icons.swift（图标生成）
icons/        四个应用图标候选 PNG
windows/      Windows 版命令行工具（Python 单文件，复用 cc-switch 凭据查同样接口）→ 见 windows/README-WINDOWS.md
```
