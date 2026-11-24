# 仓库元数据（用于 GitHub 仓库设置；本文件不参与构建）

## 仓库名

推荐：`QuotaBar`

理由：现在叫 `api_usage_show_widget`，名字问题有三个：
1. **把实现方式写进了名字**："widget" 让人以为只有小组件，实际还有菜单栏和 CLI；将来换 UI 也不该改名。
2. **下划线分词差**：GitHub 搜索和 URL 里 `api_usage_show_widget` 的 `show` 是噪音词，不贡献任何检索价值。
3. **不可发音、不可记忆**：没有短名字，别人没法口头推荐，也很难出现在 README 徽章、Homebrew tap、issue 模板里。

`QuotaBar` 的优势：一个词交代了"额度"（quota）+ "菜单栏"（bar），短、可发音、搜索唯一（`quota` 是该项目的核心词），且不绑定平台或实现。

备选（按偏好排序）：

| 名称 | 评价 |
|---|---|
| `QuotaBar` | 推荐。短、点题、唯一 |
| `QuotaDock` | 也不错，但 Dock 在 macOS 语境下特指程序坞，容易误解 |
| `QuotaWatch` | 表达"监视"到位，但 `watch` 一词已被大量工具占用 |
| `cc-switch-quota` | 明确绑定 cc-switch 生态，利于检索，但把项目价值说得比实际窄 |

**改名时机建议**：如果你的目标是先让少数人用起来、不想折腾，可以不改名（GitHub 会为旧名保留 301 重定向，改名也不会丢 star）。但只要想被检索到、被推荐，越早改越好——一旦有人在 README、博客、issue 里引用旧名，迁移成本就从"改个设置"变成"到处发更正"。我建议现在改，因为仓库还是私有、star 数为 0。

## 仓库描述（GitHub About 字段，上限 350 字符）

中文（推荐，你的目标受众主要是中文圈）：

```
一眼看清你所有 AI 编程订阅还剩多少：macOS 菜单栏 + 桌面小组件 + Windows CLI，支持火山方舟 / 智谱 GLM / DeepSeek / OpenCode Go / CommandCode，凭据自动复用 cc-switch，零第三方依赖
```

English（如果你想要英文为主，用这条）：

```
Menu bar + desktop widgets + CLI to watch quota across Volcengine Ark, Zhipu GLM, DeepSeek, OpenCode Go and CommandCode. Auto-discovers keys from cc-switch. Zero third-party dependencies.
```

英文简短版（若 About 一栏想更紧凑）：

```
See what's left on all your AI coding subscriptions — macOS menu bar, widgets and a CLI. Reads keys from cc-switch.
```

## Topics 标签（GitHub 上限 20 个，小写、连字符）

建议这 14 个（按检索价值排序）：

```
macos
swift
swiftui
widgetkit
menu-bar
macos-app
llm
ai-coding
quota
usage-tracker
openai
deepseek
glm
claude-code
```

补充可选（凑满 20 个时用；注意别加无检索量的自造词）：

```
cc-switch
opencode
developer-tools
cost-monitoring
crypto-kit
```

**不建议加的标签**：`api`（搜索结果太泛，几百个仓库）、`tool`、`productivity`、`utilities`（这三类是纯噪音，不带来任何定向检索）、中文标签（GitHub topics 实际以英文检索为主）。

## 其他建议填写的字段

- **Website**：暂时留空，或指向你自己的博客；不要填一个不存在的产品页
- **Releases**：开源后打一个 `v1.0.0`，附带可下载的 `.app`（注意 .app 需要你自己的签名，别人下载后可能被 Gatekeeper 拦，建议在 release notes 里说明"自行构建更省事"）
- **Social preview image**：用 `icons/A-深空仪表盘.png` 或截一张真实的菜单栏 + 窗口图，1280×640

## 开源前必须做的（我已核对当前仓库状态）

| 检查项 | 状态 |
|---|---|
| 全历史密钥泄漏 | ✅ 10 个提交零命中（sk- / user_ / AKLT / webhook key / 私钥） |
| 证书、私钥、.env 入库 | ✅ 无 `.p12` `.pem` `.cer` `.key` `.mobileprovision`，无 `.env` |
| 个人标识 | ⚠️ Team ID `D35P9V7J8X` 出现在 pbxproj / 两个 entitlements / SnapshotCache / 旧 README。**这是苹果开发者 Team ID，不是密钥**，公开不构成安全风险（别人无法用它签名或访问你的账户），但会暴露"这是谁的仓库"。已在 README 里写明要替换成自己的。想更彻底可以改成占位符 `YOUR_TEAM_ID`，代价是 App 开箱不能直接编译 |
| 提交邮箱 | ⚠️ 所有提交是 `YZz-S <2174545302@qq.com>`，开源后会公开。若不希望 QQ 邮箱暴露，可在 GitHub 设置里开启 "Keep my email addresses private"，但**这只影响之后的提交**，已有历史需要 rewrite（`git filter-repo`）才生效 |
| 构建产物 | ✅ `build/` 已在 .gitignore（本地 1.0G 全在那里面），`.git` 仅 1.7M |
| LICENSE | ✅ 已添加 MIT |
| 第三方代码来源 | ✅ 字段口径参考了 cc-switch（MIT）与 PerfPanel（你自己的项目），无 GPL 传染风险；MIT 合适 |
| 接口合法性 | ✅ README 已加免责声明，明确部分接口非官方公开 API |
