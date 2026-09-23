//
//  OmpConfigInstaller.swift
//  AgentIsland
//
//  闸门需要的 omp 配置写入器：只写 `extensionHandlers.toolCallTimeoutMs` 一个键。
//
//  为什么需要：omp 的扩展 handler 预算是 **active-work 30s**。用户在刘海上犹豫超过
//  30 秒，omp 会自己 fail-closed（`Extension ... timed out after 30000ms`），用户看到的
//  是一次没有理由的工具失败。把预算抬到 5 分钟，让「客户端 120s 超时」成为唯一裁决者
//  ——超时理由因此可读（说明是刘海没响应），而不是 omp 的通用超时串。
//
//  纪律：
//    - 用 omp 自己的写入口（`omp config set`）做 **merge 写**，绝不自己拼 YAML；
//    - 写前备份（同目录、权限一致）、写后校验读回值，任一步失败即回滚；
//    - **绝不写** `tools.approvalMode`：它的默认值已经是 yolo，写它只会留痕，
//      而且会把用户显式选择过的限制模式静默抹掉。
//
//  抬上去的预算**不会自动还原**（闸门随启用而来，没有「关掉闸门」这个动作了）。
//  原因是还原是「整份写回备份」：用户在这之后用 `omp config set` 改过配置时，还原会把
//  那些改动一起抹掉。备份文件 `config.yml.agent-island.bak` 留给用户手动恢复，原值也记在
//  偏好域（`ompGateConfig*`）里供排查。
//

import Foundation
import os.log

