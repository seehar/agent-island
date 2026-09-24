//
//  NewAPIBalanceClient.swift
//  AgentIsland
//
//  New API 两个只读接口的客户端：查当前 Key 的额度（`/api/usage/token/`）与账户余额
//  （`/api/user/self`）。只发 GET，不写任何东西；两个端点各自独立，一个失败不影响另一个。
//
//  接口事实（对上游源码核过，改这块之前先复核）：
//  * 成功信封两种：`/api/usage/token/` 用 `{"code":true,"message":"ok","data":{…}}`，
//    `/api/user/self` 用 `{"success":true,"message":"","data":{…}}`——判定时「哪个在就用哪个」。
//  * 业务错误是 **HTTP 200** + `{"success":false,"message":…}`；缺鉴权头 / 令牌查不到是 401，
//    且 401 体里的 `code` 可能是**字符串**（`AUTH_…`），所以取 message 的那条路径不解析 code。
//  * Key 额度：`data.total_available` 是剩余；账户余额：`data.quota` 是剩余（不是总额，
//    更不是 `quota - used_quota`）。
//

import Foundation

/// New API 的两个只读接口。
nonisolated struct NewAPIBalanceClient: Sendable {
    /// 查当前 Key 的额度（带尾斜杠：少一个斜杠会多吃一次 307 重定向）。
    static let keyUsagePath = "/api/usage/token/"
    /// 查账户余额。
    static let accountUsagePath = "/api/user/self"

    // MARK: - 会话

    /// 专用会话：`ephemeral`（不把余额落进磁盘缓存）+ 10 秒请求超时（这条链路上任何一端
    /// 卡住都不该让「刷新」按钮一直转）。
    ///
    /// 会话**可注入**：单测用带 `URLProtocol` 桩的会话钉住「哪些端点被打了」——只填了访问
    /// 令牌时也必须打 `/api/user/self`（这正是「访问令牌没用」的回归面）。生产用默认会话。
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    init(session: URLSession = NewAPIBalanceClient.defaultSession) {
        self.session = session
    }

    // MARK: - 端点

    /// 端点拼接（纯函数）：只支持 https（明文 http 会被 ATS 拦掉，不如在这里说清楚），
    /// 去尾斜杠后直接拼固定路径——不走 `URL.appending(path:)`，它的尾斜杠行为不够可预期。
    /// - Throws: `.insecureURL`（不以 https:// 开头）、`.invalidURL`（拼出来的不是合法 URL）。
    static func endpoint(_ path: String, config: NewAPIConfig) throws -> URL {
        let base = config.trimmedServerURL
        guard base.lowercased().hasPrefix("https://") else { throw NewAPIBalanceError.insecureURL }

        var normalized = base
        while normalized.hasSuffix("/") { normalized.removeLast() }

        // 去掉 scheme 后必须还有主机名：否则 `https://` / `https:///sub` 这类输入会被拼成
        // 一个看似合法、实际打不通的 URL，错误信息也说不清问题在哪。
        let host = normalized.dropFirst("https://".count)
        guard !host.isEmpty, !host.hasPrefix("/") else { throw NewAPIBalanceError.invalidURL }

        guard let url = URL(string: normalized + path) else { throw NewAPIBalanceError.invalidURL }
        return url
    }

    // MARK: - 取数

    /// 查当前 Key 的额度。
    func keyUsage(_ config: NewAPIConfig) async throws -> NewAPIBalanceValue {
        var request = URLRequest(url: try Self.endpoint(Self.keyUsagePath, config: config))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.trimmedAPIKey)", forHTTPHeaderField: "Authorization")
        return try await fetch(request, decode: Self.decodeKeyUsage)
    }

    /// 查账户余额。
    ///
    /// 旧版实例还认 `New-Api-User` 头（用它校验令牌归属），新版完全不读——因此只在用户填了
    /// 用户 ID 时带上：对旧版有用，对 New 版无副作用。
    func accountUsage(_ config: NewAPIConfig) async throws -> NewAPIBalanceValue {
        var request = URLRequest(url: try Self.endpoint(Self.accountUsagePath, config: config))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.trimmedAccessToken)", forHTTPHeaderField: "Authorization")
        let userID = config.trimmedUserID
        if !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "New-Api-User")
        }
        return try await fetch(request, decode: Self.decodeAccountUsage)
    }

    /// 发一次请求并把响应折成读数：连不上 → `.transport`；非 2xx → 优先透出服务器的 message；
    /// 2xx → 交给解码（解码内部再判信封标志）。
    private func fetch(
        _ request: URLRequest,
        decode: (Data) throws -> NewAPIBalanceValue
    ) async throws -> NewAPIBalanceValue {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NewAPIBalanceError.transport
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let message = Self.errorMessage(from: data), !message.isEmpty {
                throw NewAPIBalanceError.server(message)
            }
            throw NewAPIBalanceError.status(status)
        }
        return try decode(data)
    }

    // MARK: - 解码（纯函数，可单测）

    /// 解 `/api/usage/token/` 的响应体。
    static func decodeKeyUsage(_ data: Data) throws -> NewAPIBalanceValue {
        let envelope = try Self.envelope(KeyUsageBody.self, from: data)
        guard envelope.isOK, let body = envelope.data else {
            throw NewAPIBalanceError.server(envelope.message ?? "")
        }
        return NewAPIBalanceValue(
            available: body.totalAvailable,
            used: body.totalUsed,
            granted: body.totalGranted,
            unlimited: body.unlimitedQuota ?? false)
    }

    /// 解 `/api/user/self` 的响应体。`quota` 就是**剩余**额度（见文件头）。
    static func decodeAccountUsage(_ data: Data) throws -> NewAPIBalanceValue {
        let envelope = try Self.envelope(AccountBody.self, from: data)
        guard envelope.isOK, let body = envelope.data else {
            throw NewAPIBalanceError.server(envelope.message ?? "")
        }
        return NewAPIBalanceValue(
            available: body.quota,
            used: body.usedQuota,
            granted: nil,
            unlimited: false)
    }

    private static func envelope<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws -> BalanceEnvelope<T> {
        do {
            return try JSONDecoder().decode(BalanceEnvelope<T>.self, from: data)
        } catch {
            throw NewAPIBalanceError.decoding
        }
    }

    /// 从错误体里取 `message`（非 2xx 时用）。
    ///
    /// 这条路径**不解析 `code`**：鉴权失败时它是字符串（`AUTH_UNAUTHORIZED` 之类），
    /// 声明成 `Bool?` 会让整个体解不出来，那就只能退化成「服务器返回错误 401」。
    ///
    /// 非 `private` 是为了让用例直接钉住上面这条（401 的 4xx 路径要起真会话才能走到，
    /// 而这里真正会出错的只是「怎么解这个体」）。
    static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(BalanceErrorBody.self, from: data))?.message
    }

    // MARK: - 响应体形状

    /// 成功信封：两个端点的成功标志不同名（Key 端点 `code`、账户端点 `success`），
    /// 因此都声明成可选，「哪个在就用哪个」；`code` 只在这一层当布尔用（错误体不走这里）。
    private struct BalanceEnvelope<T: Decodable>: Decodable {
        let success: Bool?
        let code: Bool?
        let message: String?
        let data: T?

        /// 成功标志：`success` 优先，其次 `code`；都没有、或为 false，都算失败。
        var isOK: Bool { (success ?? code) == true }
    }

    /// 错误体：只取 message。
    private struct BalanceErrorBody: Decodable {
        let message: String?
    }

    /// `/api/usage/token/` 的 `data`。
    private struct KeyUsageBody: Decodable {
        let totalGranted: Double
        let totalUsed: Double
        let totalAvailable: Double
        let unlimitedQuota: Bool?

        enum CodingKeys: String, CodingKey {
            case totalGranted = "total_granted"
            case totalUsed = "total_used"
            case totalAvailable = "total_available"
            case unlimitedQuota = "unlimited_quota"
        }
    }

    /// `/api/user/self` 的 `data`：只取要用到的两个字段。
    private struct AccountBody: Decodable {
        let quota: Double
        let usedQuota: Double

        enum CodingKeys: String, CodingKey {
            case quota
            case usedQuota = "used_quota"
        }
    }
}

