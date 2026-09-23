//
//  GlobalHotKey.swift
//  AgentIsland
//
//  Carbon 全局热键：面板关着、应用不在前台也能触发。只给「唤出/收起」用。
//

import AppKit
import Carbon.HIToolbox
import os

/// 进程内唯一的热键回调落点。
///
/// Carbon 的 C 回调不能捕获上下文，只能经过一个全局单例转回主 actor；实例由
/// `ShortcutController` 持有（应用生命周期），这里只用弱引用定位它。
@MainActor
final class GlobalHotKeyRouter {
    static let shared = GlobalHotKeyRouter()

    weak var active: GlobalHotKey?

    func fire() {
        active?.onPressed?()
    }
}

/// 一个全局热键（同一时刻只注册一个组合）。
@MainActor
final class GlobalHotKey {
    private static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "Shortcuts")

    /// 热键身份：签名固定 'AISL'，id 固定 1（本应用只有一个全局热键）。
    private static let identity = EventHotKeyID(signature: OSType(0x4149_534C), id: 1)

    /// 触发回调（在主 actor 上调用）。
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        GlobalHotKeyRouter.shared.active = self
        installHandler()
    }

    /// 注册组合（先注销旧的，因此重复调用等价于换绑）。
    ///
    /// 返回 false = 组合非法，或已被系统/其它应用占用。调用方负责把失败暴露给用户，
    /// 不要静默吞掉——「按了没反应」比「提示注册失败」难查得多。
    @discardableResult
    func register(_ chord: KeyChord) -> Bool {
        unregister()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.keyCode),
            chord.modifiers.carbonFlags,
            Self.identity,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Self.logger.notice("全局热键注册失败：status=\(status, privacy: .public)")
            return false
        }
        hotKeyRef = ref
        return true
    }

    /// 注销当前组合（没有注册时什么都不做）。
    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    // MARK: - 事件处理器

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handler,
            1,
            &spec,
            nil,
            &handlerRef
        )
        if status != noErr {
            Self.logger.error("安装全局热键处理器失败：status=\(status, privacy: .public)")
        }
    }

    /// C 回调：不能捕获上下文，因此只把点击转回主 actor。
    private static let handler: EventHandlerUPP = { _, _, _ in
        Task { @MainActor in GlobalHotKeyRouter.shared.fire() }
        return noErr
    }
}
