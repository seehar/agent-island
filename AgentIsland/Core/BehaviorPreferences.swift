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

    /// 选择新档位并落盘。
    func select(_ newOption: Option) {
        guard newOption != option else { return }
        option = newOption
        PreferenceStore.write(newOption, defaults: defaults)
        NotificationCenter.default.post(name: .behaviourPreferenceChanged, object: nil)
    }

    /// 展开时面板需要多出来的高度：选择行 + 微调行都由行自己定位，
    /// 这里只按档位数量给出选项块的解析高度。
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        return NotchMenuMetrics.pickerOptionsHeight(visibleOptions: Option.allCases.count)
    }
}

extension Notification.Name {
    /// 行为类偏好变化：需要按新值重算的视图（面板尺寸、空闲可见性…）据此刷新。
    static let behaviourPreferenceChanged = Notification.Name("BehaviourPreferenceChanged")
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

// MARK: - 类型别名（设置行按这个名字取用）

typealias HoverExpandSelector = EnumPreference<HoverExpand>
typealias CompletionBadgeSelector = EnumPreference<CompletionBadge>
typealias PanelSizeSelector = EnumPreference<PanelSize>
typealias IdleNotchVisibilitySelector = EnumPreference<IdleNotchVisibility>
typealias SessionRetentionSelector = EnumPreference<SessionRetention>
typealias SessionRowDensitySelector = EnumPreference<SessionRowDensity>
typealias RefreshCadenceSelector = EnumPreference<RefreshCadence>
typealias NotificationScopeSelector = EnumPreference<NotificationScope>
typealias SessionRowClickActionSelector = EnumPreference<SessionRowClickAction>
