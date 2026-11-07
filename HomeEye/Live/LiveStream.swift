import Combine
import HomeEyeCore
import UIKit

/// Glue between the RTSP supervisor, the video decoder/display layer and the audio player.
@MainActor
final class LiveStream: ObservableObject {
    @Published private(set) var status: StreamStatus = .connecting
    @Published private(set) var aspectRatio: CGFloat = 16 / 9
    @Published private(set) var hasAudio = false
    @Published var muted = true {
        didSet { if muted != oldValue { audio.setMuted(muted) } }
    }

    let videoView = VideoLayerUIView()

    private let decoder: VideoDecoder
    private let audio = AudioPlayer()
    private var supervisor: StreamSupervisor?
    private var generation = 0

    init() {
        decoder = VideoDecoder(layer: videoView.displayLayer)
        decoder.onSize = { [weak self] size in
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async { self?.aspectRatio = size.width / size.height }
        }
    }

    deinit {
        supervisor?.stop()
    }

    /// `refuseBasic` is true for a camera pinned to Digest. `onDigestConfirmed` runs on the main
    /// actor when a session authenticated with Digest (the caller persists the pin).
    func play(url: String, credentials: Credentials?, refuseBasic: Bool = false,
              onDigestConfirmed: (() -> Void)? = nil) {
        supervisor?.stop()
        supervisor = nil
        decoder.reset()
        generation += 1
        let gen = generation
        status = .connecting
        hasAudio = false

        let sup = StreamSupervisor(config: RTSPConfig(url: url, credentials: credentials, refuseBasic: refuseBasic))
        sup.onVideo = { [decoder] frame in decoder.decode(frame) }
        sup.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.status = s
            }
        }
        sup.onInfo = { [weak self] info in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.hasAudio = info.audio != nil
                if info.authScheme == .digest { onDigestConfirmed?() }
            }
        }
        sup.onAudio = { [audio] packet in
            audio.enqueue(samples: packet.samples, sampleRate: packet.sampleRate)
        }
        supervisor = sup
        sup.start()
    }

    func stop() {
        generation += 1
        supervisor?.stop()
        supervisor = nil
        if !muted { muted = true }
    }

    func snapshot() -> UIImage? {
        decoder.latestImage()
    }
}
