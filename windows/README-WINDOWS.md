# API Usage Show — Windows 版

与 macOS 小组件同源的命令行工具：查询 **火山方舟 Coding Plan / 智谱 GLM Coding Plan / DeepSeek / OpenCode Go / CommandCode** 五家额度，凭据自动复用 [cc-switch](https://github.com/farion1231/cc-switch) 的配置。仅需 Python 3.10+（纯标准库，零依赖）。

```
:: 查询一次
python windows\api_usage.py

:: 每 5 分钟自动刷新 + 越线发 Windows 通知（Ctrl+C 退出）
python windows\api_usage.py --watch 300

:: 输出 JSON（供脚本消费）
python windows\api_usage.py --json

:: 只看识别到了哪些凭据（脱敏）
python windows\api_usage.py --list
```

或直接双击 `usage.bat`（查完暂停，方便看结果；参数照常传，如 `usage.bat --watch 300`）。

## 凭据来源（与 macOS 版一致）

1. **cc-switch 数据库**（只读）：`~\.cc-switch\cc-switch.db`，按 `meta.usage_script` 识别
   - 火山：`usage_script.accessKeyId / secretAccessKey`（region 从 `ANTHROPIC_BASE_URL` 推导）
   - 智谱：`usage_script.apiKey / baseUrl`
   - DeepSeek：`env.ANTHROPIC_AUTH_TOKEN`（base_url 含 `api.deepseek.com`）
   - OpenCode Go：baseURL 含 `opencode.ai/zen/go`，Key 取 `api_key` → `key_env` → `options.apiKey`
     （`key_env` 只存变量名，真值从 `~\.hermes\.env` / `~\.env` 等 dotenv 文件解析）
   - CommandCode：`usage_script.codingPlanProvider == "command_code"`，Key 在 provider 的 `api_key`
   在 cc-switch 里改 key 后重跑即可，无需在本工具里再配一遍。
2. **手动覆盖**（优先级更高）：

```
python windows\api_usage.py --set-volc <AK> <SK> [--set-region cn-beijing]
python windows\api_usage.py --set-zhipu <apiKey> [--set-zhipu-base-url https://...]
python windows\api_usage.py --set-deepseek <apiKey>
python windows\api_usage.py --clear-manual zhipu   # 或 volc / deepseek / all
```

存于 `~\.api-usage-show\manual-credentials.json`；每次查询的快照写 `~\.api-usage-show\snapshot.json`（字段与 macOS 版 `ProviderUsage` Codable 一致）。

## 警戒

默认阈值：火山/智谱任一窗口使用率 ≥ 80%、DeepSeek 余额 ≤ ¥10 时，打印提醒并发 Windows toast 通知（`--no-toast` 关闭通知）。可用 `--alert` 自定义：

```
python windows\api_usage.py --watch 300 --alert volc=90,zhipu=85,deepseek=20
```

`--watch` 模式下只在"从低于阈值跨到高于阈值"时提醒一次，回落后再越线会重新提醒（与 macOS 版行为一致）。

## 其他

- `--no-db`：跳过 cc-switch，仅用手动 Key；`--timeout 秒`：单请求超时（默认 12）。
- 出网仅允许 https，且解析后阻断内网/环回/保留地址、不跟随重定向。
- 走系统代理（与浏览器一致）。若代理拦截了国内接口，可设 `NO_PROXY=open.bigmodel.cn,open.volcengineapi.com,api.deepseek.com` 后重跑。
- 查询/签名/解析逻辑逐行对齐 `Shared/QueryService.swift` 与 `Shared/ProvidersStore.swift`；火山 V4 签名用标准库 `hmac`/`hashlib` 实现（无 AWS4 前缀，scope `{date}/{region}/ark/request`）。
