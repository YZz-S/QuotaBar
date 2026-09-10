# API Usage 小组件（macOS WidgetKit）

一个原生 macOS 桌面/通知中心小组件，**自动复用你在 [cc-switch](https://github.com/farion1231/cc-switch) 中配置的用量查询方式**，展示三个套餐的实时用量：

| Provider | 指标 | 查询方式 |
|---|---|---|
| 火山方舟 Coding Plan | 5小时 / 7天 / 月 三窗口：使用率、剩余额度、下次重置时间 | OpenAPI V4 签名（AK/SK），`GetCodingPlanUsage` 失败回落 `GetAFPUsage` |
| 智谱 GLM Coding Plan | 5小时 / 7天 双窗口：剩余积分（API `remaining`）、已用/总量、下次重置时间 | `GET /api/monitor/usage/quota/limit`，`Authorization: <apiKey>`（无 Bearer），解析逻辑与 cc-switch 里的自定义 JS 一致（unit:3→5小时，unit:6→7天） |
| DeepSeek | 账户余额（CNY）+ 服务可用状态 | `GET /user/balance`，`Authorization: Bearer <key>` |

容器 App 另有「模型」页：方舟 / GLM Coding Plan 当前支持的模型、DeepSeek 三款模型的高峰/空闲价格表、OpenCode Go 全量模型价格与月上限（静态资料，`Shared/ModelCatalog.swift`，标注核对日期与官方链接）。

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

- **零配置**：凭据跟随 cc-switch；在 cc-switch 里改 key 后重新打开一次本 App 即同步给小组件。
- **小组件必须沙箱**：macOS 的插件注册（pkd）拒绝收录未沙箱的 appex，因此 widget 通过 App Group 与未沙箱的 App 交换数据。
- 尺寸：小号 = 使用率最高的窗口进度环 + 剩余/重置；中号 = 左栏火山三窗口，右栏智谱双窗口 + DeepSeek 余额；大号 = 三家全部窗口 + 支持模型摘要。每个分区点击跳对应控制台。

## 构建

```bash
# 终端自检（独立跑三个查询，验证凭据与解析，不依赖 Xcode 工程）
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
App/          ApiUsageShowApp(TabView), StatusView(用量), ModelsView(模型), ApiUsageShow.entitlements
Widget/       ApiUsageWidgetBundle/ApiUsageWidget/WidgetViews.swift, Info.plist, ApiUsageShowWidget.entitlements
Shared/       Models, ProvidersStore(cc-switch DB + App Group 导出), QueryService(三厂商),
              SnapshotCache(App Group 容器), ViewHelpers(共用窗口行视图), ModelCatalog(模型/价格静态资料)
scripts/      UsageCheck.swift                           # 终端独立自检脚本
```
