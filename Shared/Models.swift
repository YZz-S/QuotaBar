import Foundation

/// 单个用量窗口（火山的多窗口 / 智谱的 5 小时与每周窗口共用）
struct QuotaWindow: Codable, Hashable, Identifiable {
    static let fiveHour = "5小时"
    static let weekly = "7天"
    static let monthly = "月"

    var name: String
    var percent: Double
    var used: Double? = nil
    var total: Double? = nil
    var unit: String? = nil
    var resetTime: Date? = nil
    /// 厂商直接返回的剩余值（智谱 limits[].remaining），优先于 total - used
    var remainingOverride: Double? = nil

    var id: String { name }

    /// 剩余额度：优先厂商 remaining，否则 total - used（火山仅给百分比时为 nil）
    var remaining: Double? {
        if let remainingOverride { return remainingOverride }
        guard let used, let total, total >= used else { return nil }
        return total - used
    }

    /// 展示排序：5小时 → 7天 → 月
    var displayOrder: Int {
        switch name {
        case Self.fiveHour: return 0
        case Self.weekly: return 1
        case Self.monthly: return 2
        default: return 3
        }
    }
}

enum ProviderKind: String, Codable, CaseIterable {
    case volcengine
    case zhipu
    case deepseek

    var displayName: String {
        switch self {
        case .volcengine: return "火山方舟"
        case .zhipu: return "智谱 GLM"
        case .deepseek: return "DeepSeek"
        }
    }

    var consoleURL: String {
        switch self {
        case .volcengine: return "https://console.volcengine.com/ark"
        case .zhipu: return "https://open.bigmodel.cn/finance"
        case .deepseek: return "https://platform.deepseek.com/top_up"
        }
    }
}

/// 一个 provider 的查询结果（成功或失败都可渲染）
struct ProviderUsage: Codable, Identifiable, Hashable {
    var kind: ProviderKind
    var ok: Bool
    var queryDate: Date = Date()
    /// 窗口型指标（火山 / 智谱），已按使用率降序，第一个是主窗口
    var windows: [QuotaWindow] = []
    var subtitle: String? = nil
    /// 余额型指标（DeepSeek）
    var balance: Double? = nil
    var currency: String? = nil
    var isAvailable: Bool? = nil
    var errorMessage: String? = nil

    var id: String { kind.rawValue }

    /// 展示顺序的窗口列表（数据层按使用率排序供主窗口选择，展示按窗口周期固定排序）
    var windowsInDisplayOrder: [QuotaWindow] {
        windows.sorted { $0.displayOrder < $1.displayOrder }
    }
}

/// 从 cc-switch 数据库识别出的查询凭据（不落日志；App 导出到 App Group 容器供沙箱化 widget 读取）
struct ProviderCredentials: Codable {
    var kind: ProviderKind
    var sourceName: String
    var accessKey: String? = nil
    var secretKey: String? = nil
    var region: String? = nil
    var apiKey: String? = nil
    var baseUrl: String? = nil
    var bearerToken: String? = nil

    var keyDescription: String {
        switch kind {
        case .volcengine: return "AK \(accessKey == nil ? "✗" : "✓") / SK \(secretKey == nil ? "✗" : "✓")"
        case .zhipu: return "apiKey \(apiKey == nil ? "✗" : "✓")"
        case .deepseek: return "token \(bearerToken == nil ? "✗" : "✓")"
        }
    }

    var isComplete: Bool {
        switch kind {
        case .volcengine: return accessKey != nil && secretKey != nil
        case .zhipu: return apiKey != nil
        case .deepseek: return bearerToken != nil
        }
    }
}

/// 宽容的 JSON 字段提取（各厂商响应字段存在别名/类型差异）
enum JSONUtil {
    static func string(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func double(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.doubleValue }
            if let number = dict[key] as? Double { return number }
            if let number = dict[key] as? Int { return Double(number) }
            if let text = dict[key] as? String, let number = Double(text) { return number }
        }
        return nil
    }

    static func int(_ dict: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.intValue }
            if let number = dict[key] as? Int { return number }
            if let text = dict[key] as? String, let number = Int(text) { return number }
        }
        return nil
    }

    static func bool(_ dict: [String: Any], _ key: String) -> Bool? {
        if let value = dict[key] as? Bool { return value }
        if let number = dict[key] as? NSNumber { return number.boolValue }
        if let text = dict[key] as? String {
            if text == "1" || text.lowercased() == "true" { return true }
            if text == "0" || text.lowercased() == "false" { return false }
        }
        return nil
    }

    /// 时间戳秒/毫秒自适应，或 ISO8601 字符串
    static func date(_ dict: [String: Any], _ keys: String...) -> Date? {
        let formatterNoFraction = ISO8601DateFormatter()
        let formatterFraction = ISO8601DateFormatter()
        formatterFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for key in keys {
            guard let raw = dict[key] else { continue }
            var seconds: Double?
            if let number = raw as? NSNumber {
                seconds = number.doubleValue
            } else if let text = raw as? String {
                if let parsed = Double(text) {
                    seconds = parsed
                } else if let parsed = formatterFraction.date(from: text) ?? formatterNoFraction.date(from: text) {
                    return parsed
                }
            }
            if let seconds, seconds > 0 {
                return seconds < 100_000_000_000
                    ? Date(timeIntervalSince1970: seconds)
                    : Date(timeIntervalSince1970: seconds / 1000)
            }
        }
        return nil
    }
}
