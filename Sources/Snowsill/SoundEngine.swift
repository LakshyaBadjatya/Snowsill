import AVFoundation

/// Soft, synthesized ambience (no audio files): wind noise that follows the
/// weather, a diesel rumble while the plow drives, and a two-tone beep when it
/// starts plowing. Off by default.
final class SoundEngine {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private let lock = NSLock()
    // Targets set from the main thread
    private var windTarget: Float = 0
    private var engineTarget: Float = 0
    private var beepLeft: Int = 0
    private var started = false

    init() {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = Float(sr > 0 ? sr : 48_000)
        var wind: Float = 0, eng: Float = 0
        var lp1: Float = 0, lp2: Float = 0, lpE: Float = 0
        var phase: Float = 0, beepPhase: Float = 0, gust: Float = 0
        var seed: UInt32 = 22222
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!
        node = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, abl -> OSStatus in
            self.lock.lock()
            let wt = self.windTarget, et = self.engineTarget
            var beep = self.beepLeft
            self.lock.unlock()
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frames)
            for i in 0..<n {
                wind += (wt - wind) * 0.0005
                eng += (et - eng) * 0.0008
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let white = Float(Int32(bitPattern: seed)) / Float(Int32.max)
                // Wind: double low-passed noise, slowly gusting.
                gust += 0.00002
                let g = 0.6 + 0.4 * sin(gust * 6.283 * 0.15)
                lp1 += (white - lp1) * 0.02
                lp2 += (lp1 - lp2) * 0.05
                var s = lp2 * wind * 2.2 * g
                // Engine: low sawtooth + noise, heavily filtered.
                phase += (48 + eng * 22) / rate
                if phase > 1 { phase -= 1 }
                let saw = phase * 2 - 1
                lpE += ((saw * 0.7 + white * 0.3) - lpE) * 0.03
                s += lpE * eng * 0.35
                // Beep: 2 short tones.
                if beep > 0 {
                    let tone: Float = beep > Int(rate * 0.22) ? 1046 : 880
                    beepPhase += tone / rate
                    if beepPhase > 1 { beepPhase -= 1 }
                    let on = (beep % Int(rate * 0.22)) > Int(rate * 0.07)
                    s += (beepPhase < 0.5 ? 0.06 : -0.06) * (on ? 1 : 0)
                    beep -= 1
                }
                for b in buffers {
                    b.mData!.assumingMemoryBound(to: Float.self)[i] = max(min(s, 1), -1)
                }
            }
            self.lock.lock(); self.beepLeft = beep; self.lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.6
    }

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                if !started { engine.prepare(); started = true }
                try? engine.start()
            } else {
                engine.pause()
            }
        }
    }

    /// Call once per frame (cheap).
    func update(wind: Float, truckSpeed: Float) {
        guard enabled else { return }
        lock.lock()
        windTarget = min(wind, 1) * 0.5
        engineTarget = min(truckSpeed / 700, 1) * 0.9 + (truckSpeed > 0.5 ? 0.15 : 0)
        lock.unlock()
    }

    func beep() {
        guard enabled else { return }
        let sr = Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)
        lock.lock(); beepLeft = Int(Double(sr) * 0.44); lock.unlock()
    }
}