/// 取数失败的类型。`reason` 是给界面直接显示的一行文案（本地化在这里收口）。
nonisolated enum NewAPIBalanceError: Error, Equatable {
    /// 地址不以 `https://` 开头。
    case insecureURL
    /// 地址不是合法 URL（含只有 scheme、没有主机这类）。
    case invalidURL
    /// 连不上 / 超时 / 连接被拒。
    case transport
    /// 响应不是预期的 JSON。
    case decoding
    /// 非 2xx，且响应体里没有 message。
    case status(Int)
    /// 服务器给的 message（可能是空串：2xx 但信封标志不为 true）。
    case server(String)

    /// 界面上的失败原因。
    ///
    /// 本类型是 `nonisolated`，只能用 `LocalizationManager` 的两个非隔离查表入口——
    /// 带 `CVarArg...` 的那个是 MainActor 实例方法，这里够不着。
    var reason: String {
        switch self {
        case .insecureURL:
            return LocalizationManager.t("Server URL must start with https://")
        case .invalidURL:
            return LocalizationManager.t("Server URL is not a valid URL")
        case .transport:
            return LocalizationManager.t("Could not reach the server")
        case .decoding:
            return LocalizationManager.t("Response could not be read")
        case .server(let message):
            // 服务器文案是内容、不是界面文案（New API 已按用户语言返回），非空时原样透出。
            return message.isEmpty
                ? LocalizationManager.t("Response could not be read")
                : message
        case .status(let code):
            return String(
                format: LocalizationManager.t(
                    "Server error %lld", languageCode: AppSettings.language.resolvedCode),
                locale: Locale.current,
                arguments: [code])
        }
    }
}
