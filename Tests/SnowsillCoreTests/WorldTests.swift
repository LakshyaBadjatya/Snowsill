import XCTest
@testable import SnowsillCore

final class WorldTests: XCTestCase {
    let screen = ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080),
                            dock: Rect(x: 500, y: 990, w: 920, h: 90))

    func makeWorld() -> World {
        let w = World()
        w.setScreens([screen])
        return w
    }

    func run(_ w: World, seconds: Float) {
        var t: Float = 0
        while t < seconds { w.step(dt: 1.0 / 60); t += 1.0 / 60 }
    }

    func testSnowPilesOnWindowTopsDockAndGround() {
        let w = makeWorld()
        w.params.intensity = 1
        w.params.pileBoost = 4
        w.params.melt = 0
        w.setWindows([WindowInfo(id: 7, frame: Rect(x: 200, y: 300, w: 800, h: 400))], offscreenAlive: [])
        run(w, seconds: 40)
        let win = w.surfaces.first { $0.id == 7 }!
        XCTAssertGreaterThan(win.volume, 500)
        XCTAssertTrue(w.surfaces.contains { $0.kind == .dock && $0.volume > 100 })
        XCTAssertTrue(w.surfaces.contains { $0.kind == .ground && $0.volume > 100 })
    }

    func testOccludedLedgeGetsNoSnow() {
        let w = makeWorld()
        w.params.intensity = 1
        w.params.pileBoost = 4
        w.params.melt = 0
        // Front window (first) completely covers the back window's top edge.
        w.setWindows([
            WindowInfo(id: 1, frame: Rect(x: 100, y: 200, w: 900, h: 600)),
            WindowInfo(id: 2, frame: Rect(x: 300, y: 400, w: 400, h: 300)),
        ], offscreenAlive: [])
        run(w, seconds: 20)
        XCTAssertEqual(w.surfaces.first { $0.id == 2 }!.volume, 0)
        XCTAssertGreaterThan(w.surfaces.first { $0.id == 1 }!.volume, 0)
    }

    func testMovingWindowShedsSnow() {
        let w = makeWorld()
        let f = Rect(x: 200, y: 300, w: 800, h: 400)
        w.setWindows([WindowInfo(id: 7, frame: f)], offscreenAlive: [])
        let s = w.surfaces.first { $0.id == 7 }!
        for i in s.heights.indices { s.heights[i] = 8 }
        w.params.precipitation = .none
        w.step(dt: 1.0 / 60)
        var moved = f; moved.x += 120
        w.setWindows([WindowInfo(id: 7, frame: moved)], offscreenAlive: [])
        XCTAssertEqual(s.volume, 0)
        XCTAssertGreaterThan(w.particles.count(of: .clump), 50)
    }

    func testMinimizedWindowKeepsSnowAndRestores() {
        let w = makeWorld()
        let f = Rect(x: 200, y: 300, w: 800, h: 400)
        w.setWindows([WindowInfo(id: 7, frame: f)], offscreenAlive: [])
        let s = w.surfaces.first { $0.id == 7 }!
        for i in s.heights.indices { s.heights[i] = 6 }
        w.setWindows([], offscreenAlive: [7])
        XCTAssertNil(w.surfaces.first { $0.id == 7 })
        XCTAssertEqual(w.particles.count, 0, "minimizing is silent")
        w.setWindows([WindowInfo(id: 7, frame: f)], offscreenAlive: [])
        XCTAssertEqual(w.surfaces.first { $0.id == 7 }!.volume, 6 * 800, accuracy: 1)
    }

    func testClosedWindowDropsAndMeltsAway() {
        let w = makeWorld()
        w.params.precipitation = .none
        w.setWindows([WindowInfo(id: 7, frame: Rect(x: 200, y: 300, w: 800, h: 400))], offscreenAlive: [])
        let s = w.surfaces.first { $0.id == 7 }!
        for i in s.heights.indices { s.heights[i] = 6 }
        w.setWindows([], offscreenAlive: [])
        XCTAssertGreaterThan(w.particles.count(of: .clump), 0)
        run(w, seconds: 2)
        XCTAssertNil(w.surfaces.first { $0.id == 7 })
    }

    func testPlowClearsGroundAndPushesSnowOffScreen() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.precipitation = .none
        let ground = w.surfaces.first { $0.kind == .ground }!
        for i in ground.heights.indices { ground.heights[i] = 10 }
        w.plow.spawn(screenIndex: 0, world: w)
        run(w, seconds: 4)
        XCTAssertEqual(w.plow.state, .parked)
        // Click: plows toward the far side.
        w.plow.beginDrag(pointerX: 100, time: w.time)
        w.plow.endDrag(time: w.time, world: w)
        XCTAssertEqual(w.plow.state, .plowing)
        var spilled = 0
        for _ in 0..<(60 * 5) {
            w.step(dt: 1.0 / 60)
            spilled = max(spilled, w.particles.count(of: .spill))
        }
        XCTAssertGreaterThan(spilled, 20, "snow pours off the screen edge")
        // Everything ahead of where it parked is clear.
        let parkedEnd = 22 + w.plow.length
        let remaining = ground.heights.indices.filter { ground.cellCenter($0) > parkedEnd + 60 }.map { ground.heights[$0] }
        XCTAssertLessThan(remaining.max() ?? 0, 0.5)
        XCTAssertTrue([.returning, .parked, .waiting].contains(w.plow.state))
    }

    func testSwipeLeftPlowsLeft() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.precipitation = .none
        w.plow.spawn(screenIndex: 0, world: w)
        run(w, seconds: 4)
        w.plow.beginDrag(pointerX: 100, time: 0)
        w.plow.drag(pointerX: 80, time: 0.02, world: w)
        w.plow.drag(pointerX: 40, time: 0.05, world: w)
        w.plow.endDrag(time: 0.05, world: w)
        XCTAssertEqual(w.plow.state, .plowing)
        XCTAssertEqual(w.plow.facing, -1)
    }

    func testWeatherMapping() {
        let s = WeatherState.fromOpenMeteo(code: 75, windKmh: 45, windDirection: 270)
        XCTAssertEqual(s.precipitation, .snow)
        XCTAssertEqual(s.wind, 1, accuracy: 0.01, "west wind blows to screen-right")
        XCTAssertEqual(WeatherState.fromOpenMeteo(code: 63, windKmh: 0, windDirection: 0).precipitation, .rain)
        XCTAssertGreaterThan(WeatherState.fromOpenMeteo(code: 45, windKmh: 0, windDirection: 0).fog, 0.5)
        XCTAssertEqual(WeatherState.fromOpenMeteo(code: 0, windKmh: 0, windDirection: 0).precipitation, .none)
    }

    func testDockEstimate() {
        let d = DockGeometry.estimate(inset: 64, items: 20, separators: 1, screenWidth: 1920)!
        XCTAssertEqual(d.width, 938, accuracy: 15)
        XCTAssertNil(DockGeometry.estimate(inset: 4, items: 20, separators: 1, screenWidth: 1920))
    }
}

