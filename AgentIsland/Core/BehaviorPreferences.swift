//
//  BehaviorPreferences.swift
//  AgentIsland
//
//  行为类枚举偏好的载体。设置面板里的枚举开关（悬停展开、完成提示、面板尺寸、
//  会话保留、刷新频率…）形状完全一样——一个枚举 + 一个偏好键 + 一个行内展开状态，
//  因此不再为每个设置各写一个 selector 类：`EnumPreference<Option>` 就是那套骨架，
//  每个设置只是它的一个类型别名。
//
//  两层分工：
//   * `PreferenceStore`（nonisolated）直接在偏好域里读写——actor 与非隔离代码
//     （SessionStore、AgentSessionDiscovery）也要读这些值，不能依赖主 actor。
//   * `EnumPreference`（@MainActor）给设置行用：多一个行内展开状态，
//     展开状态只影响面板高度（见 NotchMenuMetrics）。
//  键必须保持稳定：改了键等于丢掉用户已经设过的值。
//

import Combine
import CoreGraphics
import Foundation

// MARK: - 协议与存储

/// 一个可枚举的偏好项。
nonisolated protocol PreferenceOption: RawRepresentable, CaseIterable, Hashable, Sendable
where RawValue == String {
    /// 偏好域里的键。**改名等于丢用户设置**，只能新增。
    static var preferenceKey: String { get }
    /// 用户没设过时的档位。
    static var defaultValue: Self { get }
}

/// 枚举偏好的读写（nonisolated：actor 也要用）。
nonisolated enum PreferenceStore {
    /// 读出用户设置；没设过或值已失效（例如删掉了某个档位）时回退默认档。
    static func read<Option: PreferenceOption>(
        _ type: Option.Type, defaults: UserDefaults = .standard
    ) -> Option {
        guard let raw = defaults.string(forKey: Option.preferenceKey),
            let stored = Option(rawValue: raw)
        else { return Option.defaultValue }
        return stored
    }

    static func write<Option: PreferenceOption>(
        _ option: Option, defaults: UserDefaults = .standard
    ) {
        defaults.set(option.rawValue, forKey: Option.preferenceKey)
    }
}

/// 每个档位类型一个实例的登记处。
/// 泛型类型里不能放静态存储属性，因此单例放在这里按类型查表——同一个设置
/// 在视图、行与视图模型里拿到的是同一个实例（展开状态与选中态才能同步）。
@MainActor
private final class PreferenceRegistry {
    static let shared = PreferenceRegistry()

    private var instances: [ObjectIdentifier: AnyObject] = [:]

    func instance<Option: PreferenceOption>(_ type: Option.Type) -> EnumPreference<Option> {
        let key = ObjectIdentifier(type)
        if let existing = instances[key] as? EnumPreference<Option> { return existing }
        let created = EnumPreference<Option>()
        instances[key] = created
        return created
    }
}

/// 布尔偏好 + 变更通知。
///
/// 枚举档位走 `EnumPreference`；但开关类设置（显示/隐藏某类内容）用枚举表达会变成
/// 选择行，而 macOS 的开关就该是开关。这里给 Bool 一个同级的骨架：取值同样落在偏好域，
/// 订阅它的视图会跟着重画——会话列表与对话页正是靠这一条在改开关后立刻重排。
@MainActor
final class BoolPreference: ObservableObject {
    /// 偏好域里的键。**改名等于丢用户设置**，只能新增。
    let key: String
    /// 键缺失时的取值：必须等于改造前的既有行为，否则升级会悄悄改变观感。
    let defaultValue: Bool

    @Published private(set) var isOn: Bool

    private let defaults: UserDefaults

    /// 默认读写标准偏好域；测试传独立域，避免污染真实偏好。
    init(key: String, defaultValue: Bool, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.defaults = defaults
        // 键缺失回默认值：`bool(forKey:)` 对缺失键返回 false，直接用会把默认语义翻过来。
        self.isOn = (defaults.object(forKey: key) as? Bool) ?? defaultValue
    }

    func set(_ newValue: Bool) {
        guard newValue != isOn else { return }
        isOn = newValue
        defaults.set(newValue, forKey: key)
    }

    func toggle() {
        set(!isOn)
    }
}

/// 枚举偏好 + 行内展开状态（设置行用）。
@MainActor
final class EnumPreference<Option: PreferenceOption>: ObservableObject {
    static var shared: EnumPreference<Option> { PreferenceRegistry.shared.instance(Option.self) }

    @Published private(set) var option: Option
    @Published var isPickerExpanded: Bool = false

