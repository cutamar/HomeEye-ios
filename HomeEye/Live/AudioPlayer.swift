import AVFoundation
import Foundation

/// Plays decoded G.711 samples through AVAudioEngine. Muted (and idle) by default.
/// `enqueue` may be called from any thread; `setMuted` is called from the main thread.
///
/// Locking: `engineLock` serializes all AVAudioEngine/player calls; `stateLock` guards the
/// small counters and is never held around an AV call (completion handlers only take `stateLock`).
final class AudioPlayer {
    private let engineLock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var rate = 0

    private let stateLock = NSLock()
    private var muted = true
    private var backlogFrames = 0
    private var epoch = 0

    func setMuted(_ newValue: Bool) {
        stateLock.lock()
        muted = newValue
        if newValue {
            epoch += 1
            backlogFrames = 0
        }
        stateLock.unlock()

        if newValue {
            engineLock.lock()
            player?.stop()
            engine?.stop()
            engineLock.unlock()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            // The engine starts when the first packet arrives and its rate is known.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
    }

    func enqueue(samples: [Int16], sampleRate: Int) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        engineLock.lock()
        defer { engineLock.unlock() }

        stateLock.lock()
        let skip = muted || backlogFrames > sampleRate / 2
        stateLock.unlock()
        if skip { return }

        guard prepare(rate: sampleRate), let player, let engine, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        for i in 0..<samples.count { channel[i] = Float(samples[i]) / 32768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let count = samples.count
        stateLock.lock()
        backlogFrames += count
        let token = epoch
        stateLock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            if self.epoch == token { self.backlogFrames = max(0, self.backlogFrames - count) }
            self.stateLock.unlock()
        }
        if engine.isRunning, !player.isPlaying { player.play() }
    }

    /// Creates the engine on first use, reconnects when the rate changes and starts it.
    /// `engineLock` must be held.
    private func prepare(rate newRate: Int) -> Bool {
        if engine == nil {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            engine = e
            player = p
        }
        guard let engine, let player else { return false }
        if rate != newRate {
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(newRate), channels: 1) else {
                return false
            }
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
            format = fmt
            rate = newRate
            stateLock.lock()
            epoch += 1
            backlogFrames = 0
            stateLock.unlock()
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return engine.isRunning
    }
}
