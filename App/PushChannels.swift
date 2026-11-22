import Foundation

/// 外部推送渠道配置（SMTP 邮件 + 企业微信群机器人）。
/// 与本地通知共用「警戒通知」总开关与阈值；凭据只存本机 App Group 容器（0600）。
struct PushChannelsConfig: Codable, Equatable {
    var smtpEnabled = false
    var smtpHost = ""
    var smtpPort = 465
    var smtpUsername = ""
    var smtpPassword = ""
    /// 发件人，留空 = 登录账号
    var smtpFrom = ""
    /// 收件人，逗号/分号/空白分隔，留空 = 登录账号
    var smtpTo = ""

    var wecomEnabled = false
    var wecomWebhook = ""
    var wecomMentionAll = false

    /// 发件地址：显式 from 优先，否则登录账号
    var effectiveFromAddress: String? {
        let from = smtpFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !from.isEmpty { return from }
        let user = smtpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? nil : user
    }

    var recipientAddresses: [String] {
        let raw = smtpTo.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = raw.isEmpty ? smtpUsername : raw
        return candidates
            .split(whereSeparator: { ",;，； \t\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("@") }
    }
}

/// 推送渠道配置的持久化（App Group 容器，仅本用户可读）
enum PushChannelsStore {
    static var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent("push-channels.json") }

    static func load() -> PushChannelsConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(PushChannelsConfig.self, from: data) else {
            return PushChannelsConfig()
        }
        return saved
    }

    static func save(_ config: PushChannelsConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

// MARK: - SMTP

enum PushChannelError: LocalizedError {
    case incomplete(String)
    case curl(Int, String)
    case badWebhookURL
    case wecomAPI(Int, String)

    var errorDescription: String? {
        switch self {
        case .incomplete(let what): return "配置不完整：\(what)"
        case .curl(let code, let detail):
            let reason: String
            switch code {
            case 6: reason = "无法解析 SMTP 服务器地址"
            case 7: reason = "无法连接服务器（检查地址/端口或网络）"
            case 28: reason = "连接超时"
            case 35: reason = "TLS 握手失败（检查端口：465=SSL，587=STARTTLS）"
            case 55: reason = "邮件被服务器拒收（发件人通常必须与登录账号一致）"
            case 67: reason = "登录失败（QQ/163 等邮箱需使用授权码而非登录密码）"
            default: reason = "发送失败"
            }
            return detail.isEmpty ? "\(reason)（curl 退出码 \(code)）" : "\(reason)：\(detail)"
        case .badWebhookURL: return "Webhook 地址无效（应为 https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…）"
        case .wecomAPI(let code, let message): return "企业微信返回错误 \(code)：\(message)"
        }
    }
}

/// 通过系统自带 /usr/bin/curl 发 SMTP 邮件。
/// 账号密码只写入 0600 的临时 curl 配置文件（不进 argv、不落日志），发送后立即删除。
/// 端口约定：465 走 smtps（隐式 TLS），587 走 STARTTLS（--ssl-reqd），25 尝试 STARTTLS。
enum SMTPSender {
    static func send(subject: String, body: String, config: PushChannelsConfig) async throws {
        let host = config.smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = config.smtpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw PushChannelError.incomplete("SMTP 服务器为空") }
        guard !username.isEmpty, !config.smtpPassword.isEmpty else {
            throw PushChannelError.incomplete("账号或密码/授权码为空")
        }
        guard let from = config.effectiveFromAddress else { throw PushChannelError.incomplete("发件人为空") }
        let recipients = config.recipientAddresses
        guard !recipients.isEmpty else { throw PushChannelError.incomplete("收件人为空") }
        let port = config.smtpPort > 0 ? config.smtpPort : 465

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("apiusage-smtp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let configFile = temporary.appendingPathComponent("curl.conf")
        let messageFile = temporary.appendingPathComponent("message.eml")
        try Self.configFileText(config: config, host: host, port: port, username: username,
                                from: from, recipients: recipients, messagePath: messageFile.path)
            .write(to: configFile, atomically: true, encoding: .utf8)
        try Self.messageText(subject: subject, body: body, from: from, recipients: recipients)
            .write(to: messageFile, atomically: true, encoding: .utf8)
        for file in [configFile, messageFile] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        try await runCurl(configPath: configFile.path)
    }

    private static func runCurl(configPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--config", configPath]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw PushChannelError.curl(-1, "无法启动 curl：\(error.localizedDescription)")
        }

        // waitUntilExit 会阻塞线程，放到全局队列再挂起当前任务
        let (code, stderrText): (Int32, String) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }

        if code != 0 {
            throw PushChannelError.curl(Int(code), stderrText)
        }
    }

    private static func configFileText(config: PushChannelsConfig, host: String, port: Int,
                                       username: String, from: String,
                                       recipients: [String], messagePath: String) -> String {
        var lines: [String] = []
        let scheme = port == 465 ? "smtps" : "smtp"
        lines.append("silent")
        lines.append("show-error")
        lines.append("max-time = \"25\"")
        lines.append("url = \"\(scheme)://\(host):\(port)\"")
        if port == 587 { lines.append("ssl-reqd") }
        else if port != 465 { lines.append("ssl") }
        lines.append("mail-from = \(quoted(from))")
        for recipient in recipients {
            lines.append("mail-rcpt = \(quoted(recipient))")
        }
        // 密码放配置文件而非 --user 参数，避免出现在进程列表里
        lines.append("user = \(quoted("\(username):\(config.smtpPassword)"))")
        lines.append("upload-file = \(quoted(messagePath))")
        return lines.joined(separator: "\n")
    }

    private static func messageText(subject: String, body: String, from: String, recipients: [String]) -> String {
        let encodedWord: (String) -> String = {
            "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?="
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss ZZ"

        let wrappedBody = Data(body.utf8).base64EncodedString()
            .chunked(into: 76)
            .joined(separator: "\r\n")

        var lines: [String] = []
        lines.append("From: \(encodedWord("API Usage")) <\(from)>")
        lines.append("To: " + recipients.joined(separator: ", "))
        lines.append("Subject: \(encodedWord(subject))")
        lines.append("Date: \(dateFormatter.string(from: Date()))")
        lines.append("Message-ID: <\(UUID().uuidString)@apiusage.local>")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        lines.append(wrappedBody)
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// curl 配置文件的双引号字面量：转义反斜杠与双引号
    private static func quoted(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[start..<end]))
            start = end
        }
        return chunks
    }
}

// MARK: - 企业微信

/// 企业微信群机器人：POST text 消息到 webhook，校验 errcode
enum WeComSender {
    static func send(text: String, config: PushChannelsConfig) async throws {
        let raw = config.wecomWebhook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            throw PushChannelError.badWebhookURL
        }

        var payload: [String: Any] = ["msgtype": "text"]
        var textPayload: [String: Any] = ["content": text]
        if config.wecomMentionAll { textPayload["mentioned_list"] = ["@all"] }
        payload["text"] = textPayload

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushChannelError.wecomAPI(-1, "无 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PushChannelError.wecomAPI(http.statusCode, "HTTP 错误")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let errcode = JSONUtil.int(json, "errcode") else {
            throw PushChannelError.wecomAPI(-1, "响应无法解析")
        }
        if errcode != 0 {
            let errmsg = JSONUtil.string(json, "errmsg") ?? ""
            throw PushChannelError.wecomAPI(errcode, errmsg)
        }
    }
}