final class PlowAutoTests: XCTestCase {
    func testAutoPlowClearsWholeBottomAndLeaves() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080),
                                 dock: Rect(x: 228, y: 994, w: 1464, h: 86))])
        w.params.precipitation = .none
        w.params.melt = 0
        for s in w.surfaces { for i in s.heights.indices { s.heights[i] = 10 } }
        XCTAssertGreaterThan(w.bottomDepth(screenIndex: 0), 9)
        w.plow.spawn(screenIndex: 0, world: w, auto: true)
        var t: Float = 0
        while w.plow.isVisible, t < 30 { w.step(dt: 1.0 / 60); t += 1.0 / 60 }
        XCTAssertFalse(w.plow.isVisible, "auto truck drives away when done")
        XCTAssertLessThan(w.bottomDepth(screenIndex: 0), 0.3, "bottom is clear, including where it parked")
    }

    func testManualPlowParksAfterClearing() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.precipitation = .none
        w.params.melt = 0
        for s in w.surfaces { for i in s.heights.indices { s.heights[i] = 10 } }
        w.plow.spawn(screenIndex: 0, world: w)
        for _ in 0..<240 { w.step(dt: 1.0 / 60) }
        w.plow.swipe(direction: 1, speed: 600)
        var t: Float = 0
        while w.plow.state != .parked, t < 30 { w.step(dt: 1.0 / 60); t += 1.0 / 60 }
        XCTAssertEqual(w.plow.state, .parked)
        XCTAssertLessThan(w.bottomDepth(screenIndex: 0), 0.3)
    }
}

