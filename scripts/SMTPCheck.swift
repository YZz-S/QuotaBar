import Foundation

/// 用 App 真实的 SMTPSender 发一封测试邮件，验证 SMTP 配置可用。
/// 凭据从 ~/.hermes/.env 的 UPDATE_MAIL_* 读取，不出现在命令行参数里。
///
///   swiftc -O Shared/Models.swift Shared/SnapshotCache.swift App/PushChannels.swift \
///          scripts/SMTPCheck.swift -o build/smtpcheck && ./build/smtpcheck
@main
struct SMTPCheckCLI {
    static func env(_ key: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("\(key)=") else { continue }
            var value = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, let l = value.last,
               (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    static func main() async {
        guard let host = env("UPDATE_MAIL_SMTP_HOST"),
              let user = env("UPDATE_MAIL_USER"),
              let pass = env("UPDATE_MAIL_PASS") else {
            print("❌ 读不到 UPDATE_MAIL_SMTP_HOST / UPDATE_MAIL_USER / UPDATE_MAIL_PASS")
            exit(1)
        }
        let port = Int(env("UPDATE_MAIL_SMTP_PORT") ?? "465") ?? 465
        let from = env("UPDATE_MAIL_FROM") ?? user
        let to = env("UPDATE_MAIL_TO") ?? user

        var config = PushChannelsConfig()
        config.smtpEnabled = true
        config.smtpHost = host
        config.smtpPort = port
        config.smtpUsername = user
        config.smtpPassword = pass
        config.smtpFrom = from
        config.smtpTo = to

        print("SMTP: \(host):\(port)")
        print("发件: \(from) → 收件: \(config.recipientAddresses.joined(separator: ", "))")
        print("授权码长度: \(pass.count)（不显示内容）")
        print("发送中…")

        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            try await SMTPSender.send(
                subject: "QuotaBar SMTP 测试 \(stamp)",
                body: """
                QuotaBar 推送渠道自检。

                如果你收到这封邮件，说明 SMTP 配置可用。
                发送时间：\(stamp)
                服务器：\(host):\(port)
                """,
                config: config)
            print("✅ 发送成功（curl 退出码 0，服务器已接收）")
        } catch {
            if let e = error as? PushChannelError {
                print("❌ 发送失败：\(e.errorDescription ?? "未知错误")")
            } else {
                print("❌ 发送失败：\(error.localizedDescription)")
            }
            exit(1)
        }
    }
}
