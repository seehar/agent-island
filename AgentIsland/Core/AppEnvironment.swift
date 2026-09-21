//
//  AppEnvironment.swift
//  AgentIsland
//
//  运行环境判定：把「是不是跑在单元测试宿主里」这类问题收敛到一处——AppDelegate 的单实例
//  守卫与 HookSocketServer 的 socket 归属都要用它。
//

import Foundation

/// 进程级运行环境判定。
nonisolated enum AppEnvironment {
    /// 是否运行在 `xcodebuild test` 的宿主里。
    ///
    /// 测试宿主与用户正在运行的应用 bundle id 完全相同，因此两件事必须按它分流：单实例守卫
    /// 放行（否则整轮测试会因宿主被终止而失败），**socket 服务不启动**（否则它会 unlink +
    /// rebind 抢走用户那条 `/tmp/agent-island.sock`，让真实应用静默聋掉——闸门请求此后只能
    /// 等到客户端预算耗尽然后被拒）。
    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Foundation.ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }
}
