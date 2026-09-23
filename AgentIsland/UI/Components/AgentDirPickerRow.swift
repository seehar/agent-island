//
//  AgentDirPickerRow.swift
//  AgentIsland
//
//  某个 Agent 配置根的**逐行展开编辑器**：自动检测 / 选择文件夹 / 恢复默认。
//  它由 `AgentSettingsSection` 的行在展开时内联渲染——主行（品牌标记 + 名称 +
//  集成状态 + 尾部控件）仍归那一行所有，这里只管「这个 Agent 读哪个目录」。
//
//  为什么固定三行：卡片可视窗口的高度由 `NotchMenuMetrics.agentCardLayout(total:directoryEditorHeight:)`
//  按 `AgentDirSelector.visibleOptions` 算，行数若随状态变化（例如未自定义时把
//  「恢复默认」藏起来），窗口就会比内容高出一截，面板底部的分组被顶出可视区。
//  因此不可用的档位只置灰，不隐藏。
//

import AppKit
import SwiftUI

struct AgentDirPickerRow: View {
    /// 这一行所属的 Agent：决定默认目录、记录的落点与选择面板的文案。
    let kind: AgentKind
    /// 用户指定的配置目录（绝对路径）；nil / 空 = 自动检测。
    let customDirectory: String?
    /// 目录改完后的回调：行副标题、选中态与窗口高度都读同一份状态，父视图据此重读。
    let onChange: () -> Void

    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsOptionRow(
                label: l10n.t("Auto-detect"),
                detail: isCustom ? nil : resolvedPath,
                isSelected: !isCustom
            ) {
                apply(nil)
            }

            SettingsOptionRow(
                label: l10n.t("Choose folder…"),
                detail: isCustom ? shortenedPath(customDirectory ?? "") : nil,
                isSelected: isCustom
            ) {
                openFolderPicker()
            }

            // 未自定义时置灰（而不是隐藏）：高度必须恒定，见文件头注释。
            SettingsOptionRow(
                label: l10n.t("Reset to Default"),
                isSelected: false
            ) {
                apply(nil)
            }
            .disabled(!isCustom)
            .opacity(isCustom ? 1 : 0.4)
        }
        // 与 `SettingsPickerRow` 的展开块同一套几何：总高因此正好等于
        // `NotchMenuMetrics.pickerOptionsHeight(visibleOptions: 3)`。
        .padding(.top, NotchMenuMetrics.optionListTopPadding)
        .padding(.bottom, NotchMenuMetrics.optionListBottomPadding)
        .padding(.leading, NotchMenuMetrics.optionIndent)
    }

    // MARK: - 表现

    private var isCustom: Bool {
        !(customDirectory ?? "").isEmpty
    }

    /// 「自动检测」实际解析到哪：不自定义时它就是该 Agent 的默认配置目录
    /// （有自定义时这一档的说明留空——同一串路径已经显示在「选择文件夹」那一行，
    /// 两行并排同一串路径只会让人以为点错了）。
    private var resolvedPath: String {
        guard let dir = kind.directoryOverrideRoot() else { return "" }
        return shortenedPath(dir.path)
    }

    /// 首页目录下的路径压缩成 `~/…`，避免长路径挤掉选项行的标签。
    private func shortenedPath(_ raw: String) -> String {
        let path = raw.hasPrefix("/") ? raw : NSHomeDirectory() + "/" + raw
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - 动作

    /// 选择面板的起始目录：当前生效的那一个（有自定义目录时就是它）。
    private var currentDirectory: URL {
        if let customDirectory, !customDirectory.isEmpty {
            return URL(fileURLWithPath: (customDirectory as NSString).expandingTildeInPath)
        }
        return kind.directoryOverrideRoot()
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = l10n.t("Choose Config Directory")
        panel.message = l10n.t(
            "Select the folder %@ uses for its config and session records.", kind.displayName)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        panel.directoryURL = currentDirectory

        // 刘海面板在 .mainMenu + 3，会盖住选择面板：弹窗期间把它降回普通层并让出鼠标。
        let response = withNotchPanelYielded { panel.runModal() }

        if response == .OK, let url = panel.url {
            apply(url.path)
        }
    }

    /// 写回选择：nil / 空 = 恢复自动检测。
    ///
    /// 写入的是逐 Agent 的配置根覆盖，各 Provider 下次解析时就能读到（Claude 的目录有
    /// 跨线程缓存，`AppSettings.setAgentRootOverride` 里已经随之失效）。
    private func apply(_ path: String?) {
        AppSettings.setAgentRootOverride(kind, path: path)

        // 目录换了，集成还留在旧目录里：已启用的 Agent 立刻按新目录重装一次。
        // 否则行内会马上显示「未安装」，实时事件也就断了（用户会以为改目录把集成弄坏了）。
        if AppSettings.isAgentEnabled(kind) {
            AgentIntegrationInstaller.install(kind)
        }

        onChange()
    }
}