    private let defaults: UserDefaults

    /// 默认读写标准偏好域；测试传独立域，避免污染真实偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.option = PreferenceStore.read(Option.self, defaults: defaults)
    }

    /// 选择新档位并落盘。订阅了本对象的视图会收到 `objectWillChange`，
    /// 因此不需要额外发通知（谁要按新值重算，就订阅这个选择器）。
    func select(_ newOption: Option) {
        guard newOption != option else { return }
        option = newOption
        PreferenceStore.write(newOption, defaults: defaults)
    }

    /// 展开时面板需要多出来的高度：选择行 + 微调行都由行自己定位，
    /// 这里只按档位数量给出选项块的解析高度。
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: Option.allCases.count)
    }
}

// MARK: - 悬停展开

/// 鼠标停在刘海上时是否自动展开面板，以及等多久。
nonisolated enum HoverExpand: String, PreferenceOption {
    case off
    case fast
    case standard
    case slow

    static let preferenceKey = "hoverExpand"
    static var defaultValue: HoverExpand { .standard }

    /// 自动展开延时；`off` 为 nil——只响应点击。
    var delay: TimeInterval? {
        switch self {
        case .off: return nil
        case .fast: return 0.3
        case .standard: return 1
        case .slow: return 1.5
        }
    }
}

// MARK: - 闸门问什么

/// 闸门的**适用范围**：哪些档位的工具调用要阻塞等人点按（omp / pi 的阻塞闸门）。
///
/// 档位由集成侧判定（`classifyToolCall`：`allow` = 只读/协议工具、`write` = 写类工具、
/// `exec` = 执行类、`critical` = 命中危险命令名单），应用只把这一档位烘焙进扩展文件。
/// 前两档里「只问危险命令」不是「不问」：`critical` 在那两档下永远要问，且在应用不可达时
/// 仍然拒绝。第三档「始终允许」是用户明确选择的例外：它连 `critical` 都不问——闸门在那档下
/// 等于关闭，危险命令名单不再有兜底，应用没在运行时也不阻塞。默认值不变（升级不动老用户的手感）。
nonisolated enum ApprovalAskScope: String, CaseIterable, PreferenceOption {
    /// 写档与执行档都问（默认；闸门的原始形态）。
    case writesAndExec = "all"
    /// 只问危险命令档；其余写/执行调用照跑（仍会上报，行里看得到工具在跑）。
    case criticalOnly = "critical-only"
    /// 始终允许：任何档位都不问（含危险命令）。选它即放弃闸门本身。
    case alwaysAllow = "always-allow"

    static let preferenceKey = "approvalAskScope"
    static var defaultValue: ApprovalAskScope { .writesAndExec }
}

// MARK: - 待批自动展开

/// 新的待批许可到来时，刘海要不要自己展开。
///
/// 背景（实测）：闸门版集成（omp / pi / opencode）把工具调用拦在自己手里，**终端侧不画任何
/// 提问**，刘海上的卡片是唯一入口；而「当前空间里有终端」时刘海原本不自动展开，于是用户
/// 在终端里工作就只剩关闭态的一枚小指示——工具调用会一直等到客户端预算耗尽，然后被静默
/// 拒绝。这一档默认只对「终端里没有入口」的待批生效，Claude 的体验保持不变。
nonisolated enum ApprovalAutoExpand: String, CaseIterable, PreferenceOption {
    /// 只在待批的入口就在刘海时展开（闸门类 Agent，且终端没有在问）。
    case whenTerminalIsSilent
    /// 任何待批都展开（含 Claude 的 `PermissionRequest`：终端里也有对话框）。
    case always
    /// 从不自动展开：只留关闭态的指示。
    case never

    static let preferenceKey = "approvalAutoExpand"
    static var defaultValue: ApprovalAutoExpand { .whenTerminalIsSilent }

    /// 新的待批到来时是否展开刘海。
    ///
    /// - Parameters:
    ///   - decisionOnlyOnNotch: 这批新待批里有没有「决定只能在刘海上给」的（闸门类 Agent
    ///     且终端没有在问）。
    ///   - terminalVisible: 当前空间里有没有终端的窗口。
    nonisolated func shouldExpand(decisionOnlyOnNotch: Bool, terminalVisible: Bool) -> Bool {
        switch self {
        case .never:
            return false
        case .always:
            return true
        case .whenTerminalIsSilent:
            return decisionOnlyOnNotch || !terminalVisible
        }
    }
}

// MARK: - 完成提示