final class ExemptTests: XCTestCase {
    func testExemptWindowGetsNoSnowAndBlocksSnowBehindIt() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.intensity = 1; w.params.pileBoost = 4; w.params.melt = 0
        w.setWindows([
            WindowInfo(id: 1, frame: Rect(x: 100, y: 200, w: 700, h: 500), exempt: true),
            WindowInfo(id: 2, frame: Rect(x: 1000, y: 300, w: 600, h: 400)),
        ], offscreenAlive: [])
        var t: Float = 0
        while t < 20 { w.step(dt: 1.0 / 60); t += 1.0 / 60 }
        XCTAssertEqual(w.surfaces.first { $0.id == 1 }!.volume, 0, "exempt window: no pile")
        XCTAssertGreaterThan(w.surfaces.first { $0.id == 2 }!.volume, 0)
        XCTAssertEqual(w.exemptRects.count, 1)
    }
}

final class ExtrasTests: XCTestCase {
    func screen() -> ScreenInfo { ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil) }

    func testIciclesGrowAndSnapOnMove() {
        let w = World()
        w.setScreens([screen()])
        w.params.intensity = 0.8
        let f = Rect(x: 300, y: 300, w: 800, h: 400)
        w.setWindows([WindowInfo(id: 9, frame: f)], offscreenAlive: [])
        for _ in 0..<(60 * 120) { w.step(dt: 1.0 / 60) }
        let s = w.surfaces.first { $0.id == 9 }!
        XCTAssertFalse(s.icicles.isEmpty)
        XCTAssertGreaterThan(s.icicles.map(\.len).max()!, 4)
        var g = f; g.x += 200
        w.setWindows([WindowInfo(id: 9, frame: g)], offscreenAlive: [])
        XCTAssertEqual(s.icicles.map(\.len).max()!, 0)
        XCTAssertGreaterThan(w.particles.count(of: .shard), 0)
    }

    func testSnowmanAppearsOnDeepGroundAndPlowKnocksItOver() {
        let w = World()
        w.setScreens([screen()])
        w.params.precipitation = .none
        w.params.melt = 0
        for s in w.surfaces where s.kind == .ground { for i in s.heights.indices { s.heights[i] = 14 } }
        for _ in 0..<(60 * 3) { w.step(dt: 1.0 / 60) }
        XCTAssertEqual(w.snowmen.count, 1)
        w.plow.spawn(screenIndex: 0, world: w, auto: true)
        var t: Float = 0
        while w.plow.isVisible, t < 30 { w.step(dt: 1.0 / 60); t += 1.0 / 60 }
        XCTAssertTrue(w.snowmen.isEmpty, "the truck knocks the snowman over")
    }

    func testFrostBuildsInHeavySnowAndFades() {
        let w = World()
        w.setScreens([screen()])
        w.params.intensity = 0.9
        for _ in 0..<(60 * 30) { w.step(dt: 1.0 / 60) }
        XCTAssertGreaterThan(w.frost, 0.2)
        w.params.precipitation = .none
        for _ in 0..<(60 * 60) { w.step(dt: 1.0 / 60) }
        XCTAssertEqual(w.frost, 0)
    }
}

