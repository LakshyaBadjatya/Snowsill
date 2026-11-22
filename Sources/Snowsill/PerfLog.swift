import Foundation
import QuartzCore

/// SNOWSILL_DEBUG=1: once a second, prints main-thread work per frame and
/// frame gaps (a gap > 1.5 refresh intervals is a dropped frame).
final class PerfLog {
    private let on = ProcessInfo.processInfo.environment["SNOWSILL_DEBUG"] == "1"
    private var lastTick: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0, dropped = 0
    private var maxWork: Double = 0, sumWork: Double = 0, maxGap: Double = 0
    var extra: () -> String = { "" }

    func frame(tick: CFTimeInterval, work: Double) {
        guard on else { return }
        if lastTick > 0 {
            let gap = tick - lastTick
            maxGap = max(maxGap, gap)
            if gap > 1.5 / 75 { dropped += 1 }
        }
        lastTick = tick
        frames += 1
        sumWork += work
        maxWork = max(maxWork, work)
        if windowStart == 0 { windowStart = tick }
        if tick - windowStart >= 1 {
            FileHandle.standardError.write(String(format: "perf frames=%d dropped=%d work avg=%.2fms max=%.2fms gap max=%.1fms %@\n",
                frames, dropped, sumWork / Double(max(frames, 1)) * 1000, maxWork * 1000, maxGap * 1000, extra()).data(using: .utf8)!)
            windowStart = tick; frames = 0; dropped = 0; maxWork = 0; sumWork = 0; maxGap = 0
        }
    }
}