/// 会话进入「就绪」后，关闭态右侧的勾与活动态保留多久。
nonisolated enum CompletionBadge: String, PreferenceOption {
    case short
    case standard
    case long
    case persistent

    static let preferenceKey = "completionBadge"
    static var defaultValue: CompletionBadge { .standard }

    /// 展示窗口；`persistent` 为 nil——一直留到会话状态变化。
    var window: TimeInterval? {
        switch self {
        case .short: return 10
        case .standard: return 30
        case .long: return 60
        case .persistent: return nil
        }
    }
}

// MARK: - 面板尺寸

/// 展开态面板的尺寸档：内容面与列表面板按比例缩放。
nonisolated enum PanelSize: String, PreferenceOption {
    case compact
    case standard
    case wide

    static let preferenceKey = "panelSize"
    static var defaultValue: PanelSize { .standard }

    /// 相对基准档的缩放比例。
    var scale: CGFloat {
        switch self {
        case .compact: return 0.88
        case .standard: return 1
        case .wide: return 1.15
        }
    }
}

// MARK: - 空闲时的胶囊

/// 没有活动时关闭态胶囊怎么表现。
nonisolated enum IdleNotchVisibility: String, PreferenceOption {
    case always
    case whenActive
    case linger

    static let preferenceKey = "idleNotchVisibility"
    static var defaultValue: IdleNotchVisibility { .whenActive }

    /// 活动结束后再留一会儿的时长；`always` 不参与（永不隐藏）。
    /// 0.5s 是改造前 `handleProcessingChange` 的硬编码值。
    var lingerWindow: TimeInterval {
        switch self {
        case .always: return 0
        case .whenActive: return 0.5
        case .linger: return 3
        }
    }

    /// 用户关掉设置面板后再收起的延时。与上面分开：改造前这条路径是 0.35s
    /// （等收起动画走完），比活动结束那条 0.5s 更急；合并成一个数会改变既有手感。
    var closeDelay: TimeInterval {
        switch self {
        case .always: return 0
        case .whenActive: return 0.35
        case .linger: return 3
        }
    }

    /// 无活动时是否隐藏（`always` 档不隐藏）。
    var hidesWhenIdle: Bool { self != .always }
}

// MARK: - 已结束会话的保留

/// 结束的会话在列表里再留多久。
nonisolated enum SessionRetention: String, PreferenceOption {
    case immediate
    case minute
    case tenMinutes
    case hour

    static let preferenceKey = "sessionRetention"
    static var defaultValue: SessionRetention { .immediate }

    var window: TimeInterval {
        switch self {
        case .immediate: return 0
        case .minute: return 60
        case .tenMinutes: return 600
        case .hour: return 3600
        }
    }

    /// 是否还有保留窗口（`immediate` 等于结束就移出）。
    var keepsEndedSessions: Bool { window > 0 }
}

// MARK: - 列表行信息密度

/// 会话列表每行显示多少信息。
nonisolated enum SessionRowDensity: String, PreferenceOption {
    case compact
    case standard
    case detailed

    static let preferenceKey = "sessionRowDensity"
    static var defaultValue: SessionRowDensity { .standard }

    /// 标题下方那一行（最后消息 / 工具名 / 状态）。
    var showsActivityLine: Bool { self != .compact }
    /// 行内 token 用量。
    var showsTokenUsage: Bool { self != .compact }
    /// 额外的第三行（工作目录）。
    var showsWorkingDirectory: Bool { self == .detailed }
}

// MARK: - 刷新频率

/// 后台轮询的频率：状态复核 + 记录目录扫描。
nonisolated enum RefreshCadence: String, PreferenceOption {
    case fast
    case standard
    case relaxed

    static let preferenceKey = "refreshCadence"
    static var defaultValue: RefreshCadence { .standard }

    /// 会话状态复核间隔（秒）。
    var statusSeconds: UInt64 {
        switch self {
        case .fast: return 1
        case .standard: return 3
        case .relaxed: return 10
        }
    }

    /// 记录目录扫描间隔（秒）。扫描会起 `ps`，因此比状态复核更慢。
    var discoverySeconds: UInt64 {
        switch self {
        case .fast: return 2
        case .standard: return 4
        case .relaxed: return 15
        }
    }
}

// MARK: - 提示音范围

/// 哪些事件会响提示音（音效本身仍由「通知音效」决定）。
nonisolated enum NotificationScope: String, PreferenceOption {
    case readyOnly
    case readyAndApprovals

    static let preferenceKey = "notificationScope"
    static var defaultValue: NotificationScope { .readyOnly }

    /// 待审批请求是否也响。
    var coversApprovals: Bool { self == .readyAndApprovals }
}

