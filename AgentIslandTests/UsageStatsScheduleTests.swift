//
//  UsageStatsScheduleTests.swift
//  AgentIslandTests
//
//  用量索引的兜底排程判据：间隔按统计页可见性取档。
//
//  这是「常驻 CPU」那批改动的承重墙：改动前是固定每 60 秒一轮，而每轮都要把各 Agent 的
//  记录根整棵枚举一遍（本机 6.2k 个源、枚举 0.25~0.76 s）再扫一遍 OpenCode 库（3.4 GB，
//  2.3~2.5 s），页面没人看也照跑。现在不可见时降到 10 分钟一档。
//

import Foundation
import Testing

@testable import AgentIsland

@Suite("用量统计排程")
struct UsageStatsScheduleTests {
  @Test("兜底间隔按可见性取档")
  func sweepIntervalByVisibility() {
    #expect(UsageStatsIndexer.sweepIntervalSeconds(uiVisible: true) == 60)
    #expect(UsageStatsIndexer.sweepIntervalSeconds(uiVisible: false) == 600)
  }

  @Test("不可见档必须比可见档长——它就是这个改动的全部收益")
  func hiddenIsTheCheapTier() {
    #expect(
      UsageStatsIndexer.sweepIntervalSeconds(uiVisible: false)
        > UsageStatsIndexer.sweepIntervalSeconds(uiVisible: true))
  }

  @Test("没跑过就一定跑（首次启动 / 页面打开后的第一轮）")
  func runsWhenNeverRun() {
    #expect(UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: nil, uiVisible: false))
    #expect(UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: nil, uiVisible: true))
  }

  @Test("可见档：不到 60 秒不跑，到了就跑")
  func visibleFallback() {
    #expect(
      UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: 59, uiVisible: true) == false)
    #expect(UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: 60, uiVisible: true))
  }

  @Test("不可见档：上一轮刚过去的一两分钟内不跑（常驻成本收在这里）")
  func hiddenFallback() {
    #expect(
      UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: 59, uiVisible: false) == false)
    #expect(
      UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: 120, uiVisible: false) == false)
    #expect(UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: 600, uiVisible: false))
  }

  @Test("同一时刻只按当前档位判：120 秒在可见档跑、在不可见档不跑")
  func tierDecidesAlone() {
    #expect(UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: 120, uiVisible: true))
    #expect(
      UsageStatsIndexer.shouldRunPass(secondsSinceLastPass: 120, uiVisible: false) == false)
  }
}