final class DisplayTests: XCTestCase {
    func testNoSnowFallsOnADisabledDisplay() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1440, h: 900), dock: nil),
                      ScreenInfo(id: 2, frame: Rect(x: 1440, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.intensity = 1
        w.params.disabledScreens = [2]
        for _ in 0..<(60 * 5) { w.step(dt: 1.0 / 60) }
        let onSecond = (0..<w.particles.count).filter { w.particles.x[$0] > 1500 }.count
        XCTAssertEqual(onSecond, 0)
        XCTAssertGreaterThan(w.particles.count, 100)
    }
}

final class PlowCallTests: XCTestCase {
    func testCalledPlowClearsAndLeavesEvenWithLittleSnow() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: Rect(x: 228, y: 994, w: 1464, h: 86))])
        w.params.precipitation = .none
        w.params.melt = 0
        for s in w.surfaces { for i in s.heights.indices { s.heights[i] = 3 } }
        w.plow.spawn(screenIndex: 0, world: w, auto: true)
        var t: Float = 0
        while w.plow.isVisible, t < 30 { w.step(dt: 1.0 / 60); t += 1.0 / 60 }
        XCTAssertFalse(w.plow.isVisible, "it drives off by itself")
        XCTAssertLessThan(t, 15, "one quick job")
        XCTAssertLessThan(w.bottomDepth(screenIndex: 0), 0.3)
        // It can be called again right away.
        w.plow.spawn(screenIndex: 0, world: w, auto: true)
        XCTAssertTrue(w.plow.isVisible)
    }
}

final class PlowFrostTests: XCTestCase {
    func testPlowClearsFrostyCorners() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.intensity = 0.9
        for _ in 0..<(60 * 40) { w.step(dt: 1.0 / 60) }
        XCTAssertGreaterThan(w.frost, 0.3)
        w.plow.spawn(screenIndex: 0, world: w, auto: true)
        for _ in 0..<(60 * 3) { w.step(dt: 1.0 / 60) }
        XCTAssertEqual(w.frost, 0, "frost is gone while the plow works, even in heavy snow")
    }
}

final class SheddingTests: XCTestCase {
    func testFullLedgeShedsOccasionallyNotAsAWaterfall() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.intensity = 1; w.params.pileBoost = 8; w.params.melt = 0
        w.setWindows([WindowInfo(id: 5, frame: Rect(x: 400, y: 300, w: 300, h: 300))], offscreenAlive: [])
        for _ in 0..<(60 * 60) { w.step(dt: 1.0 / 60) }      // pile is full
        var drops = 0
        for _ in 0..<(60 * 10) {
            w.step(dt: 1.0 / 60)
            for i in 0..<w.particles.count where w.particles.kind[i] == .clump
                && abs(w.particles.y[i] - 302) < 4 && (abs(w.particles.x[i] - 398) < 3 || abs(w.particles.x[i] - 702) < 3) { drops += 1 }
        }
        XCTAssertLessThan(drops, 30, "a few clumps in 10 s, not a stream")
    }
}

final class RestingPointerTests: XCTestCase {
    func testRestingPointerInAPileMakesNoStream() {
        let w = World()
        w.setScreens([ScreenInfo(id: 1, frame: Rect(x: 0, y: 0, w: 1920, h: 1080), dock: nil)])
        w.params.intensity = 1; w.params.pileBoost = 6; w.params.melt = 0
        w.setWindows([WindowInfo(id: 5, frame: Rect(x: 400, y: 300, w: 600, h: 300))], offscreenAlive: [])
        for _ in 0..<(60 * 30) { w.step(dt: 1.0 / 60) }
        for _ in 0..<(60 * 5) { w.setPointer(x: 700, y: 296, dt: 1.0 / 60); w.step(dt: 1.0 / 60) }
        let clumpsNearPointer = (0..<w.particles.count).filter {
            w.particles.kind[$0] == .clump && abs(w.particles.x[$0] - 700) < 40
        }.count
        XCTAssertLessThan(clumpsNearPointer, 5)
    }
}