// MARK: - 单击会话行

/// 单击会话行的动作（双击始终是打开聊天）。
nonisolated enum SessionRowClickAction: String, PreferenceOption {
    case none
    case openChat
    case focusTerminal

    static let preferenceKey = "sessionRowClickAction"
    static var defaultValue: SessionRowClickAction { .none }

    /// 单击这一行该做什么；`nil` 表示什么都不做（默认档＝改造前行为）。
    /// 定位终端只对 tmux 会话有意义，其余退回打开聊天，避免点了没反应。
    func singleTapTarget(isInTmux: Bool) -> SessionRowTapTarget? {
        switch self {
        case .none: return nil
        case .openChat: return .chat
        case .focusTerminal: return isInTmux ? .terminal : .chat
        }
    }
}

/// 单击会话行的落点。
nonisolated enum SessionRowTapTarget: Equatable, Sendable {
    case chat
    case terminal
}

// MARK: - 安静时段

/// 提示音的安静时段：命中时段内不播声音（刘海与卡片照常显示，只是不出声）。
///
/// 用预设档而不是起止时间选择器：设置面板的行高与展开块高度是解析式算出来的，
/// 两个小时选择器会把展开块撑高；常用预设覆盖「晚上别吵」的诉求，代价是零新控件。
nonisolated enum QuietHours: String, PreferenceOption {
    case off
    case eveningToMorning
    case nightToMorning
    case midnightToMorning

    static let preferenceKey = "quietHours"
    static var defaultValue: QuietHours { .off }

    /// 起止时刻（从零点算的分钟数）；关闭档为 nil。允许 start > end（跨零点）。
    var minutes: (start: Int, end: Int)? {
        switch self {
        case .off: return nil
        case .eveningToMorning: return (20 * 60, 8 * 60)
        case .nightToMorning: return (22 * 60, 7 * 60)
        case .midnightToMorning: return (0, 9 * 60)
        }
    }

    /// 给定时刻是否落在安静时段内：起点含、终点不含；跨零点按「晚于起点或早于终点」判。
    nonisolated func covers(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let span = minutes else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if span.start < span.end {
            return minuteOfDay >= span.start && minuteOfDay < span.end
        }
        return minuteOfDay >= span.start || minuteOfDay < span.end
    }
}

// MARK: - 会话展示开关

/// 会话展示的布尔偏好：设置行与消费视图必须拿同一实例，否则改开关不重画。
@MainActor
enum SessionDisplayPreferences {
    /// 对话里列出子代理内部工具明细（默认开启，保持既有展示）。
    static let showSubagentDetails = BoolPreference(
        key: "showSubagentDetails", defaultValue: true)
    /// 会话列表里隐藏空闲会话（默认关闭，保持既有展示）。
    static let hideIdleSessions = BoolPreference(
        key: "hideIdleSessions", defaultValue: false)
}

// MARK: - 会话可见性

/// 结束会话保留与「隐藏闲置」共用可见性判据：先按保留档过滤结束会话，再隐藏 idle。
nonisolated enum SessionVisibility {
    static func isVisible(
        phase: SessionPhase,
        lastActivity: Date,
        retention: SessionRetention,
        hideIdleSessions: Bool,
        now: Date
    ) -> Bool {
        if phase == .ended {
            guard retention.keepsEndedSessions,
                lastActivity >= now.addingTimeInterval(-retention.window)
            else { return false }
        }
        return !hideIdleSessions || phase != .idle
    }
}

// MARK: - 类型别名（设置行按这个名字取用）

typealias ApprovalAskScopeSelector = EnumPreference<ApprovalAskScope>
typealias ApprovalAutoExpandSelector = EnumPreference<ApprovalAutoExpand>
typealias HoverExpandSelector = EnumPreference<HoverExpand>
typealias CompletionBadgeSelector = EnumPreference<CompletionBadge>
typealias PanelSizeSelector = EnumPreference<PanelSize>
typealias IdleNotchVisibilitySelector = EnumPreference<IdleNotchVisibility>
typealias SessionRetentionSelector = EnumPreference<SessionRetention>
typealias SessionRowDensitySelector = EnumPreference<SessionRowDensity>
typealias RefreshCadenceSelector = EnumPreference<RefreshCadence>
typealias NotificationScopeSelector = EnumPreference<NotificationScope>
typealias QuietHoursSelector = EnumPreference<QuietHours>
typealias SessionRowClickActionSelector = EnumPreference<SessionRowClickAction>
