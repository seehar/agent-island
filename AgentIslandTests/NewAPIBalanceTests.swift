//
//  NewAPIBalanceTests.swift
//  AgentIslandTests
//
//  New API 额度取数的纯逻辑用例：响应体解码（两种成功信封 + 两种错误体）、端点拼接与
//  https 门、额度数字格式化、配置判定。网络本身不测——上面这些函数才是会出错的地方，
//  它们都是纯函数，所以这里不需要起会话、也不需要真服务器。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("New API 额度取数")
struct NewAPIBalanceTests {
  // MARK: - 夹具

  private func json(_ text: String) -> Data { Data(text.utf8) }

  private func config(
    serverURL: String = "https://api.example.com",
    apiKey: String = "sk-x",
    accessToken: String = "",
    userID: String = ""
  ) -> NewAPIConfig {
    NewAPIConfig(
      serverURL: serverURL, apiKey: apiKey, accessToken: accessToken, userID: userID)
  }

  // MARK: - Key 额度

  @Test("Key 额度：total_available 是剩余，已用与总额各归其位")
  func decodesKeyUsage() throws {
    let body = """
      {
          "code": true,
          "message": "ok",
          "data": {
              "object": "token_usage",
              "name": "Default Token",
              "total_granted": 1000000,
              "total_used": 12345,
              "total_available": 987655,
              "unlimited_quota": false,
              "model_limits": {},
              "model_limits_enabled": false,
              "expires_at": 0
          }
      }
      """

    let value = try NewAPIBalanceClient.decodeKeyUsage(json(body))

    #expect(value.available == 987655)
    #expect(value.used == 12345)
    #expect(value.granted == 1_000_000)
    #expect(value.unlimited == false)
  }

  @Test("Key 额度：unlimited_quota 为真时带出「不限额度」")
  func decodesUnlimitedKey() throws {
    let body = """
      {"code":true,"message":"ok",
        "data":{"total_granted":1000000,"total_used":12345,"total_available":987655,
                        "unlimited_quota":true}}
      """

    let value = try NewAPIBalanceClient.decodeKeyUsage(json(body))

    #expect(value.unlimited)
    // 数值照旧带回来（要不要显示成「不限额度」是界面的事）。
    #expect(value.available == 987655)
  }

  // MARK: - 账户余额

  @Test("账户余额：quota 就是剩余，不是 quota 减 used_quota，也没有总额")
  func accountBalanceIsQuota() throws {
    let body = """
      {"success":true,"message":"",
        "data":{"id":123,"username":"test","quota":987655,"used_quota":12345,
                        "request_count":100}}
      """

    let value = try NewAPIBalanceClient.decodeAccountUsage(json(body))

    #expect(value.available == 987655)
    #expect(value.used == 12345)
    #expect(value.granted == nil)
    #expect(value.unlimited == false)
  }

  // MARK: - 错误信封

