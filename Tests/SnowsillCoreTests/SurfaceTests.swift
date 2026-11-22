import XCTest
@testable import SnowsillCore

final class SurfaceTests: XCTestCase {
    func testDepositAddsVolumeAndRespectsCap() {
        let s = Surface(id: 1, kind: .window, minX: 0, top: 100, width: 100, maxHeight: 10)
        let kept = s.deposit(x: 50, volume: 8)
        XCTAssertEqual(kept, 8, accuracy: 0.001)
        XCTAssertEqual(s.volume, 8, accuracy: 0.001)
        for _ in 0..<200 { s.deposit(x: 50, volume: 8) }
        XCTAssertLessThanOrEqual(s.heights.max()!, 10.0001)
    }

    func testRelaxConservesVolumeAndSheds() {
        let s = Surface(id: 1, kind: .window, minX: 0, top: 100, width: 40, maxHeight: 100)
        s.heights[10] = 400
        let before = s.volume
        for _ in 0..<400 { s.relax(maxStep: 1.1) }
        let after = s.volume + s.overflowLeft + s.overflowRight
        XCTAssertEqual(before, after, accuracy: 0.01)
        XCTAssertGreaterThan(s.overflowLeft + s.overflowRight, 0, "a tall spike on a narrow ledge must shed")
        for i in 0..<(s.cellCount - 1) {
            XCTAssertLessThanOrEqual(abs(s.heights[i] - s.heights[i + 1]), 1.2 + 0.3)
        }
    }

    func testGroundIsWalledAndKeepsSnow() {
        let s = Surface(id: -2000, kind: .ground, minX: 0, top: 1000, width: 20, maxHeight: 100)
        s.heights[0] = 30
        for _ in 0..<300 { s.relax(maxStep: 1.3) }
        XCTAssertEqual(s.overflowLeft + s.overflowRight, 0)
        XCTAssertEqual(s.volume, 60, accuracy: 0.01)
    }

    func testCarveRemovesSnowUnderPointer() {
        let s = Surface(id: 1, kind: .window, minX: 0, top: 100, width: 200, maxHeight: 20)
        for i in s.heights.indices { s.heights[i] = 10 }
        let removed = s.carve(cx: 100, cy: 92, r: 10)
        XCTAssertFalse(removed.isEmpty)
        XCTAssertLessThan(s.height(atX: 100), 1)
        XCTAssertEqual(s.height(atX: 20), 10, accuracy: 0.001, "far from the pointer is untouched")
        let total = removed.reduce(0) { $0 + $1.volume }
        XCTAssertEqual(total + s.volume, 2000, accuracy: 0.5, "carved snow is accounted for")
    }

    func testCarveAbovePileDoesNothing() {
        let s = Surface(id: 1, kind: .window, minX: 0, top: 100, width: 200, maxHeight: 20)
        for i in s.heights.indices { s.heights[i] = 5 }
        XCTAssertTrue(s.carve(cx: 100, cy: 60, r: 10).isEmpty)
    }

    func testResizeKeepsAnchoredSideAndSpillsTheRest() {
        let s = Surface(id: 1, kind: .window, minX: 0, top: 100, width: 100, maxHeight: 20)
        for i in s.heights.indices { s.heights[i] = Float(i) }
        let spilled = s.resize(minX: 0, width: 60)
        XCTAssertEqual(s.cellCount, 30)
        XCTAssertEqual(s.heights[29], 29)
        XCTAssertEqual(spilled.count, 20)
        XCTAssertTrue(spilled.allSatisfy { $0.x >= 60 })
    }

    func testCenteredResize() {
        let s = Surface(id: 1, kind: .dock, minX: 100, top: 900, width: 100, maxHeight: 20)
        s.heights[25] = 7
        _ = s.resize(minX: 90, width: 120, anchor: .center)
        XCTAssertEqual(s.cellCount, 60)
        XCTAssertEqual(s.heights[30], 7)
    }

    func testCornerDropFollowsRoundedCorner() {
        let s = Surface(id: 1, kind: .window, minX: 0, top: 100, width: 300, cornerRadius: 12)
        XCTAssertEqual(s.cornerDrop(atX: 150), 0)
        XCTAssertEqual(s.cornerDrop(atX: 0), 12, accuracy: 0.01)
        XCTAssertGreaterThan(s.cornerDrop(atX: 3), s.cornerDrop(atX: 8))
    }

    func testScrape() {
        let s = Surface(id: -2000, kind: .ground, minX: 0, top: 1000, width: 100, maxHeight: 30)
        for i in s.heights.indices { s.heights[i] = 4 }
        let v = s.scrape(from: 20, to: 60)
        XCTAssertEqual(v, 160, accuracy: 0.01)
        XCTAssertEqual(s.height(atX: 41), 0)
        XCTAssertEqual(s.height(atX: 81), 4)
    }
}
