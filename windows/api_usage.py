#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""API Usage Show — Windows 版

与 macOS 小组件 (ApiUsageShow) 同源的用量查询工具：
  火山方舟 Coding Plan : OpenAPI V4 签名（AK/SK），GetCodingPlanUsage 失败回落 GetAFPUsage
  智谱 GLM Coding Plan : GET /api/monitor/usage/quota/limit，Authorization 裸 key
  DeepSeek             : GET /user/balance，Authorization: Bearer
  OpenCode Go          : GET opencode.ai/zen/go/v1/usage，Bearer sk- Key
  CommandCode          : 官方 CLI 的 /alpha 私有路由（whoami/credits/subscriptions/summary）

凭据自动从 cc-switch 数据库（~/.cc-switch/cc-switch.db，只读）识别，
可用 --set-volc/--set-zhipu/--set-deepseek 手动覆盖，存于 ~/.api-usage-show/。

仅用 Python 标准库。查询/签名/解析逻辑逐行对齐 Shared/QueryService.swift
与 Shared/ProvidersStore.swift。出网仅允许 https，且解析后阻断内网/环回/保留地址。
"""

import argparse
import concurrent.futures
import hashlib
import hmac
import ipaddress
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path.home() / ".api-usage-show"
MANUAL_FILE = STATE_DIR / "manual-credentials.json"
SNAPSHOT_FILE = STATE_DIR / "snapshot.json"
CC_SWITCH_DB = Path.home() / ".cc-switch" / "cc-switch.db"

KIND_ORDER = ["volcengine", "zhipu", "deepseek", "opencode-go", "commandcode"]
DISPLAY_NAME = {"volcengine": "火山方舟", "zhipu": "智谱 GLM", "deepseek": "DeepSeek",
                "opencode-go": "OpenCode Go", "commandcode": "CommandCode"}
DEFAULT_TIMEOUT = 12
USER_AGENT = "ApiUsageShow-Windows/1.0"

W_5H, W_7D, W_MONTH = "5小时", "7天", "月"

# ---------------------------------------------------------------------------
# 宽容的 JSON 字段提取（对应 Shared/Models.swift 的 JSONUtil）


def j_str(d, *keys):
    for k in keys:
        v = d.get(k)
        if isinstance(v, str) and v:
            return v
    return None


def j_num(d, *keys):
    for k in keys:
        v = d.get(k)
        if isinstance(v, bool):
            continue
        if isinstance(v, (int, float)):
            return float(v)
        if isinstance(v, str):
            try:
                return float(v)
            except ValueError:
                pass
    return None


def j_int(d, *keys):
    v = j_num(d, *keys)
    return int(v) if v is not None else None


def j_bool(d, key):
    v = d.get(key)
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    if isinstance(v, str):
        if v in ("1", "true", "True"):
            return True
        if v in ("0", "false", "False"):
            return False
    return None


def j_date(d, *keys):
    """时间戳秒/毫秒自适应，或 ISO8601 字符串 → 本地时区 datetime"""
    for k in keys:
        raw = d.get(k)
        if raw is None:
            continue
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            seconds = float(raw)
            if seconds > 0:
                if seconds >= 100_000_000_000:
                    seconds /= 1000.0
                return datetime.fromtimestamp(seconds).astimezone()
        if isinstance(raw, str):
            try:
                seconds = float(raw)
                if seconds > 0:
                    if seconds >= 100_000_000_000:
                        seconds /= 1000.0
                    return datetime.fromtimestamp(seconds).astimezone()
            except ValueError:
                pass
            try:
                return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone()
            except ValueError:
                continue
    return None


def round1(x):
    """Swift 的 (x*10).rounded()/10：四舍五入到 1 位小数（非银行家舍入）"""
    return int(x * 10 + 0.5) / 10 if x >= 0 else -int(-x * 10 + 0.5) / 10


# ---------------------------------------------------------------------------
# 数据模型（字段名与 Swift Codable 保持一致，快照文件可互换）


def quota_window(name, percent, used=None, total=None, unit=None,
                 reset_time=None, remaining_override=None):
    return {
        "name": name,
        "percent": percent,
        "used": used,
        "total": total,
        "unit": unit,
        "resetTime": reset_time.isoformat() if reset_time else None,
        "remainingOverride": remaining_override,
    }


def window_remaining(w):
    if w.get("remainingOverride") is not None:
        return w["remainingOverride"]
    used, total = w.get("used"), w.get("total")
    if used is not None and total is not None and total >= used:
        return total - used
    return None


def window_display_order(w):
    return {W_5H: 0, W_7D: 1, W_MONTH: 2}.get(w["name"], 3)


def usage(kind, ok, windows=None, subtitle=None, balance=None,
          currency=None, is_available=None, error=None, source=None):
    return {
        "kind": kind,
        "ok": ok,
        "queryDate": datetime.now(timezone.utc).isoformat(),
        "windows": windows or [],
        "subtitle": subtitle,
        "balance": balance,
        "currency": currency,
        "isAvailable": is_available,
        "errorMessage": error,
        "sourceName": source,
    }


# ---------------------------------------------------------------------------
# 凭据发现（对应 Shared/ProvidersStore.swift）


def load_credentials(no_db=False):
    merged = [] if no_db else load_from_database()
    for manual in load_manual():
        for i, c in enumerate(merged):
            if c["kind"] == manual["kind"]:
                merged[i] = manual
                break
        else:
            merged.append(manual)
    merged.sort(key=lambda c: KIND_ORDER.index(c["kind"])
                if c["kind"] in KIND_ORDER else 9)
    return merged


def load_from_database():
    if not CC_SWITCH_DB.exists():
        return []
    try:
        db = sqlite3.connect(f"file:{CC_SWITCH_DB}?mode=ro", uri=True)
    except sqlite3.Error:
        return []
    credentials = []
    try:
        rows = db.execute(
            "SELECT name, settings_config, meta FROM providers "
            "ORDER BY sort_index, created_at"
        ).fetchall()
        for name, settings_json, meta_json in rows:
            try:
                settings = json.loads(settings_json or "{}")
                meta = json.loads(meta_json or "{}")
            except json.JSONDecodeError:
                continue
            credential = _identify(name, settings, meta)
            if credential and all(c["kind"] != credential["kind"] for c in credentials):
                credentials.append(credential)
    except sqlite3.Error:
        pass
    finally:
        db.close()
    return credentials


def _identify(name, settings, meta):
    script = meta.get("usage_script") or {}
    if not isinstance(script, dict):
        script = {}
    enabled = j_bool(script, "enabled") or False
    env = settings.get("env") or {}
    if not isinstance(env, dict):
        env = {}
    base_url = env.get("ANTHROPIC_BASE_URL") or ""
    coding_plan_provider = script.get("codingPlanProvider")

    # 火山方舟：AK/SK 存在 usage_script 里（推理 key 无法查额度）
    if (enabled and coding_plan_provider == "volcengine"
            and j_str(script, "accessKeyId") and j_str(script, "secretAccessKey")):
        return {
            "kind": "volcengine", "sourceName": name,
            "accessKey": script.get("accessKeyId"),
            "secretKey": script.get("secretAccessKey"),
            "region": _region_from_base_url(base_url),
        }

    # 智谱：apiKey（id.secret 格式），baseUrl 来自自定义脚本或默认 CN 端点
    if enabled and coding_plan_provider == "zhipu" and j_str(script, "apiKey"):
        return {
            "kind": "zhipu", "sourceName": name,
            "apiKey": script.get("apiKey"),
            "baseUrl": script.get("baseUrl")
            or "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
        }

    # DeepSeek：余额模板，key 在写入 CLI 的 env 里
    if ("api.deepseek.com" in base_url
            and j_str(env, "ANTHROPIC_AUTH_TOKEN", "DEEPSEEK_API_KEY")
            and (enabled or script.get("templateType") == "balance")):
        return {
            "kind": "deepseek", "sourceName": name,
            "bearerToken": env.get("ANTHROPIC_AUTH_TOKEN") or env.get("DEEPSEEK_API_KEY"),
        }

    # OpenCode Go / Zen Go：baseURL 指向 opencode.ai/zen/go，key 是 sk-
    oc_base = " ".join([
        base_url,
        j_str(env, "OPENCODE_GO_BASE_URL", "OPENCODE_ZEN_BASE_URL") or "",
        j_str(settings, "base_url") or "",
        j_str(settings.get("options") or {}, "baseURL") or "",
    ])
    if "opencode.ai" in oc_base:
        key = _opencode_key(settings)
        if key:
            return {"kind": "opencode-go", "sourceName": name, "apiKey": key}

    # CommandCode：usage_script.codingPlanProvider == "command_code"，key 在 provider 自身
    if enabled and coding_plan_provider == "command_code":
        key = j_str(settings, "api_key", "apiKey")
        if key:
            return {"kind": "commandcode", "sourceName": name, "apiKey": key}
    return None


def _dotenv_lookup(name):
    """cc-switch 的 key_env 只存变量名，真值在 dotenv 文件里（对应 Swift 的 DotEnv）"""
    if os.environ.get(name):
        return os.environ[name]
    for rel in (".hermes/.env", ".env", ".config/api-usage-show/.env", ".cc-switch/.env"):
        path = Path.home() / rel
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            key, sep, value = line.partition("=")
            if not sep or key.strip() != name:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("\"", "'"):
                value = value[1:-1]
            if value:
                return value
    return None


def _opencode_key(settings):
    """直接写 provider → key_env → options.apiKey → 两个约定环境变量名"""
    direct = j_str(settings, "api_key", "apiKey")
    if direct:
        return direct
    key_env = j_str(settings, "key_env")
    if key_env:
        value = _dotenv_lookup(key_env)
        if value:
            return value
    raw = j_str(settings.get("options") or {}, "apiKey")
    if raw:
        if raw.startswith("{env:") and raw.endswith("}"):
            value = _dotenv_lookup(raw[5:-1])
            if value:
                return value
        else:
            return raw
    for name in ("OPENCODE_GO_API_KEY", "OPENCODE_ZEN_API_KEY"):
        value = _dotenv_lookup(name)
        if value:
            return value
    return None


def _region_from_base_url(base_url):
    m = re.search(r"ark\.([a-z0-9-]+)\.volces\.com", base_url)
    return m.group(1) if m else "cn-beijing"


def load_manual():
    return _read_creds(MANUAL_FILE)


def _read_creds(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (OSError, json.JSONDecodeError):
        return []


def save_manual(credentials):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if credentials:
        MANUAL_FILE.write_text(
            json.dumps(credentials, ensure_ascii=False, indent=2), encoding="utf-8")
    elif MANUAL_FILE.exists():
        MANUAL_FILE.unlink()


# ---------------------------------------------------------------------------
# HTTP（仅 https；解析后阻断内网/环回/链路本地/保留地址；不跟随重定向）


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)

_FIXED_HOSTS = {"open.volcengineapi.com", "api.deepseek.com", "open.bigmodel.cn",
                "opencode.ai", "api.commandcode.ai"}


def _validate_url(url):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ConnectionError(f"URL 被拒绝（仅允许 https）: {url}")
    host = parsed.hostname
    if host.lower() in _FIXED_HOSTS:
        return
    try:
        infos = socket.getaddrinfo(host, parsed.port or 443)
    except socket.gaierror as e:
        raise ConnectionError(f"域名解析失败: {host}") from e
    for info in infos:
        addr = ipaddress.ip_address(info[4][0])
        if (addr.is_private or addr.is_loopback or addr.is_link_local
                or addr.is_reserved or addr.is_multicast or addr.is_unspecified):
            raise ConnectionError(f"目标地址被拒绝（内网/保留地址）: {host}")


def http_json(method, url, headers, timeout, body=None):
    """返回 (status, dict|list|None)。非 2xx 也尽量解析 JSON。"""
    _validate_url(url)
    request = urllib.request.Request(url, data=body, method=method)
    for k, v in headers.items():
        request.add_header(k, v)
    request.add_header("User-Agent", USER_AGENT)
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            status = response.status
            raw = response.read()
    except urllib.error.HTTPError as e:
        status = e.code
        raw = e.read()
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", None) or e
        raise ConnectionError(f"网络错误: {reason}") from e
    try:
        return status, json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return status, None


# ---------------------------------------------------------------------------
# 火山方舟 Coding Plan（OpenAPI V4 签名，对应 QueryService.swift）


def _uri_encode(s):
    return urllib.parse.quote(s, safe="-._~")


def _hmac_sha256(key, message):
    return hmac.new(key, message, hashlib.sha256).digest()


def volc_signed_post(region, access_key, secret_key, action, timeout):
    """V4 签名：HMAC-SHA256（无 AWS4 前缀），scope {date}/{region}/ark/request，
    SignedHeaders 固定 host;x-date;x-content-sha256;content-type，空 body。"""
    host = "open.volcengineapi.com"
    content_type = "application/json; charset=utf-8"
    signed_headers = "host;x-date;x-content-sha256;content-type"

    pairs = sorted([("Action", action), ("Region", region), ("Version", "2024-01-01")])
    canonical_query = "&".join(f"{_uri_encode(k)}={_uri_encode(v)}" for k, v in pairs)

    x_date = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    short_date = x_date[:8]
    body_hash = hashlib.sha256(b"").hexdigest()

    canonical_headers = (f"host:{host}\nx-date:{x_date}\n"
                         f"x-content-sha256:{body_hash}\ncontent-type:{content_type}\n")
    canonical_request = (f"POST\n/\n{canonical_query}\n{canonical_headers}\n"
                         f"{signed_headers}\n{body_hash}")
    scope = f"{short_date}/{region}/ark/request"
    string_to_sign = (f"HMAC-SHA256\n{x_date}\n{scope}\n"
                      f"{hashlib.sha256(canonical_request.encode()).hexdigest()}")

    k_date = _hmac_sha256(secret_key.encode(), short_date.encode())
    k_region = _hmac_sha256(k_date, region.encode())
    k_service = _hmac_sha256(k_region, b"ark")
    k_signing = _hmac_sha256(k_service, b"request")
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()

    authorization = (f"HMAC-SHA256 Credential={access_key}/{scope}, "
                     f"SignedHeaders={signed_headers}, Signature={signature}")
    return http_json(
        "POST", f"https://{host}/?{canonical_query}",
        {"X-Date": x_date, "X-Content-Sha256": body_hash,
         "Content-Type": content_type, "Authorization": authorization},
        timeout, body=b"")


def volc_window_name(level):
    lowered = level.lower()
    if "month" in lowered or lowered in ("m", "30d"):
        return W_MONTH
    if "week" in lowered or lowered == "7d":
        return W_7D
    if "hour" in lowered or lowered == "5h" or "session" in lowered:
        return W_5H
    return level


def parse_volc_plan(payload):
    """解析 QuotaUsage[]（别名 Usages/Details），窗口/百分比/重置字段别名容错"""
    if isinstance(payload, dict):
        metadata = payload.get("ResponseMetadata")
        if isinstance(metadata, dict) and isinstance(metadata.get("Error"), dict):
            error = metadata["Error"]
            code = j_str(error, "Code") or "Error"
            message = j_str(error, "Message") or ""
            return [], f"{code}: {message}"
        result = payload.get("Result") if isinstance(payload.get("Result"), dict) else payload
        items = result.get("QuotaUsage") or result.get("Usages") or result.get("Details")
    else:
        items = None
    windows = []
    for item in items or []:
        if not isinstance(item, dict):
            continue
        level = j_str(item, "Level", "Type", "Period", "Label", "Window")
        if not level:
            continue
        percent = j_num(item, "Percent", "UsedPercent", "UsagePercent")
        used = j_num(item, "Used")
        total = j_num(item, "Total", "Quota")
        if percent is None and used is not None and total is not None and total > 0:
            percent = used / total * 100
        windows.append(quota_window(
            volc_window_name(level), round1(percent or 0), used=used, total=total,
            reset_time=j_date(item, "ResetTime", "ResetTimestamp")))
    windows.sort(key=lambda w: w["percent"], reverse=True)
    return windows, None


def fetch_volc(credential, timeout):
    access_key = credential.get("accessKey")
    secret_key = credential.get("secretKey")
    region = credential.get("region")
    if not (access_key and secret_key and region):
        return usage("volcengine", False, error="火山 AK/SK 未配置",
                     source=credential.get("sourceName"))
    windows, last_error = [], None
    # 先探 Coding Plan，再探 Agent Plan（与 cc-switch 的双探策略一致）
    for action in ("GetCodingPlanUsage", "GetAFPUsage"):
        try:
            status, payload = volc_signed_post(
                region, access_key, secret_key, action, timeout)
            parsed, parse_error = parse_volc_plan(payload if isinstance(payload, dict) else {})
            if parsed:
                windows, last_error = parsed, None
                break
            last_error = parse_error or f"HTTP {status}"
        except (ConnectionError, ValueError) as e:
            last_error = str(e)
    if not windows:
        return usage("volcengine", False, error=last_error or "无额度数据",
                     source=credential.get("sourceName"))
    return usage("volcengine", True, windows=windows, subtitle="Coding Plan",
                 source=credential.get("sourceName"))


# ---------------------------------------------------------------------------
# 智谱 GLM Coding Plan


def fetch_zhipu(credential, timeout):
    api_key = credential.get("apiKey")
    if not api_key:
        return usage("zhipu", False, error="智谱 apiKey 未配置",
                     source=credential.get("sourceName"))
    url = credential.get("baseUrl") or "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
    try:
        status, payload = http_json("GET", url, {
            "Authorization": api_key,  # 智谱：裸 key，无 Bearer 前缀
            "Content-Type": "application/json",
            "Accept-Language": "en-US,en",
        }, timeout)
    except ConnectionError as e:
        return usage("zhipu", False, error=str(e), source=credential.get("sourceName"))
    if not isinstance(payload, dict):
        return usage("zhipu", False, error=f"智谱: 响应解析失败 (HTTP {status})",
                     source=credential.get("sourceName"))
    code = j_int(payload, "code")
    if code is not None and code != 200:
        message = j_str(payload, "msg", "message") or f"HTTP {status}"
        return usage("zhipu", False, error=f"智谱: {message}",
                     source=credential.get("sourceName"))
    data = payload.get("data") if isinstance(payload.get("data"), dict) else None
    limits = data.get("limits") if data else None
    if not limits:
        return usage("zhipu", False, error="智谱: 未获取到用量数据",
                     source=credential.get("sourceName"))

    level = j_str(data, "level") or ""
    five_hour = weekly = fallback = None
    # data.limits[]：unit:3 → 五小时窗口，unit:6 → 每周窗口，主值取每周（更稳定）
    for limit in limits:
        if not isinstance(limit, dict):
            continue
        limit_type = j_str(limit, "type") or ""
        unit = j_int(limit, "unit") or 0
        used = j_num(limit, "currentValue")
        total = j_num(limit, "usage")
        percent = j_num(limit, "percentage")
        if percent is None:
            percent = (used or 0) / max(total or 1, 1) * 100
        window = quota_window(
            W_5H if unit == 3 else W_7D, round1(percent), used=used, total=total,
            unit="积分", reset_time=j_date(limit, "nextResetTime", "resetTime"),
            remaining_override=j_num(limit, "remaining"))
        if limit_type == "CREDIT_LIMIT":
            if unit == 3:
                five_hour = window
            elif unit == 6:
                weekly = window
        elif fallback is None:
            fallback = window
    main = weekly or five_hour or fallback
    if main is None:
        return usage("zhipu", False, error="智谱: 无 CREDIT_LIMIT 数据",
                     source=credential.get("sourceName"))
    windows = [main]
    for extra in (five_hour, weekly):
        if extra and all(w["name"] != extra["name"] for w in windows):
            windows.append(extra)
    return usage("zhipu", True, windows=windows,
                 subtitle="Coding Plan" + (f" ({level})" if level else ""),
                 source=credential.get("sourceName"))


# ---------------------------------------------------------------------------
# DeepSeek 余额


def fetch_deepseek(credential, timeout):
    token = credential.get("bearerToken")
    if not token:
        return usage("deepseek", False, error="DeepSeek API key 未配置",
                     source=credential.get("sourceName"))
    try:
        status, payload = http_json("GET", "https://api.deepseek.com/user/balance",
                                    {"Authorization": f"Bearer {token}"}, timeout)
    except ConnectionError as e:
        return usage("deepseek", False, error=str(e), source=credential.get("sourceName"))
    if not isinstance(payload, dict):
        return usage("deepseek", False, error=f"DeepSeek: 响应解析失败 (HTTP {status})",
                     source=credential.get("sourceName"))
    if status != 200:
        error = payload.get("error")
        message = (j_str(error, "message") if isinstance(error, dict) else None) \
            or f"HTTP {status}"
        return usage("deepseek", False, error=f"DeepSeek: {message}",
                     source=credential.get("sourceName"))
    infos = payload.get("balance_infos")
    main = infos[0] if isinstance(infos, list) and infos and isinstance(infos[0], dict) else None
    if main is None:
        return usage("deepseek", False, error="DeepSeek: 无余额数据",
                     source=credential.get("sourceName"))
    return usage("deepseek", True, subtitle="余额",
                 balance=j_num(main, "total_balance") or 0,
                 currency=j_str(main, "currency") or "CNY",
                 is_available=j_bool(payload, "is_available"),
                 source=credential.get("sourceName"))


# ---------------------------------------------------------------------------
# OpenCode Go（sk- Key，官方 usage 端点）

OPENCODE_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"


def fetch_opencode(credential, timeout):
    """GET /zen/go/v1/usage → usage.{rolling,weekly,monthly}.{percent,resetsAt}
    percent 实测 0-100；防御式兼容 0-1 分数形态与 usedDollars/limitDollars"""
    key = credential.get("apiKey")
    if not key:
        return usage("opencode-go", False, error="OpenCode Go API Key 未配置",
                     source=credential.get("sourceName"))
    try:
        status, payload = http_json("GET", OPENCODE_USAGE_URL,
                                    {"Authorization": f"Bearer {key}",
                                     "Accept": "application/json"}, timeout)
    except ConnectionError as e:
        return usage("opencode-go", False, error=str(e), source=credential.get("sourceName"))
    if status in (401, 403):
        return usage("opencode-go", False,
                     error=f"OpenCode Go: 鉴权失败 (HTTP {status})，请检查 API Key（opencode.ai/console）",
                     source=credential.get("sourceName"))
    if not isinstance(payload, dict):
        return usage("opencode-go", False, error=f"OpenCode Go: 响应解析失败 (HTTP {status})",
                     source=credential.get("sourceName"))
    if status != 200:
        error = payload.get("error")
        message = (j_str(error, "message") if isinstance(error, dict) else None) or f"HTTP {status}"
        return usage("opencode-go", False, error=f"OpenCode Go: {message}",
                     source=credential.get("sourceName"))
    body = payload.get("usage")
    if not isinstance(body, dict):
        return usage("opencode-go", False, error="OpenCode Go: 响应中没有 usage 字段",
                     source=credential.get("sourceName"))

    found = [(label, body[k]) for k, label in (("rolling", W_5H), ("weekly", W_7D), ("monthly", W_MONTH))
             if isinstance(body.get(k), dict)]
    if not found:
        return usage("opencode-go", False,
                     error="OpenCode Go: 响应中没有 rolling/weekly/monthly 窗口",
                     source=credential.get("sourceName"))

    values = [j_num(node, "percent") or 0 for _, node in found]
    fraction = all(0 <= v <= 1 for v in values) and any(v > 0 for v in values)

    windows = []
    for label, node in found:
        percent = j_num(node, "percent", "usagePercent") or 0
        if fraction:
            percent *= 100
        used = j_num(node, "usedDollars", "usageDollars")
        limit = j_num(node, "limitDollars", "limit")
        windows.append(quota_window(
            label, max(0.0, min(100.0, percent)), used=used, total=limit,
            unit="USD" if limit is not None else None,
            reset_time=j_date(node, "resetsAt", "resetAt", "reset_at")))
    plan = j_str(payload, "plan") or j_str(body, "plan") or "Go"
    return usage("opencode-go", True, windows=windows, subtitle=plan,
                 source=credential.get("sourceName"))


# ---------------------------------------------------------------------------
# CommandCode（GOAT 等套餐，官方 CLI 的 /alpha 私有路由）

COMMANDCODE_BASE = "https://api.commandcode.ai"


def _cc_get(key, path, timeout):
    status, payload = http_json("GET", COMMANDCODE_BASE + path,
                               {"Authorization": f"Bearer {key}",
                                "Accept": "application/json"}, timeout)
    if status in (401, 403):
        raise ConnectionError(f"CommandCode: 鉴权失败 (HTTP {status})，"
                              f"请检查 API Key（commandcode.ai › Studio › API Keys）")
    if not isinstance(payload, dict):
        raise ConnectionError(f"CommandCode: 响应解析失败 (HTTP {status}) {path}")
    if status != 200:
        raise ConnectionError(f"CommandCode: HTTP {status} {path.split('?')[0]}")
    if payload.get("success") is False:
        error = payload.get("error")
        message = (j_str(error, "message", "code") if isinstance(error, dict) else None) or "未知错误"
        raise ConnectionError(f"CommandCode: {message}")
    return payload


def _cc_org_id(who):
    for path in (("org",), ("data", "org")):
        node = who
        for step in path:
            node = node.get(step) if isinstance(node, dict) else None
        if isinstance(node, dict):
            value = j_str(node, "id")
            if value:
                return value
    return ""


def _cc_query(org_id, *pairs):
    parts = []
    if org_id:
        parts.append("orgId=" + urllib.parse.quote(org_id, safe=""))
    parts.extend(p for p in pairs if p)
    return ("?" + "&".join(parts)) if parts else ""


def _cc_plan_label(plan_id):
    return {
        "": "", "go": "Go", "individual-goat": "GOAT", "goat": "GOAT", "pro": "Pro",
        "max10": "Max 10x", "max_10x": "Max 10x", "max-10x": "Max 10x",
        "max20": "Max 20x", "max_20x": "Max 20x", "max-20x": "Max 20x",
        "provider": "Provider",
    }.get((plan_id or "").lower(), plan_id)


def fetch_commandcode(credential, timeout):
    """四个 /alpha 路由：whoami → credits + subscriptions → usage/summary。
    5小时/周 = used/cap；月 = spent ÷(spent + 剩余池) —— credits 返回的是剩余，
    直接 spent/remaining 会在周期后段严重高估。"""
    key = credential.get("apiKey")
    if not key:
        return usage("commandcode", False, error="CommandCode API Key 未配置",
                     source=credential.get("sourceName"))
    try:
        who = _cc_get(key, "/alpha/whoami?limits=1", timeout)
        org_id = _cc_org_id(who)
        credits = _cc_get(key, "/alpha/billing/credits" + _cc_query(org_id), timeout)
        subs = _cc_get(key, "/alpha/billing/subscriptions" + _cc_query(org_id), timeout)

        period_start, plan_id, period_end = "", "", None
        data = subs.get("data")
        if isinstance(data, dict):
            period_start = j_str(data, "currentPeriodStart") or ""
            period_end = j_date(data, "currentPeriodEnd")
            plan_id = j_str(data, "planId") or ""

        since = ("since=" + urllib.parse.quote(period_start, safe="")) if period_start else ""
        summary = _cc_get(key, "/alpha/usage/summary" + _cc_query(org_id, since), timeout)
    except ConnectionError as e:
        return usage("commandcode", False, error=str(e), source=credential.get("sourceName"))

    spent = j_num(summary, "totalCost")
    if spent is None:
        return usage("commandcode", False,
                     error="CommandCode: usage/summary 缺少 totalCost 字段（接口口径可能有变）",
                     source=credential.get("sourceName"))

    pool_node = credits.get("credits") if isinstance(credits.get("credits"), dict) else credits
    pool = 0.0
    for field in ("monthlyCredits", "purchasedCredits", "freeCredits"):
        pool += max(0.0, j_num(pool_node, field) or 0.0)

    limits = credits.get("windowLimits")
    if not isinstance(limits, dict):
        limits = pool_node.get("windowLimits") if isinstance(pool_node, dict) else None
    limits = limits if isinstance(limits, dict) else {}
    payg_only = limits.get("limited") is False

    windows = []
    if not payg_only:
        for field, label in (("fiveHour", W_5H), ("weekly", W_7D)):
            node = limits.get(field)
            if not isinstance(node, dict):
                continue
            cap = j_num(node, "cap") or 0
            if cap <= 0:
                continue
            used = j_num(node, "used") or 0
            windows.append(quota_window(
                label, max(0.0, min(100.0, used / cap * 100)),
                used=used, total=cap, unit="USD",
                reset_time=j_date(node, "resetAt")))
    if pool > 0:
        allotment = spent + pool
        windows.append(quota_window(
            W_MONTH, max(0.0, min(100.0, spent / allotment * 100)),
            used=spent, total=allotment, unit="USD",
            reset_time=period_end, remaining_override=pool))

    if not windows:
        return usage("commandcode", False,
                     error="CommandCode: credits 池为 0 且无滚动窗口（套餐可能未生效）",
                     source=credential.get("sourceName"))
    return usage("commandcode", True, windows=windows,
                 subtitle=_cc_plan_label(plan_id),
                 balance=pool if pool > 0 else None,
                 currency="USD" if pool > 0 else None,
                 source=credential.get("sourceName"))


FETCHERS = {"volcengine": fetch_volc, "zhipu": fetch_zhipu,
            "deepseek": fetch_deepseek, "opencode-go": fetch_opencode,
            "commandcode": fetch_commandcode}


def fetch_all(credentials, timeout=DEFAULT_TIMEOUT):
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(credentials) or 1) as pool:
        return list(pool.map(lambda c: FETCHERS[c["kind"]](c, timeout), credentials))


# ---------------------------------------------------------------------------
# 快照


def save_snapshot(results):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        SNAPSHOT_FILE.write_text(
            json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# 警戒（对应 App 设置页的阈值通知；toast 走 PowerShell WinRT，无需装模块）

DEFAULT_ALERTS = {"volc": 80.0, "zhipu": 80.0, "deepseek": 10.0,
                  "opencode": 80.0, "commandcode": 80.0}


def parse_alert_spec(spec):
    thresholds = dict(DEFAULT_ALERTS)
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        key, _, value = part.partition("=")
        key = key.strip().lower()
        if key not in thresholds:
            raise SystemExit(f"未知警戒项: {key}（可选 volc/zhipu/deepseek/opencode/commandcode）")
        try:
            thresholds[key] = float(value)
        except ValueError:
            raise SystemExit(f"警戒阈值无效: {part}")
    return thresholds


THRESHOLD_KEY = {"volcengine": "volc", "zhipu": "zhipu",
                 "opencode-go": "opencode", "commandcode": "commandcode"}


def check_alerts(results, thresholds):
    alerts = []
    for result in results:
        kind = result["kind"]
        if kind == "deepseek":
            limit = thresholds["deepseek"]
            balance = result.get("balance")
            if result["ok"] and balance is not None and balance <= limit:
                alerts.append((kind, f"DeepSeek 余额 ¥{balance:g} ≤ ¥{limit:g}"))
        else:
            key = THRESHOLD_KEY.get(kind)
            if key is None:
                continue
            limit = thresholds[key]
            for w in result.get("windows", []):
                if w["percent"] >= limit:
                    alerts.append((kind, f"{DISPLAY_NAME[kind]} {w['name']}窗口 "
                                          f"使用率 {fmt_pct(w['percent'])}% ≥ {fmt_pct(limit)}%"))
    return alerts


def toast(title, body):
    if os.name != "nt":
        return
    try:
        script = (
            "[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications,"
            " ContentType=Windows] | Out-Null;"
            "$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent("
            "[Windows.UI.Notifications.ToastTemplateType]::ToastText02);"
            "$x=$t.GetElementsByTagName('text');"
            "[void]$x.Item(0).AppendChild($t.CreateTextNode('" + title.replace("'", "''") + "'));"
            "[void]$x.Item(1).AppendChild($t.CreateTextNode('" + body.replace("'", "''") + "'));"
            "[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("
            "'{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe')"
            ".Show([Windows.UI.Notifications.ToastNotification]::new($t))"
        )
        subprocess.run(["powershell", "-NoProfile", "-Command", script],
                       capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        pass


# ---------------------------------------------------------------------------
# 渲染


class Style:
    def __init__(self, enabled):
        self.enabled = enabled

    def _c(self, code, text):
        return f"\033[{code}m{text}\033[0m" if self.enabled else text

    def green(self, t): return self._c("32", t)
    def yellow(self, t): return self._c("33", t)
    def red(self, t): return self._c("31", t)
    def dim(self, t): return self._c("90", t)
    def bold(self, t): return self._c("1", t)


def fmt_pct(p):
    return ("%.1f" % p).rstrip("0").rstrip(".")


def fmt_num(v):
    if v is None:
        return "--"
    if abs(v) >= 1e6:
        return f"{v/1e6:.2f}M"
    if v % 1:
        return ("%.2f" % v).rstrip("0").rstrip(".")
    return f"{int(v):,}"


def display_width(s):
    return sum(2 if ord(c) > 0x2E80 else 1 for c in s)


def pad(s, width):
    return s + " " * max(0, width - display_width(s))


def level_color(style, percent):
    return style.red if percent >= 85 else style.yellow if percent >= 60 else style.green


def render_bar(style, percent, width=18):
    filled = max(0, min(width, round(percent / 100 * width)))
    bar = "█" * filled + "░" * (width - filled)
    return level_color(style, percent)(bar)


def render(results, style, credentials, thresholds):
    lines = []
    header_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines.append(style.bold(f"== API Usage ({header_time}) =="))
    lines.append(style.dim(
        f"凭据: cc-switch 数据库{' + 手动覆盖' if any(c['sourceName'] == '手动配置' for c in credentials) else ''}"
        f" · 警戒: 火山≥{fmt_pct(thresholds['volc'])}% 智谱≥{fmt_pct(thresholds['zhipu'])}%"
        f" OC≥{fmt_pct(thresholds['opencode'])}% CC≥{fmt_pct(thresholds['commandcode'])}%"
        f" 余额≤¥{fmt_pct(thresholds['deepseek'])}"))
    lines.append("")

    for result in results:
        kind = result["kind"]
        name = DISPLAY_NAME.get(kind, kind)
        source = style.dim(f"  [{result.get('sourceName') or '-'}]")
        if not result["ok"]:
            lines.append(style.red(f"❌ {name}: {result.get('errorMessage') or '查询失败'}") + source)
            lines.append("")
            continue
        subtitle = result.get("subtitle") or ""
        lines.append(style.bold(f"● {name} · {subtitle}") + source)
        if kind == "deepseek":
            balance = result.get("balance") or 0
            currency = result.get("currency") or "CNY"
            symbol = "¥" if currency.upper() == "CNY" else ""
            color = style.red if balance <= thresholds["deepseek"] else style.green
            state = result.get("isAvailable")
            state_text = "" if state is None else ("  状态: 可用" if state else "  状态: 不可用")
            lines.append(f"  余额 {color(f'{symbol}{balance:g} {currency}')}{state_text}")
        else:
            if result.get("balance") is not None:
                currency = (result.get("currency") or "USD").upper()
                symbol = {"CNY": "¥", "USD": "$"}.get(currency, currency + " ")
                lines.append(f"  余额 {symbol}{result['balance']:.2f}")
            for w in sorted(result.get("windows", []), key=window_display_order):
                color = level_color(style, w["percent"])
                reset_text = ""
                if w["resetTime"]:
                    try:
                        reset = datetime.fromisoformat(w["resetTime"])
                        reset_text = f"  重置 {reset.strftime('%m-%d %H:%M')}"
                    except ValueError:
                        pass
                lines.append(f"  {pad(w['name'], 6)}{render_bar(style, w['percent'])}"
                             f"  {color(fmt_pct(w['percent']) + '%')}{reset_text}")
                detail = []
                remaining = window_remaining(w)
                if remaining is not None:
                    unit = w.get("unit") or ""
                    detail.append(f"剩余 {fmt_num(remaining)}{unit}")
                if w.get("used") is not None and w.get("total") is not None:
                    detail.append(f"已用 {fmt_num(w['used'])}/{fmt_num(w['total'])}")
                if detail:
                    lines.append("       " + style.dim(" · ".join(detail)))
        lines.append("")
    return "\n".join(lines)


def masked(secret):
    if not secret:
        return "✗"
    if len(secret) <= 10:
        return "✓"
    return f"{secret[:6]}…{secret[-4:]} ({len(secret)}字符)"


def credential_brief(c):
    kind = c["kind"]
    if kind == "volcengine":
        return f"AK {masked(c.get('accessKey'))} / SK {masked(c.get('secretKey'))} · {c.get('region')}"
    if kind == "zhipu":
        return f"apiKey {masked(c.get('apiKey'))}"
    if kind in ("opencode-go", "commandcode"):
        return f"apiKey {masked(c.get('apiKey'))}"
    return f"token {masked(c.get('bearerToken'))}"


# ---------------------------------------------------------------------------
# CLI


def run_once(args, style, thresholds, prev_over=None):
    credentials = load_credentials(no_db=args.no_db)
    if not credentials:
        print("❌ 未识别到任何凭据：cc-switch 数据库无匹配，也未配置手动 Key")
        print("   手动配置示例: api_usage.py --set-zhipu <apiKey>")
        return 2
    results = fetch_all(credentials, timeout=args.timeout)
    save_snapshot(results)

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        failed = sum(1 for r in results if not r["ok"])
        return 2 if failed else 0

    print(render(results, style, credentials, thresholds))

    alerts = check_alerts(results, thresholds)
    over_kinds = {kind for kind, _ in alerts}
    fired = []
    for kind, message in alerts:
        if prev_over is None or not prev_over.get(kind):
            fired.append(message)
        if prev_over is not None:
            prev_over[kind] = kind in over_kinds
    if prev_over is not None:  # watch 模式：回落时清除记忆，下次再越线会重新提醒
        for kind in list(prev_over):
            if kind not in over_kinds:
                prev_over[kind] = False
    if fired:
        print(style.red("⚠ 警戒:"))
        for message in fired:
            print(style.red(f"  · {message}"))
        if args.toast:
            toast("API 用量警戒", "\n".join(fired))
    failed = sum(1 for r in results if not r["ok"])
    return 2 if failed else 0


def handle_set_commands(args):
    if not (args.set_volc or args.set_zhipu or args.set_deepseek or args.clear_manual):
        return False
    manual = [c for c in load_manual() if c["sourceName"] == "手动配置"]

    def replace(entry):
        for i, c in enumerate(manual):
            if c["kind"] == entry["kind"]:
                manual[i] = entry
                return
        manual.append(entry)

    if args.clear_manual:
        target = args.clear_manual
        aliases = {"volc": "volcengine", "zhipu": "zhipu", "deepseek": "deepseek"}
        if target == "all":
            manual = []
        else:
            kind = aliases.get(target)
            if not kind:
                raise SystemExit(f"未知项: {target}（可选 volc/zhipu/deepseek/all）")
            manual = [c for c in manual if c["kind"] != kind]
    if args.set_volc:
        ak, sk = args.set_volc
        replace({"kind": "volcengine", "sourceName": "手动配置",
                 "accessKey": ak, "secretKey": sk,
                 "region": args.set_region or "cn-beijing"})
    if args.set_zhipu:
        replace({"kind": "zhipu", "sourceName": "手动配置",
                 "apiKey": args.set_zhipu,
                 "baseUrl": args.set_zhipu_base_url
                 or "https://open.bigmodel.cn/api/monitor/usage/quota/limit"})
    if args.set_deepseek:
        replace({"kind": "deepseek", "sourceName": "手动配置",
                 "bearerToken": args.set_deepseek})
    save_manual(manual)

    if manual:
        print(f"手动凭据已保存 → {MANUAL_FILE}")
        for c in manual:
            print(f"  {DISPLAY_NAME[c['kind']]}: {credential_brief(c)}")
    else:
        print("手动凭据已清空")
    return bool(args.set_volc or args.set_zhipu or args.set_deepseek or args.clear_manual)


def main():
    parser = argparse.ArgumentParser(
        description="API Usage Show（Windows 版）：火山方舟 / 智谱 GLM / DeepSeek / OpenCode Go / CommandCode 用量查询",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  api_usage.py                 查询一次并打印\n"
               "  api_usage.py --watch 300     每 5 分钟自动刷新（含警戒 toast）\n"
               "  api_usage.py --json          输出 JSON（快照也存 ~/.api-usage-show/snapshot.json）\n"
               "  api_usage.py --set-zhipu <key>   手动配置智谱 Key（覆盖 cc-switch 识别）\n"
               "  api_usage.py --alert volc=90,zhipu=85,deepseek=20   自定义警戒阈值")
    parser.add_argument("--json", action="store_true", help="输出 JSON 而非表格")
    parser.add_argument("--watch", nargs="?", const=300, type=int, metavar="秒",
                        help="循环刷新（默认 300 秒；Ctrl+C 退出）")
    parser.add_argument("--list", action="store_true", help="只列出识别到的凭据（脱敏）")
    parser.add_argument("--no-db", action="store_true", help="跳过 cc-switch 数据库，仅用手动 Key")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, metavar="秒",
                        help="单请求超时（默认 12）")
    parser.add_argument("--alert", default=None, metavar="规格",
                        help="警戒阈值，如 volc=80,zhipu=80,deepseek=10,opencode=80,commandcode=80")
    parser.add_argument("--no-toast", dest="toast", action="store_false",
                        help="越线时只打印，不发 Windows 通知")
    parser.add_argument("--no-color", dest="color", action="store_false",
                        help="禁用 ANSI 颜色")
    parser.add_argument("--set-volc", nargs=2, metavar=("AK", "SK"), help="手动配置火山凭据")
    parser.add_argument("--set-zhipu", metavar="KEY", help="手动配置智谱 apiKey")
    parser.add_argument("--set-zhipu-base-url", metavar="URL", help="智谱查询端点（默认 CN）")
    parser.add_argument("--set-deepseek", metavar="KEY", help="手动配置 DeepSeek API key")
    parser.add_argument("--set-region", metavar="REGION", help="火山 region（默认 cn-beijing）")
    parser.add_argument("--clear-manual", metavar="项", help="清除手动凭据: volc/zhipu/deepseek/all")
    args = parser.parse_args()

    thresholds = parse_alert_spec(args.alert) if args.alert else dict(DEFAULT_ALERTS)
    # pythonw 常驻（无控制台）时 sys.stdout 为 None，print 可用但 isatty 需保护
    style = Style(args.color and sys.stdout is not None and sys.stdout.isatty())
    if os.name == "nt":
        try:
            os.system("")  # 请求 conhost 启用 ANSI/VT 处理
        except OSError:
            pass

    if handle_set_commands(args):
        return 0

    if args.list:
        credentials = load_credentials(no_db=args.no_db)
        if not credentials:
            print("未识别到凭据")
            return 1
        print(f"cc-switch 数据库: {CC_SWITCH_DB}" + style.dim("（只读）"))
        for c in credentials:
            print(f"  {DISPLAY_NAME[c['kind']]}  ← {c['sourceName']}: {credential_brief(c)}")
        return 0

    if args.watch is not None:
        if args.watch < 10:
            raise SystemExit("--watch 间隔过短（最小 10 秒）")
        prev_over = {}
        try:
            while True:
                print("\033[2J\033[H", end="")
                run_once(args, style, thresholds, prev_over)
                time.sleep(args.watch)
        except KeyboardInterrupt:
            print("\n已停止")
        return 0

    return run_once(args, style, thresholds)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