  @Test("业务错误（HTTP 200 + success:false）透出服务器 message")
  func surfacesServerMessage() {
    let body = #"{"success":false,"message":"令牌无效"}"#

    #expect(throws: NewAPIBalanceError.server("令牌无效")) {
      try NewAPIBalanceClient.decodeKeyUsage(json(body))
    }
    #expect(throws: NewAPIBalanceError.server("令牌无效")) {
      try NewAPIBalanceClient.decodeAccountUsage(json(body))
    }
  }

  @Test("响应体不是预期的 JSON 判成解码失败；标志为真却没有 data 算服务器失败")
  func rejectsNonJSONBody() {
    #expect(throws: NewAPIBalanceError.decoding) {
      try NewAPIBalanceClient.decodeKeyUsage(json("<html>502 Bad Gateway</html>"))
    }
    // 结构合法、信封标志也是 true，但没带 data：这是「服务器没给读数」，不是解码失败——
    // 判成解码失败会把上游换了个信封这种事掩饰成「响应无法解析」。
    #expect(throws: NewAPIBalanceError.server("")) {
      try NewAPIBalanceClient.decodeKeyUsage(json(#"{"code":true}"#))
    }
  }

  @Test("鉴权失败体里的 code 是字符串，也不影响取出 message")
  func extractsMessageFromAuthFailureBody() {
    // 401 体长这样（`code` 是 **字符串**）：声明成 Bool? 去解它就会整条解不出来，
    // 那样只能退化成「服务器返回错误 401」。取 message 的路径因此不解析 code。
    let body =
      #"{"success":false,"code":"AUTH_UNAUTHORIZED","message":"未登录或登录已过期"}"#

    #expect(NewAPIBalanceClient.errorMessage(from: json(body)) == "未登录或登录已过期")
    #expect(NewAPIBalanceClient.errorMessage(from: json(#"{"success":false}"#)) == nil)
  }

  @Test("失败原因：服务器文案原样透出，空文案与带状态码各有兜底")
  func failureReasonsAreReadable() {
    #expect(NewAPIBalanceError.server("令牌无效").reason == "令牌无效")

    // 空 message（2xx 但信封标志不为 true）与解码失败给同一条兜底文案。
    #expect(NewAPIBalanceError.server("").reason.isEmpty == false)
    #expect(NewAPIBalanceError.server("").reason == NewAPIBalanceError.decoding.reason)

    // 状态码要出现在文案里（文案随语言变，"502" 不会变）。
    #expect(NewAPIBalanceError.status(502).reason.contains("502"))
  }

  // MARK: - 端点

  @Test("端点拼接：去尾斜杠后拼固定路径")
  func endpointNormalization() throws {
    let expected = "https://api.example.com/api/usage/token/"
    let inputs = [
      "https://api.example.com",
      "https://api.example.com/",
      "  https://api.example.com/  ",
    ]

    for input in inputs {
      let url = try NewAPIBalanceClient.endpoint(
        NewAPIBalanceClient.keyUsagePath, config: config(serverURL: input))
      #expect(url.absoluteString == expected, "输入：\(input)")
    }

    // 带路径前缀的实例（网关挂在子路径上）。
    let prefixed = try NewAPIBalanceClient.endpoint(
      NewAPIBalanceClient.accountUsagePath, config: config(serverURL: "https://h/sub/"))
    #expect(prefixed.absoluteString == "https://h/sub/api/user/self")
  }

  @Test("端点只接受 https：明文地址与畸形地址各有明确错误")
  func endpointRejectsInsecureAndMalformedURLs() {
    #expect(throws: NewAPIBalanceError.insecureURL) {
      try NewAPIBalanceClient.endpoint(
        NewAPIBalanceClient.keyUsagePath, config: config(serverURL: "http://h"))
    }
    #expect(throws: NewAPIBalanceError.insecureURL) {
      try NewAPIBalanceClient.endpoint(
        NewAPIBalanceClient.keyUsagePath, config: config(serverURL: "not a url"))
    }
    #expect(throws: NewAPIBalanceError.insecureURL) {
      try NewAPIBalanceClient.endpoint(
        NewAPIBalanceClient.keyUsagePath, config: config(serverURL: ""))
    }
    // 有 scheme 但没有主机：拼出来会是个打不通的 URL，因此直接判非法。
    for hostless in ["https://", "https:///sub"] {
      #expect(throws: NewAPIBalanceError.invalidURL) {
        try NewAPIBalanceClient.endpoint(
          NewAPIBalanceClient.keyUsagePath, config: config(serverURL: hostless))
      }
    }
  }

  // MARK: - 展示与配置

  @Test("额度数字按 locale 分组")
  func formatsQuota() {
    let en = Locale(identifier: "en_US")

    #expect(NewAPIBalanceFormat.quota(1_234_567, locale: en) == "1,234,567")
    #expect(NewAPIBalanceFormat.quota(999.6, locale: en) == "1,000")
    #expect(NewAPIBalanceFormat.quota(0, locale: en) == "0")
  }

  @Test("配置判定：地址与 Key 齐备才算配好，账户槽还要访问令牌")
  func configReadiness() {
    #expect(config(serverURL: "", apiKey: "").isConfigured == false)
    #expect(config(serverURL: "", apiKey: "").canReadAccount == false)

    let keyOnly = config(accessToken: "")
    #expect(keyOnly.isConfigured)
    #expect(keyOnly.canReadAccount == false)

    let full = config(serverURL: " https://h ", apiKey: " sk-x ", accessToken: " tok ")
    #expect(full.isConfigured)
    #expect(full.canReadAccount)
    #expect(full.trimmedAPIKey == "sk-x")
    #expect(full.trimmedServerURL == "https://h")
  }

  @Test("失败时保留上一次成功的数值，只有失败没有旧值时才是空")
  func failedReadingKeepsLastValue() {
    let value = NewAPIBalanceValue(available: 42, used: 1, granted: nil, unlimited: false)

    #expect(NewAPIBalanceReading.value(value).lastValue == value)
    #expect(NewAPIBalanceReading.failed(reason: "断网", value: value).lastValue == value)
    #expect(NewAPIBalanceReading.failed(reason: "断网", value: nil).lastValue == nil)
    #expect(NewAPIBalanceReading.loading.lastValue == nil)
    #expect(NewAPIBalanceReading.notConfigured.lastValue == nil)
    #expect(NewAPIBalanceReading.needsAccessToken.lastValue == nil)
  }
}