nonisolated enum OmpConfigInstaller {
    private static let logger = Logger(
        subsystem: "com.celestial.AgentIsland", category: "OmpConfig")

    /// 要写的键与目标值：把 handler 预算抬到 5 分钟（原值通常是 30000）。
    private static let timeoutKey = "extensionHandlers.toolCallTimeoutMs"
    static let gateHandlerTimeoutMs = 300_000

    /// 备份文件与 `config.yml` 同目录，沿用既有 `.agent-island.bak` 命名。
    private static let backupFileName = "config.yml.agent-island.bak"

    /// 写入失败的原因；都带可读描述，界面直接用它的 `errorDescription`。
    enum Failure: LocalizedError {
        /// 目标配置文件不存在（用户没装 omp，或配置目录被挪走）。
        case configMissing(String)
        /// 找不到 omp 可执行文件（GUI 环境的 PATH 与用户 shell 不同）。
        case executableMissing
        case backupFailed(String)
        case writeFailed(String)
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .configMissing(let path):
                return "找不到 omp 配置文件：\(path)"
            case .executableMissing:
                return "找不到 omp 可执行文件"
            case .backupFailed(let reason):
                return "备份 omp 配置失败：\(reason)"
            case .writeFailed(let reason):
                return "写入 omp 配置失败：\(reason)"
            case .verifyFailed(let reason):
                return "校验 omp 配置失败：\(reason)"
            }
        }
    }

    // MARK: - 路径

    /// omp 的 `config.yml`。
    static func configFile() -> URL? {
        AgentRegistry.provider(for: .ohMyPi).paths()?
            .configDir
            .appendingPathComponent("config.yml")
    }

    /// omp 可执行文件。
    ///
    /// GUI 进程的 PATH 往往不含用户 shell 的 bin 目录（本机 omp 在 `~/.bun/bin`），
    /// 因此先探常见位置，再退回问用户的登录 shell（`zsh -lc 'command -v omp'`）。
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".bun/bin/omp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/omp"),
            URL(fileURLWithPath: "/usr/local/bin/omp"),
            home.appendingPathComponent(".local/bin/omp"),
        ]
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return found
        }
        guard let output = capture("/bin/zsh", ["-lc", "command -v omp"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - 读写

    /// 读回当前生效的 handler 预算（拿不到时返回 nil）。
    static func readConfiguredTimeout() -> String? {
        guard let config = configFile(), let omp = executable() else { return nil }
        return readTimeout(executable: omp, config: config)
    }

    /// 抬 handler 预算：把 `extensionHandlers.toolCallTimeoutMs` 设成 5 分钟。
    ///
    /// 它由安装器在装闸门版扩展时调用（见 `AgentIntegrationInstaller.install`），因此
    /// 「omp 被监控」就等于这一步跑过。任一步失败即从备份还原并把错误抛给调用方。
    static func applyGateTimeout() throws {
        guard let config = configFile() else { throw Failure.executableMissing }
        guard FileManager.default.fileExists(atPath: config.path) else {
            throw Failure.configMissing(config.path)
        }
        guard let omp = executable() else { throw Failure.executableMissing }

        let original = readTimeout(executable: omp, config: config)

        // 备份：已经备份过就沿用（它保存的是最初的原值），否则现在做一个。
        let backup = try backupIfNeeded(config)

        // 已经是目标值：不必再动用户文件（可能是上次开启留下的，也可能用户自己设过）。
        if original == String(gateHandlerTimeoutMs) {
            record(original: original, backup: backup)
            logger.notice("omp handler 预算已是目标值，未改写配置")
            return
        }

        do {
            try writeTimeout(executable: omp, config: config)
            let readBack = readTimeout(executable: omp, config: config)
            guard readBack == String(gateHandlerTimeoutMs) else {
                throw Failure.verifyFailed("读回值不是 \(gateHandlerTimeoutMs)（得到 \(readBack ?? "空")）")
            }
        } catch {
            // 回滚：把备份内容写回去，并清掉这次留下的记录。
            _ = restore(from: backup, to: config)
            AppSettings.ompGateConfigBackupPath = nil
            AppSettings.ompGateConfigOriginalTimeout = nil
            AppSettings.ompGateConfigAppliedAt = nil
            logger.error("写 omp 配置失败已回滚：\(String(describing: error), privacy: .public)")
            throw error
        }

        record(original: original, backup: backup)
    }

    // MARK: - 记录

    private static func record(original: String?, backup: URL) {
        AppSettings.ompGateConfigBackupPath = backup.path
        AppSettings.ompGateConfigOriginalTimeout = original
        AppSettings.ompGateConfigAppliedAt = Date()
        AppSettings.ompGateTimeoutSetupFailed = false
    }

    // MARK: - 备份 / 回滚

    /// 已有备份就不覆盖（它保存的是最初的原值），否则复制一份并沿用原文件权限。
    private static func backupIfNeeded(_ config: URL) throws -> URL {
        let backup = config.deletingLastPathComponent().appendingPathComponent(backupFileName)
        if FileManager.default.fileExists(atPath: backup.path) {
            return backup
        }
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: config.path))?[.posixPermissions]
        do {
            try fm.copyItem(at: config, to: backup)
            if let permissions {
                try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: backup.path)
            }
        } catch {
            throw Failure.backupFailed(error.localizedDescription)
        }
        return backup
    }

    /// 用备份覆盖目标文件；成功返回 true。
    private static func restore(from backup: URL, to config: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: config.path) {
                try fm.removeItem(at: config)
            }
            try fm.copyItem(at: backup, to: config)
            return true
        } catch {
            logger.error("还原 omp 配置失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - omp 调用

    /// 读一个键；失败返回 nil（拿不到就当没有原值，不影响写入与校验）。
    private static func readTimeout(executable: URL, config: URL) -> String? {
        guard let output = try? run(executable, ["config", "get", timeoutKey], config: config)
        else {
            return nil
        }
        // `omp config get` 的形态是 `30000` 或 `30000 (number)`，取首个数字段即可。
        guard let value = output.split(whereSeparator: { !$0.isNumber }).first else { return nil }
        return String(value)
    }

    /// merge 写一个键；非 0 退出即失败（**不**降级成自己写文件）。
    private static func writeTimeout(executable: URL, config: URL) throws {
        do {
            _ = try run(
                executable,
                ["config", "set", timeoutKey, String(gateHandlerTimeoutMs)],
                config: config
            )
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String], config: URL) throws -> String
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(for: config)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // 先读完再等退出：写满管道会让子进程阻塞在写、而我们阻塞在等退出。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.writeFailed(
                "omp \(arguments.joined(separator: " ")) 退出码 \(process.terminationStatus)：\(detail)"
            )
        }
        return output
    }

    /// 只读执行一个命令并返回 stdout（失败返回 nil）。
    private static func capture(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 子进程环境：补上 PATH（GUI 进程的 PATH 很短）与 `HOME`；配置目录不是默认位置时
    /// 显式告诉 omp（否则它会去写默认目录）。
    private static func environment(for config: URL) -> [String: String] {
        // 仓库自带一个 `ProcessInfo`（进程树），这里要的是 Foundation 的那个。
        var env = Foundation.ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home

        let extra = [
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var seen = Set<String>()
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (existing + extra).filter { seen.insert($0).inserted }.joined(separator: ":")

        let configDir = config.deletingLastPathComponent().path
        if configDir != "\(home)/.omp/agent" {
            env["PI_CODING_AGENT_DIR"] = configDir
        }
        return env
    }
}
