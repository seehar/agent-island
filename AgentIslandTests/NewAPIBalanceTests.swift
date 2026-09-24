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

/// 钉住 `BalanceStubProtocol`：它的响应表与请求记录是**静态共享**的，每个用它的用例都会
/// `reset()` 再断言——并行跑会互相清表/串记录（表现是请求次数翻几倍、余额读到别的用例的
/// 响应体）。因此这个套件必须串行（与 `AgentProviderTests` 等同一口径）。
@Suite("New API 额度取数", .serialized)
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
  let payload = try NewAPIBalanceClient.decodeAccountPayload(
   json(Self.accountBody(group: "default")))

  #expect(payload.value.available == 987655)
  #expect(payload.value.used == 12345)
  #expect(payload.value.granted == nil)
  #expect(payload.value.unlimited == false)
 }

 // MARK: - 身份、分组与令牌

 @Test("身份字段：display_name / id / group / request_count 解出来，缺项给安全默认")
 func decodesIdentityWithFallbacks() throws {
  let payload = try NewAPIBalanceClient.decodeAccountPayload(
   json(Self.accountBody(group: "default")))
  #expect(payload.identity.displayName == "李兴华")
  #expect(payload.identity.userID == 59)
  #expect(payload.identity.group == "default")
  #expect(payload.identity.requestCount == 358_486)

  // 老实例少了身份键（甚至一个都没有）：数值照旧，身份退回安全默认——缺一个
  // `request_count` 不该把整条余额读数判成失败。
  let sparse = try NewAPIBalanceClient.decodeAccountPayload(
   json(#"{"success":true,"message":"","data":{"quota":1,"used_quota":0}}"#))
  #expect(sparse.identity.displayName.isEmpty)
  #expect(sparse.identity.userID == 0)
  #expect(sparse.identity.group.isEmpty)
  #expect(sparse.identity.requestCount == 0)
  #expect(sparse.value.available == 1)
 }

 @Test("实例版本：与额度口径一起解出来，老实例没有 version 时是 nil")
 func decodesSiteVersion() throws {
  let status = try NewAPIBalanceClient.decodeSiteStatus(json(Self.statusBody))
  #expect(status.version == "v1.0.0-rc.37")

  let bare = try NewAPIBalanceClient.decodeSiteStatus(
   json(#"{"success":true,"message":"","data":{"quota_display_type":"USD"}}"#))
  #expect(bare.version == nil)
 }

 @Test("分组倍率表：只带 desc 的分组不进表，表里没有的分组就是 nil")
 func decodesUserGroups() throws {
  let ratios = try NewAPIBalanceClient.decodeUserGroups(json(Self.groupsBody))
  #expect(ratios["default"] == 0.8)
  #expect(ratios.count == 1)
  // 「查不到」与「倍率是 0」是两件事：缺 `ratio` 的分组不进表，调用方据此保留上一轮的值。
  #expect(ratios["vip"] == nil)

  let descOnly = try NewAPIBalanceClient.decodeUserGroups(
   json(#"{"data":{"vip":{"desc":"贵宾"}},"success":true}"#))
  #expect(descOnly.isEmpty)
 }

 @Test("令牌列表：掩码/限额/时间字段各归其位，-1 与 0 都算「没有这个时间」")
 func decodesTokenItems() throws {
  let items = try NewAPIBalanceClient.decodeTokenItems(json(Self.tokenListBody()))
  #expect(items.count == 1)
  let item = try #require(items.first)
  #expect(item.maskedKey == "s7xl**********n1T6")
  #expect(item.name == "ai-workspace")
  #expect(item.used == 1_015_417)
  #expect(item.unlimited)
  // `expired_time = -1` 是「永不过期」。
  #expect(item.expiresAt == nil)
  #expect(item.accessedAt == Date(timeIntervalSince1970: 1_790_221_937))

  // 真的带过期时间时照解；`accessed_time` 缺失就是 nil；`items` 缺失给空表而不是失败。
  let expiring = try NewAPIBalanceClient.decodeTokenItems(
   json(#"{"success":true,"data":{"items":[{"key":"ab****gh","expired_time":1800000000}]}}"#))
  #expect(expiring.first?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
  #expect(expiring.first?.accessedAt == nil)
  #expect(try NewAPIBalanceClient.decodeTokenItems(json(#"{"success":true,"data":{}}"#)).isEmpty)
 }

 @Test("掩码匹配：三分支都覆盖、剥掉 sk- 前缀、同表其它令牌不匹配")
 func tokenItemMatchesConfiguredAPIKey() {
  let long = NewAPITokenItem(
   maskedKey: "s7xl**********n1T6", name: "ai-workspace", used: 0, unlimited: true,
   expiresAt: nil, accessedAt: nil)
  // 配置里存的是 `sk-…`，服务端掩码基于**裸** key：匹配前剥前缀（前后带空白也照剥）。
  #expect(long.matches(apiKey: "sk-s7xlABCDEFGHIJn1T6"))
  #expect(long.matches(apiKey: "s7xlABCDEFGHIJn1T6"))
  #expect(long.matches(apiKey: "  sk-s7xlABCDEFGHIJn1T6  "))

  // 掩码只暴露首尾各 4 位 ⇒ 同首尾的另一个令牌**会**被判为匹配。这是掩码精度的上限，
  // 不是这里能补救的（用例把它显式记下来，免得日后被当成缺陷）。
  #expect(long.matches(apiKey: "sk-s7xlZZZZZZZZZZn1T6"))
  // 首 4 位或尾 4 位对不上就不匹配。
  #expect(long.matches(apiKey: "sk-z9xlABCDEFGHIJn1T6") == false)
  #expect(long.matches(apiKey: "sk-s7xlABCDEFGHIJn1T7") == false)
  #expect(long.matches(apiKey: "") == false)

  // ≤8 字符分支：前 2 + `****` + 后 2。
  let short = NewAPITokenItem(
   maskedKey: "ab****gh", name: "短", used: 0, unlimited: false, expiresAt: nil,
   accessedAt: nil)
  #expect(short.matches(apiKey: "sk-abcdefgh"))

  // ≤4 字符分支：整条都是 `*`。
  let tiny = NewAPITokenItem(
   maskedKey: "**", name: "极短", used: 0, unlimited: false, expiresAt: nil, accessedAt: nil)
  #expect(tiny.matches(apiKey: "sk-ab"))

  // 服务端对空 key 回空串：没有掩码就没法匹配。
  let empty = NewAPITokenItem(
   maskedKey: "", name: "", used: 0, unlimited: false, expiresAt: nil, accessedAt: nil)
  #expect(empty.matches(apiKey: "sk-abcdefgh") == false)
 }

 // MARK: - 错误信封

 @Test("业务错误（HTTP 200 + success:false）透出服务器 message")
 func surfacesServerMessage() {
  let body = #"{"success":false,"message":"令牌无效"}"#

  #expect(throws: NewAPIBalanceError.server("令牌无效")) {
   try NewAPIBalanceClient.decodeKeyUsage(json(body))
  }
  #expect(throws: NewAPIBalanceError.server("令牌无效")) {
   try NewAPIBalanceClient.decodeAccountPayload(json(body))
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

 @Test("实例显示口径：按 /api/status 解出换算参数，缺项按「显示内部单位」兜底")
 func decodesSiteStatus() throws {
  let currency = try NewAPIBalanceClient.decodeSiteStatus(json(Self.statusBody)).currency
  #expect(currency.displayType == .usd)
  #expect(currency.displayInCurrency)
  #expect(currency.quotaPerUnit == 500_000)
  #expect(currency.usdExchangeRate == 7.3)
  #expect(currency.customSymbol == "¤")

  // 站点没给这些键（老版本 / 精简部署）：宁可显示内部单位，也不要凭空算金额。
  let bare = try NewAPIBalanceClient.decodeSiteStatus(
   json(#"{"success":true,"message":"","data":{}}"#))
  #expect(bare.currency == NewAPICurrency.rawQuota)
  #expect(bare.currency.displayInCurrency == false)

  // 不认识的显示类型按美元兜底（实例前端同样是 default → USD）。
  let unknown = try NewAPIBalanceClient.decodeSiteStatus(
   json(#"{"success":true,"data":{"quota_display_type":"XYZ","display_in_currency":true}}"#))
  #expect(unknown.currency.displayType == .usd)
  #expect(unknown.currency.quotaPerUnit == 500_000)
 }

 @Test("金额按站点口径写：美元 / 人民币 / 自定义 / token 数 / 关掉货币显示")
 func formatsWithSiteCurrency() {
  let en = Locale(identifier: "en_US")
  // 实测实例：quota_per_unit = 500000、quota_display_type = USD。
  let usd = NewAPICurrency(displayInCurrency: true, quotaPerUnit: 500_000)

  #expect(NewAPIBalanceFormat.display(175_134_432, currency: usd, locale: en) == "$350.27")
  #expect(NewAPIBalanceFormat.display(8_274_865_568, currency: usd, locale: en) == "$16,549.73")
  // 整数不补零（平台前端的最小/最大小数位是 0 与 2）。
  #expect(NewAPIBalanceFormat.display(175_000_000, currency: usd, locale: en) == "$350")

  let cny = NewAPICurrency(
   displayType: .cny, displayInCurrency: true, quotaPerUnit: 500_000, usdExchangeRate: 7.3)
  #expect(NewAPIBalanceFormat.display(175_134_432, currency: cny, locale: en) == "¥2,556.96")

  let custom = NewAPICurrency(
   displayType: .custom, displayInCurrency: true, quotaPerUnit: 500_000,
   customSymbol: "¤", customExchangeRate: 2)
  #expect(NewAPIBalanceFormat.display(175_134_432, currency: custom, locale: en) == "¤ 700.54")

  // token 档位与「站点关掉货币显示」都写内部单位（改造前就是这么显示的）。
  let tokens = NewAPICurrency(displayType: .tokens, displayInCurrency: true)
  #expect(NewAPIBalanceFormat.display(175_134_432, currency: tokens, locale: en) == "175,134,432")
  #expect(
   NewAPIBalanceFormat.display(
    175_134_432, currency: NewAPICurrency(displayInCurrency: false), locale: en)
    == "175,134,432")

  // 站点把换算参数写成 0（或缺失）时按缺省走，别算出 0 元或无穷大。
  let zeroed = NewAPICurrency(
   displayInCurrency: true, quotaPerUnit: 0, usdExchangeRate: 0)
  #expect(NewAPIBalanceFormat.display(500_000, currency: zeroed, locale: en) == "$1")
 }

 /// `/api/user/self` 的响应形状（额度两项 + 身份四项，数值与实测实例同形但是造的）。
 private static func accountBody(group: String) -> String {
  """
  {"success":true,"message":"","data":{"quota":987655,"used_quota":12345,
    "display_name":"李兴华","id":59,"group":"\(group)","request_count":358486}}
  """
 }

 /// `/api/user/self/groups` 的响应形状（实测实例：`default` 倍率 0.8）。
 private static let groupsBody = #"""
  {"data":{"default":{"desc":"默认分组","ratio":0.8}},"message":"","success":true}
  """#

 /// `/api/token/` 的响应形状（实测实例：掩码 + `expired_time: -1` 永久不过期）。
 private static func tokenListBody(maskedKey: String = "s7xl**********n1T6") -> String {
  """
  {"data":{"items":[{"id":279,"key":"\(maskedKey)","name":"ai-workspace",
    "used_quota":1015417,"unlimited_quota":true,"expired_time":-1,
    "accessed_time":1790221937,"status":1}],"total":2},
   "message":"","success":true}
  """
 }

 /// `/api/usage/token/` 的响应形状（`total_available` 是剩余）。
 private static let keyUsageBody = #"""
  {"code":true,"message":"ok","data":{"total_granted":1000000,"total_used":12345,
   "total_available":987655}}
  """#

 /// 令牌列表在桩里的键：带 query 的 URL 不以 `/` 结尾，而 `URL.path` 会吃掉路径尾斜杠
 /// ⇒ 桩键是 `/api/token`（**没有**尾斜杠，与 `/api/usage/token/` 不同）。
 private static let tokenListStubKey = "/api/token"

 /// 实例 `/api/status` 的响应形状（字段与实测实例一致，数值是造的）。
 private static let statusBody = #"""
  {
    "success": true,
    "message": "",
    "data": {
      "version": "v1.0.0-rc.37",
      "display_in_currency": true,
      "quota_display_type": "USD",
      "quota_per_unit": 500000,
      "usd_exchange_rate": 7.3,
      "custom_currency_symbol": "¤",
      "custom_currency_exchange_rate": 1,
      "HeaderNavModules": "{\"home\":true}"
    }
  }
  """#

 @Test("额度数字按 locale 分组")
 func formatsQuota() {
  let en = Locale(identifier: "en_US")

  #expect(NewAPIBalanceFormat.quota(1_234_567, locale: en) == "1,234,567")
  #expect(NewAPIBalanceFormat.quota(999.6, locale: en) == "1,000")
  #expect(NewAPIBalanceFormat.quota(0, locale: en) == "0")
 }

 @Test("槽位门禁分开算：只填访问令牌也必须能查账户余额")
 func configReadiness() {
  let empty = config(serverURL: "", apiKey: "", accessToken: "")
  #expect(empty.isConfigured == false)
  #expect(empty.hasServer == false)
  #expect(NewAPISlot.key.missing(in: empty) == .notConfigured)
  #expect(NewAPISlot.account.missing(in: empty) == .notConfigured)

  // 只填了地址：两个槽都缺凭据，但缺的不是同一样（页面据此各写各的提示）。
  let serverOnly = config(apiKey: "", accessToken: "")
  #expect(serverOnly.isConfigured == false)
  #expect(NewAPISlot.key.missing(in: serverOnly) == .needsAPIKey)
  #expect(NewAPISlot.account.missing(in: serverOnly) == .needsAccessToken)

  // **只填访问令牌**：账户槽能查。旧口径把「配好」定义成 Key 齐备，于是这一档
  // 连请求都不发，页面上两行都写「未配置」——用户看到的正是「访问令牌没用」。
  let tokenOnly = config(apiKey: "", accessToken: " tok ")
  #expect(tokenOnly.isConfigured)
  #expect(tokenOnly.canReadAccount)
  #expect(tokenOnly.canReadKey == false)
  #expect(NewAPISlot.account.missing(in: tokenOnly) == nil)
  #expect(NewAPISlot.key.missing(in: tokenOnly) == .needsAPIKey)

  let keyOnly = config(accessToken: "")
  #expect(keyOnly.isConfigured)
  #expect(keyOnly.canReadKey)
  #expect(keyOnly.canReadAccount == false)
  #expect(NewAPISlot.key.missing(in: keyOnly) == nil)
  #expect(NewAPISlot.account.missing(in: keyOnly) == .needsAccessToken)

  let full = config(serverURL: " https://h ", apiKey: " sk-x ", accessToken: " tok ")
  #expect(full.isConfigured)
  #expect(full.canReadAccount)
  #expect(full.canReadKey)
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
  #expect(NewAPIBalanceReading.needsAPIKey.lastValue == nil)
 }

 // MARK: - 账号与快照

 @Test("账号显示名：备注名优先，其次服务器主机名，都没有时留给界面按序号兜底")
 func accountDisplayName() {
  let labelled = NewAPIAccount(
   label: "  个人站  ", config: config(serverURL: "https://a.example.com"))
  #expect(labelled.displayName == "个人站")

  let host = NewAPIAccount(config: config(serverURL: "https://a.example.com/sub"))
  #expect(host.displayName == "a.example.com")

  // 地址解析不出主机时退回原文：宁可显示用户填的东西，也不要空着。
  #expect(NewAPIAccount(config: config(serverURL: "h")).displayName == "h")
  #expect(NewAPIAccount().displayName.isEmpty)
 }

 @Test("账号是 Codable：存进偏好域再读回来完全一致（id 也要保持）")
 func accountRoundTripsThroughJSON() throws {
  let account = NewAPIAccount(
   label: "team",
   config: config(serverURL: "https://h", apiKey: "sk-a", accessToken: "tok"))
  let data = try JSONEncoder().encode([account])
  #expect(try JSONDecoder().decode([NewAPIAccount].self, from: data) == [account])
 }

 @Test("起手占位就过槽位门禁：不发请求的槽不显示「加载中」")
 func pendingReadingHonoursSlotGates() {
  // 只填地址：两个槽都缺凭据 ⇒ 占位就该说缺什么。
  let serverOnly = NewAPIConfig(serverURL: "https://h")
  #expect(NewAPIBalanceViewModel.pendingReading(for: serverOnly).key == .needsAPIKey)
  #expect(NewAPIBalanceViewModel.pendingReading(for: serverOnly).account == .needsAccessToken)

  // 只填访问令牌：账户槽能查 ⇒ 先给「加载中」，Key 槽说缺 Key。
  let tokenOnly = NewAPIConfig(serverURL: "https://h", accessToken: "tok")
  #expect(NewAPIBalanceViewModel.pendingReading(for: tokenOnly).account == .loading)
  #expect(NewAPIBalanceViewModel.pendingReading(for: tokenOnly).key == .needsAPIKey)

  // 连地址都没填：两个槽都是「未配置」。
  let blank = NewAPIBalanceViewModel.pendingReading(for: NewAPIConfig())
  #expect(blank.account == .notConfigured)
  #expect(blank.key == .notConfigured)
 }

 @Test("账号列表对缺字段容错：将来加字段不会让整份凭据解不出来")
 func accountListDecodeIsTolerant() throws {
  let id = UUID()
  // 缺 `apiKey` / `userID`（老数据）＋两个未知字段（新版本写的）。
  let blob = #"""
   [
     {
       "id": "\#(id.uuidString)",
       "label": "team",
       "config": {
         "serverURL": "https://h",
         "accessToken": "tok",
         "futureField": 1
       },
       "futureTop": true
     }
   ]
   """#

  let accounts = try JSONDecoder().decode([NewAPIAccount].self, from: json(blob))
  #expect(accounts.count == 1)
  // 凭据必须活下来：解不出来会被当成「全新安装」，把用户存的账号静默换成空表。
  #expect(accounts.first?.id == id)
  #expect(accounts.first?.label == "team")
  #expect(accounts.first?.config.trimmedServerURL == "https://h")
  #expect(accounts.first?.config.trimmedAccessToken == "tok")
  #expect(accounts.first?.config.apiKey.isEmpty == true)

  // 连 `config` 整个缺失也只丢那一项，账号本身仍要解出来。
  let sparseBlob = #"[{"label":"bare"}]"#
  let sparse = try JSONDecoder().decode([NewAPIAccount].self, from: json(sparseBlob))
  #expect(sparse.count == 1)
  #expect(sparse.first?.label == "bare")
  #expect(sparse.first?.config.trimmedServerURL.isEmpty == true)
 }

 @Test("快照按账号查：没查过的账号是「未配置」，不是失败态")
 func snapshotLookupDefaultsToNotConfigured() {
  var snapshot = NewAPIBalanceSnapshot()
  #expect(snapshot[UUID()] == NewAPIAccountReading())
  #expect(snapshot.hasFreshValue == false)

  let value = NewAPIBalanceValue(available: 1, used: 0, granted: nil, unlimited: false)
  let id = UUID()
  snapshot.readings[id] = NewAPIAccountReading(account: .value(value), key: .needsAPIKey)
  #expect(snapshot[id].account.lastValue?.available == 1)
  #expect(snapshot[id].key.lastValue == nil)
  #expect(snapshot[id].hasValue)
  #expect(snapshot.hasFreshValue)

  // 「失败但带着上一轮的旧值」不算本轮新值：否则全部账号都失败时，页眉的「更新于」
  // 会被推到现在，用户以为数字是刚拉的。
  var carried = NewAPIBalanceSnapshot()
  carried.readings[id] = NewAPIAccountReading(
   account: .failed(reason: "断网", value: value), key: .needsAPIKey)
  #expect(carried[id].hasValue)
  #expect(carried.hasFreshValue == false)
 }

 @Test("空账号判定：只认「什么都没填」")
 func blankAccountDetection() {
  #expect(NewAPIAccount().isBlank)
  #expect(NewAPIAccount(label: " ").isBlank)
  #expect(NewAPIAccount(config: config(serverURL: " https://h ")).isBlank == false)
 }

 // MARK: - 偏好域（账号列表）

 /// 独立偏好域：账号列表的读写、迁移与视图模型用例都走它，不碰用户真实设置。
 private func isolatedDefaults() throws -> UserDefaults {
  let name = "newapi-accounts-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  defaults.removePersistentDomain(forName: name)
  return defaults
 }

 @Test("迁移：旧的四键搬成一个账号，只搬一次（清空账号后不会被旧键复活）")
 func migratesLegacySingleAccountOnce() throws {
  let defaults = try isolatedDefaults()
  defaults.set("https://legacy.example.com", forKey: "newAPIServerURL")
  defaults.set("sk-legacy", forKey: "newAPIKey")
  defaults.set("tok-legacy", forKey: "newAPIAccessToken")
  defaults.set("7", forKey: "newAPIUserID")

  AppSettings.migrateNewAPIAccountsIfNeeded(defaults: defaults)
  let accounts = AppSettings.newAPIAccounts(defaults: defaults)
  #expect(accounts.count == 1)
  #expect(accounts.first?.config.trimmedServerURL == "https://legacy.example.com")
  #expect(accounts.first?.config.trimmedAPIKey == "sk-legacy")
  #expect(accounts.first?.config.trimmedAccessToken == "tok-legacy")
  #expect(accounts.first?.config.trimmedUserID == "7")

  // 再跑一次不新增（标记 + 「已有列表」两道判定）。
  AppSettings.migrateNewAPIAccountsIfNeeded(defaults: defaults)
  #expect(AppSettings.newAPIAccounts(defaults: defaults).count == 1)

  // 用户把账号清空后，旧键不该把它复活。
  AppSettings.setNewAPIAccounts([], defaults: defaults)
  AppSettings.migrateNewAPIAccountsIfNeeded(defaults: defaults)
  #expect(AppSettings.newAPIAccounts(defaults: defaults).isEmpty)
 }

 @Test("全新安装：没有旧键时也迁移出一个空账号（额度页从一张空表开始）")
 func migratesFreshInstallToSingleBlankAccount() throws {
  let defaults = try isolatedDefaults()
  AppSettings.migrateNewAPIAccountsIfNeeded(defaults: defaults)
  let accounts = AppSettings.newAPIAccounts(defaults: defaults)
  #expect(accounts.count == 1)
  #expect(accounts.first?.isBlank == true)
 }

 @Test("选中账号的持久化：存的 id 不在列表里时给出 nil（界面回落第一个）")
 func selectionPersistence() throws {
  let defaults = try isolatedDefaults()
  #expect(AppSettings.newAPISelectedAccountID(defaults: defaults) == nil)

  let id = UUID()
  AppSettings.setNewAPISelectedAccountID(id, defaults: defaults)
  #expect(AppSettings.newAPISelectedAccountID(defaults: defaults) == id)
 }

 // MARK: - 视图模型

 @MainActor
 @Test("账号增删选：永远至少留一个账号，字段每敲一下就落盘")
 func viewModelKeepsAtLeastOneAccount() throws {
  let defaults = try isolatedDefaults()
  let model = NewAPIBalanceViewModel(defaults: defaults)
  // 空偏好域：给一个空账号，而不是零账号（零账号会让五行输入框没有内容可画）。
  #expect(model.accounts.count == 1)
  #expect(model.canRemoveSelectedAccount == false)

  model.removeSelectedAccount()
  #expect(model.accounts.count == 1)

  model.addAccount()
  #expect(model.accounts.count == 2)
  #expect(model.canRemoveSelectedAccount)
  #expect(model.selectedAccountID == model.accounts.last?.id)

  // 字段写入：内存与偏好域同时更新（输入框每敲一下都会走到这里）。
  model.setField(.serverURL, to: "https://a.example.com")
  #expect(model.field(.serverURL) == "https://a.example.com")
  let stored = AppSettings.newAPIAccounts(defaults: defaults)
  #expect(stored.count == 2)
  #expect(stored.last?.config.serverURL == "https://a.example.com")
  #expect(AppSettings.newAPISelectedAccountID(defaults: defaults) == model.selectedAccountID)

  // 换选中账号：输入框跟着换成那个账号的值。
  model.selectAccount(model.accounts[0].id)
  #expect(model.field(.serverURL).isEmpty)
  #expect(model.field(.label).isEmpty)

  model.removeSelectedAccount()
  #expect(model.accounts.count == 1)
  #expect(model.selectedAccountID == model.accounts[0].id)
 }

 @MainActor
 @Test("一个能查的账号都没有时不发请求：每行如实说缺什么")
 func viewModelPaintsMissingCredentialsWithoutRequesting() throws {
  let defaults = try isolatedDefaults()
  let account = NewAPIAccount(config: NewAPIConfig(serverURL: "https://h"))
  AppSettings.setNewAPIAccounts([account], defaults: defaults)

  let model = NewAPIBalanceViewModel(defaults: defaults)
  #expect(model.selectedAccountID == account.id)

  // 只填了地址：`refresh()` 在没有任何可查账号时提前返回（不发请求），
  // 两行各写各的提示而不是笼统的「未配置」。
  model.refresh()
  #expect(model.selectedReading.key == .needsAPIKey)
  #expect(model.selectedReading.account == .needsAccessToken)
  #expect(model.snapshot.refreshedAt == nil)
  #expect(model.isRefreshing == false)
 }

 @MainActor
 @Test("取数面（桩会话）：只填访问令牌就打账户端点，两个账号各按自己的门禁取数")
 func refreshesEveryAccountThroughItsOwnSlotGates() async throws {
  BalanceStubProtocol.reset()
  BalanceStubProtocol.responses["/api/user/self"] = (
   status: 200, body: Self.accountBody(group: "default")
  )
  BalanceStubProtocol.responses["/api/usage/token/"] = (status: 200, body: Self.keyUsageBody)
  BalanceStubProtocol.responses["/api/user/self/groups"] = (
   status: 200, body: Self.groupsBody
  )
  BalanceStubProtocol.responses[Self.tokenListStubKey] = (
   status: 200, body: Self.tokenListBody()
  )
  BalanceStubProtocol.responses["/api/status"] = (status: 200, body: Self.statusBody)

  let defaults = try isolatedDefaults()
  // 账号一：只有访问令牌（就是报障的那种填法）。
  let tokenOnly = NewAPIAccount(
   label: "token-only",
   config: NewAPIConfig(serverURL: "https://a.example.com", accessToken: "tok"))
  // 账号二：同一台实例上的另一个账号（Key 与令牌都填了）——显示口径因此只需查一次。
  let full = NewAPIAccount(
   label: "full",
   config: NewAPIConfig(
    serverURL: "https://a.example.com", apiKey: "sk-b", accessToken: "tok-b"))
  AppSettings.setNewAPIAccounts([tokenOnly, full], defaults: defaults)

  let model = NewAPIBalanceViewModel(
   client: NewAPIBalanceClient(session: BalanceStubProtocol.session()), defaults: defaults)
  model.refresh()
  await waitUntilRefreshed(model)

  // 账号一：账户槽有数（修复面），Key 槽如实报缺 Key。
  #expect(model.snapshot[tokenOnly.id].account.lastValue?.available == 987655)
  #expect(model.snapshot[tokenOnly.id].key == .needsAPIKey)
  // 账号二：两个槽都有数。
  #expect(model.snapshot[full.id].account.lastValue?.available == 987655)
  #expect(model.snapshot[full.id].key.lastValue?.granted == 1_000_000)

  // 端点各打各的：账户端点两个账号各一次；Key 端点只有填了 Key 的那个账号打；
  // 分组与令牌两路由账户身份派生，因此只有填了访问令牌的账号打（这里两个都填了）；
  // 显示口径是实例级的，同一台服务器只查一次（公开端点，不带凭据也算一次网络往返）。
  let paths = BalanceStubProtocol.requestedPaths
  #expect(paths.filter { $0 == "/api/user/self" }.count == 2)
  #expect(paths.filter { $0 == "/api/usage/token/" }.count == 1)
  #expect(paths.filter { $0 == "/api/user/self/groups" }.count == 2)
  #expect(paths.filter { $0 == Self.tokenListStubKey }.count == 2)
  #expect(paths.filter { $0 == "/api/status" }.count == 1)
  #expect(model.snapshot.refreshedAt != nil)

  // 显示口径已落到读数上：界面因此写 $1.98 而不是 987,655。
  #expect(model.snapshot[tokenOnly.id].siteCurrency.displayInCurrency)
  #expect(model.snapshot[tokenOnly.id].siteCurrency.quotaPerUnit == 500_000)
  // （987655 / 500000 = 1.97531 ⇒ 平台口径是两位小数）
  #expect(
   NewAPIBalanceFormat.display(
    987_655, currency: model.snapshot[tokenOnly.id].siteCurrency,
    locale: Locale(identifier: "en_US")) == "$1.98")

  // 第二圈：实例的公开设置查不到（比如 /api/status 被网关拦了）时，余额照旧刷新，
  // 口径与版本都沿用上一次已知的——不能因为这一路失败就闪回内部单位或把版本擦掉。
  BalanceStubProtocol.responses["/api/status"] = nil
  model.refresh()
  await waitUntilRefreshed(model)
  #expect(model.snapshot[tokenOnly.id].account.lastValue?.available == 987_655)
  #expect(model.snapshot[tokenOnly.id].siteCurrency.displayInCurrency)
  #expect(model.snapshot[tokenOnly.id].siteVersion == "v1.0.0-rc.37")
 }

 @MainActor
 @Test("分组倍率取 identity.group 那一项：分组缺失时如实置空，不沿用旧值")
 func viewModelResolvesGroupRatioByIdentityGroup() async throws {
  BalanceStubProtocol.reset()
  BalanceStubProtocol.responses["/api/user/self"] = (
   status: 200, body: Self.accountBody(group: "default")
  )
  BalanceStubProtocol.responses["/api/user/self/groups"] = (
   status: 200, body: Self.groupsBody
  )
  BalanceStubProtocol.responses[Self.tokenListStubKey] = (
   status: 200, body: Self.tokenListBody()
  )
  BalanceStubProtocol.responses["/api/status"] = (status: 200, body: Self.statusBody)

  let defaults = try isolatedDefaults()
  // 只填访问令牌：这个用例只讲分组倍率的取值口径（令牌匹配在 fail-soft 用例里钉）。
  let account = NewAPIAccount(
   label: "分组",
   config: NewAPIConfig(serverURL: "https://a.example.com", accessToken: "tok"))
  AppSettings.setNewAPIAccounts([account], defaults: defaults)

  let model = NewAPIBalanceViewModel(
   client: NewAPIBalanceClient(session: BalanceStubProtocol.session()), defaults: defaults)
  model.refresh()
  await waitUntilRefreshed(model)

  // 倍率取的是 `identity.group` 那一项，不是「表里第一项」。
  #expect(model.snapshot[account.id].identity?.group == "default")
  #expect(model.snapshot[account.id].groupRatio == 0.8)

  // 换成「身份说自己在 vip，但分组表里只有 default」：倍率如实置空——上一轮那个 0.8 属于
  // 另一个分组，是陈旧值，不该当现值继续显示。
  BalanceStubProtocol.responses["/api/user/self"] = (
   status: 200, body: Self.accountBody(group: "vip")
  )
  model.refresh()
  await waitUntilRefreshed(model)
  #expect(model.snapshot[account.id].identity?.group == "vip")
  #expect(model.snapshot[account.id].groupRatio == nil)
 }

 @MainActor
 @Test("补足信息取不到时 fail-soft：余额照旧，上一轮的分组倍率与令牌被保留")
 func supplementaryReadsFailSoft() async throws {
  BalanceStubProtocol.reset()
  BalanceStubProtocol.responses["/api/user/self"] = (
   status: 200, body: Self.accountBody(group: "default")
  )
  BalanceStubProtocol.responses["/api/usage/token/"] = (status: 200, body: Self.keyUsageBody)
  BalanceStubProtocol.responses["/api/user/self/groups"] = (
   status: 200, body: Self.groupsBody
  )
  BalanceStubProtocol.responses[Self.tokenListStubKey] = (
   status: 200, body: Self.tokenListBody()
  )
  BalanceStubProtocol.responses["/api/status"] = (status: 200, body: Self.statusBody)

  let defaults = try isolatedDefaults()
  let account = NewAPIAccount(
   label: "fail-soft",
   config: NewAPIConfig(
    serverURL: "https://a.example.com", apiKey: "sk-s7xlABCDEFGHIJn1T6",
    accessToken: "tok"))
  AppSettings.setNewAPIAccounts([account], defaults: defaults)

  let model = NewAPIBalanceViewModel(
   client: NewAPIBalanceClient(session: BalanceStubProtocol.session()), defaults: defaults)
  model.refresh()
  await waitUntilRefreshed(model)
  #expect(model.snapshot[account.id].groupRatio == 0.8)
  #expect(model.snapshot[account.id].token?.name == "ai-workspace")

  // 第二圈：分组与令牌两路都 500（老实例 404 走的是同一条 fail-soft 路径）。
  BalanceStubProtocol.responses["/api/user/self/groups"] = (status: 500, body: "")
  BalanceStubProtocol.responses[Self.tokenListStubKey] = (status: 500, body: "")
  model.refresh()
  await waitUntilRefreshed(model)

  let reading = model.snapshot[account.id]
  // 两个槽位仍是本轮新取到的 `.value`：补足信息失败不牵连余额，也不把它标成失败。
  #expect(isFresh(reading.account))
  #expect(isFresh(reading.key))
  #expect(reading.account.lastValue?.available == 987_655)
  #expect(reading.identity?.displayName == "李兴华")
  // 补足信息保留上一轮的值，而不是被清空。
  #expect(reading.groupRatio == 0.8)
  #expect(reading.token?.name == "ai-workspace")
  #expect(model.snapshot.refreshedAt != nil)
 }

 @MainActor
 @Test("请求矩阵：只填 sk- 的账号不打账户/分组/令牌三路，同一实例只查一次口径")
 func requestMatrixSkipsSupplementaryReadsWithoutIdentity() async throws {
  BalanceStubProtocol.reset()
  BalanceStubProtocol.responses["/api/usage/token/"] = (status: 200, body: Self.keyUsageBody)
  BalanceStubProtocol.responses["/api/status"] = (status: 200, body: Self.statusBody)

  let defaults = try isolatedDefaults()
  // 两个账号都只填了 `sk-`：`/api/user/self` 与由它派生的分组、令牌两路都要访问令牌，
  // 因此一个都不该发；服务器地址还写成「同一个实例的两种写法」，口径也只该查一次。
  let first = NewAPIAccount(
   label: "a", config: NewAPIConfig(serverURL: "https://a.example.com", apiKey: "sk-a"))
  let second = NewAPIAccount(
   label: "b", config: NewAPIConfig(serverURL: "https://a.example.com/", apiKey: "sk-b"))
  AppSettings.setNewAPIAccounts([first, second], defaults: defaults)

  let model = NewAPIBalanceViewModel(
   client: NewAPIBalanceClient(session: BalanceStubProtocol.session()), defaults: defaults)
  model.refresh()
  await waitUntilRefreshed(model)

  let paths = BalanceStubProtocol.requestedPaths
  #expect(paths.filter { $0 == "/api/user/self" }.isEmpty)
  #expect(paths.filter { $0 == "/api/user/self/groups" }.isEmpty)
  #expect(paths.filter { $0 == Self.tokenListStubKey }.isEmpty)
  #expect(paths.filter { $0 == "/api/usage/token/" }.count == 2)
  // 实例口径是实例级的：`https://h` 与 `https://h/` 是同一台，只查一次。
  #expect(paths.filter { $0 == "/api/status" }.count == 1)

  // 两个账号的 Key 槽都拿到数；账户槽如实说缺访问令牌（不是「未配置」，也不是「加载中」）。
  #expect(model.snapshot[first.id].key.lastValue?.available == 987_655)
  #expect(model.snapshot[second.id].key.lastValue?.available == 987_655)
  #expect(model.snapshot[first.id].account == .needsAccessToken)
  #expect(model.snapshot[first.id].identity == nil)
  #expect(model.snapshot[first.id].groupRatio == nil)
  #expect(model.snapshot[first.id].token == nil)
 }

 /// 槽位是不是本轮新取到的 `.value`（失败态里带的上一轮旧值不算）。
 private func isFresh(_ reading: NewAPIBalanceReading) -> Bool {
  if case .value = reading { return true }
  return false
 }

 /// 等一次刷新跑完（`refresh()` 内部是 Task，测试要从外部等它落地）。
 @MainActor
 private func waitUntilRefreshed(_ model: NewAPIBalanceViewModel) async {
  for _ in 0..<400 where model.isRefreshing {
   try? await Task.sleep(for: .milliseconds(5))
  }
 }
}

// MARK: - 桩会话

/// 单测用的桩会话：按路径返回预设响应体，并记下被请求过的路径。
///
/// 它替代真服务器来钉住「哪些端点被打了」——只填访问令牌时也必须打 `/api/user/self`，
/// 而 Key 槽缺 Key 就不该打 `/api/usage/token/`。状态是进程级的静态量，因此只在
/// **同一个用例**里用完即重置（并行用例共享它会互相污染）。
nonisolated final class BalanceStubProtocol: URLProtocol {
 /// 路径 → (状态码, 响应体)；未登记的路径按「连不上」处理。键用 `stubKey(of:)`。
 nonisolated(unsafe) static var responses: [String: (status: Int, body: String)] = [:]
 /// 依次记下被请求的路径（断言次数与端点都看它）。
 nonisolated(unsafe) static var requestedPaths: [String] = []

 private static let lock = NSLock()

 static func reset() {
  lock.lock()
  defer { lock.unlock() }
  responses = [:]
  requestedPaths = []
 }

 /// 带本桩的会话（配置与生产同形：ephemeral + 不落盘）。
 static func session() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [BalanceStubProtocol.self]
  return URLSession(configuration: configuration)
 }

 private static func record(_ path: String) {
  lock.lock()
  defer { lock.unlock() }
  requestedPaths.append(path)
 }

 /// 桩的键：路径 + 尾斜杠。**不能直接用 `URL.path`**——它会把尾斜杠吃掉
 /// （`/api/usage/token/` 变成 `/api/usage/token`），两个端点因此分不开。
 static func stubKey(of url: URL) -> String {
  let path = url.path
  return url.absoluteString.hasSuffix("/") ? path + "/" : path
 }

 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

 override func startLoading() {
  guard let url = request.url else { return }
  let key = Self.stubKey(of: url)
  Self.record(key)

  guard let stub = Self.responses[key] else {
   client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
   return
  }
  guard
   let response = HTTPURLResponse(
    url: url, statusCode: stub.status, httpVersion: nil,
    headerFields: ["Content-Type": "application/json"])
  else { return }

  client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
  client?.urlProtocolDidFinishLoading(self)
 }

 override func stopLoading() {}
}
