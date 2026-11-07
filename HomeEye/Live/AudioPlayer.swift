import AVFoundation
import Foundation

/// Plays decoded G.711 samples through AVAudioEngine. Muted (and idle) by default.
/// `enqueue` may be called from any thread; `setMuted` is called from the main thread.
final class AudioPlayer {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var rate = 0
    private var muted = true
    private var backlogFrames = 0

    func setMuted(_ newValue: Bool) {
        lock.lock()
        muted = newValue
        lock.unlock()
        if newValue {
            lock.lock()
            player?.stop()
            engine?.stop()
            backlogFrames = 0
            lock.unlock()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            // The engine starts when the first packet arrives and its rate is known.
            lock.lock()
            if let engine, let player {
                try? engine.start()
                player.play()
            }
            lock.unlock()
        }
    }

    func enqueue(samples: [Int16], sampleRate: Int) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if muted || backlogFrames > sampleRate / 2 { return }
        guard prepareLocked(rate: sampleRate), let player, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        for i in 0..<samples.count { channel[i] = Float(samples[i]) / 32768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        backlogFrames += samples.count
        let count = samples.count
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.backlogFrames = max(0, self.backlogFrames - count)
            self.lock.unlock()
        }
        if !player.isPlaying { player.play() }
    }

    /// Creates the engine on first use and reconnects when the rate changes. Lock must be held.
    private func prepareLocked(rate newRate: Int) -> Bool {
        if engine == nil {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            engine = e
            player = p
        }
        guard let engine, let player else { return false }
        if rate != newRate {
            player.stop()
            engine.stop()
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(newRate), channels: 1) else {
                return false
            }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            format = fmt
            rate = newRate
            backlogFrames = 0
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }
}
