//
//  NewAPIAccountPageState.swift
//  AgentIsland
//
//  「额度」页的**运行时状态**：账号列表的窗口行数（= 账号个数，封顶
//  `NotchMenuMetrics.visibleAccountRows`）与「编辑凭据」模式。
//
//  与其它选择器只有一个共同点：都参与面板高度解析式。区别在于这里没有「选择」可言——
//  账号个数是运行时才知道的（用户增删），静态版面表里因此**没有**账号行；这一份运行时
//  增量由视图在账号增删 / 切换编辑态时写回，`NotchViewModel` 按它撑高面板
//  （见 `expandedPickerHeight(for: .quota)`）。
//
//  面板高度必须可解析：超出窗口行数的账号在列表里滚动；编辑态把列表折叠成被编辑的那
//  一行（两个运行时项因此不会叠加，最坏组合仍在上限内，见 `NotchMenuMetricsTests`）。
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class NewAPIAccountPageState: ObservableObject {
    static let shared = NewAPIAccountPageState()

    // MARK: - 状态

    /// 账号列表的窗口行数（1…`visibleAccountRows`），由视图在账号增删时写回。
    @Published private(set) var visibleAccountRowCount = 1

    /// 是否在编辑凭据。编辑态下列表折叠成一行、详情卡的基准行换成凭据表单。
    @Published var isEditingCredentials = false

    /// 详情卡里**可选行**的行数（0…`quotaDetailOptionalRowsMax`）：身份行与密钥额度行。
    ///
    /// 「拿不到数据的就不展示」——平台只给 `sk-` 时没有账号数据、只给访问令牌时没有密钥
    /// 额度，对应那一行整行不画；行数因此随选中账号的读数变化，由视图在读数刷新时写回
    /// （见 `QuotaSettingsPage.updateOptionalDetailRowCount`）。
    @Published private(set) var optionalDetailRowCount = 0

    private init() {}

    // MARK: - 写入

    /// 账号数量变化时写回窗口行数（至少 1 行：页面永远留着一个可编辑的账号）。
    func setAccountCount(_ count: Int) {
        let visible = max(1, min(count, NotchMenuMetrics.visibleAccountRows))
        guard visible != visibleAccountRowCount else { return }
        visibleAccountRowCount = visible
    }

    /// 详情卡可选行数变化时写回（面板高度按它算）。
    func setOptionalDetailRowCount(_ count: Int) {
        let clamped = max(0, min(count, NotchMenuMetrics.quotaDetailOptionalRowsMax))
        guard clamped != optionalDetailRowCount else { return }
        optionalDetailRowCount = clamped
    }

    // MARK: - 高度

    /// 额度页相对静态版面表的运行时增量。
    ///
    /// - 读数态：账号列表窗口（`visibleAccountRowCount` 行）+ 详情卡的可选行
    ///   （`optionalDetailRowCount` 行）；
    /// - 编辑态：列表折叠成被编辑的那一行 + 详情卡的基准行被凭据表单替换
    ///   （`credentialFormHeight − quotaDetailHeight`）。
    var runtimeHeight: CGFloat {
        if isEditingCredentials { return Self.editingRuntimeHeight }
        return Self.accountListHeight(rows: visibleAccountRowCount)
            + Self.detailOptionalHeight(rows: optionalDetailRowCount)
    }

    /// 账号列表窗口的高度（`rows` 行）。
    nonisolated static func accountListHeight(rows: Int) -> CGFloat {
        NotchMenuMetrics.twoLineRowHeight * CGFloat(rows)
    }

    /// 详情卡可选行的高度（`rows` 行，夹在 0…上限）。
    nonisolated static func detailOptionalHeight(rows: Int) -> CGFloat {
        let clamped = max(0, min(rows, NotchMenuMetrics.quotaDetailOptionalRowsMax))
        return NotchMenuMetrics.twoLineRowHeight * CGFloat(clamped)
    }

    /// 编辑态的运行时增量：一行账号 + 凭据表单与基准行的差。
    nonisolated static var editingRuntimeHeight: CGFloat {
        NotchMenuMetrics.twoLineRowHeight
            + (NotchMenuMetrics.credentialFormHeight - NotchMenuMetrics.quotaDetailHeight)
    }

    /// 最坏情况下的运行时增量（读数态满窗口 + 可选行全在 vs 编辑态）。
    ///
    /// 生产代码里两段是**互斥**的（编辑态折叠列表、也不画可选行），因此高度守卫用例按
    /// 这个值核对「内容 + 该页最高的单个展开 + chrome ≤ 728」（见 `NotchMenuMetricsTests`）。
    nonisolated static var worstRuntimeHeight: CGFloat {
        max(
            Self.accountListHeight(rows: NotchMenuMetrics.visibleAccountRows)
                + Self.detailOptionalHeight(rows: NotchMenuMetrics.quotaDetailOptionalRowsMax),
            Self.editingRuntimeHeight)
    }
}
