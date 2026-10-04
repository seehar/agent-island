//
//  PointerInterestBandTests.swift
//  AgentIslandTests
//
//  指针位置流的发布判据：只有「跨进 / 跨出兴趣区」才发（见 `EventMonitors.interestRect`）。
//
//  背景：这条流原先每个鼠标移动事件都发一次（全局监听 → Combine → 两个订阅者），现在压成
//  边界事件。少发一次 = 悬停不展开、面板该收鼠标事件时没收；多发一次 = 回到原来的每事件
//  成本。两个方向都是用户可见的，因此判据本身（纯函数）钉在这里，不依赖真实指针位置。
//

import CoreGraphics
import Testing

@testable import AgentIsland

@Suite("指针兴趣区边界事件")
struct PointerInterestBandTests {
  private let band = CGRect(x: 0, y: 0, width: 100, height: 20)

  @Test("未接线（nil）时保持旧语义：每次都发")
  func unboundBandPublishesEveryEvent() {
    let outcome = EventMonitors.shouldPublish(
      interestRect: nil, wasInside: false, at: CGPoint(x: 999, y: 999))
    #expect(outcome.publish)
  }

  @Test("跨进发一次")
  func enteringPublishes() {
    let outcome = EventMonitors.shouldPublish(
      interestRect: band, wasInside: false, at: CGPoint(x: 50, y: 10))
    #expect(outcome.publish)
    #expect(outcome.isInside)
  }

  @Test("区内继续移动不发")
  func movingInsideStaysSilent() {
    let outcome = EventMonitors.shouldPublish(
      interestRect: band, wasInside: true, at: CGPoint(x: 80, y: 18))
    #expect(outcome.publish == false)
    #expect(outcome.isInside)
  }

  @Test("跨出发一次")
  func leavingPublishes() {
    let outcome = EventMonitors.shouldPublish(
      interestRect: band, wasInside: true, at: CGPoint(x: 400, y: 10))
    #expect(outcome.publish)
    #expect(outcome.isInside == false)
  }

  @Test("区外继续移动不发")
  func movingOutsideStaysSilent() {
    let outcome = EventMonitors.shouldPublish(
      interestRect: band, wasInside: false, at: CGPoint(x: 400, y: 10))
    #expect(outcome.publish == false)
    #expect(outcome.isInside == false)
  }

  @Test("兴趣区换了一块（面板收起 / 展开、胶囊变宽）后按新矩形的在否重判")
  func rebasedBandReEvaluates() {
    // 指针没动、还停在旧矩形里；换成新矩形后它已经在外面 ⇒ 必须补发一次，否则
    // 「面板刚收起、指针明明已不在卡片里」这一段会一直被认为还在区内。
    let moved = CGRect(x: 500, y: 0, width: 100, height: 20)
    let outcome = EventMonitors.shouldPublish(
      interestRect: moved, wasInside: true, at: CGPoint(x: 50, y: 10))
    #expect(outcome.publish)
    #expect(outcome.isInside == false)
  }
}
