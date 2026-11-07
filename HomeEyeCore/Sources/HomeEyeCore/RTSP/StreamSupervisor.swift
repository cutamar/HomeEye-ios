import Foundation

/// Keeps one RTSP stream running on a background thread, reconnecting after failures.
/// Set the callbacks before `start()`; they are called on the supervisor's thread.
public final class StreamSupervisor: @unchecked Sendable {
    public var onStatus: ((StreamStatus) -> Void)?
    public var onInfo: ((StreamInfo) -> Void)?
    public var onVideo: ((VideoFrame) -> Void)?
    public var onAudio: ((AudioPacket) -> Void)?

    private let config: RTSPConfig
    private let retryDelay: TimeInterval
    private let connector: (String, Int, TimeInterval) throws -> ByteStream

    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var client: RTSPClient?
    private let wake = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)

    public init(config: RTSPConfig, retryDelay: TimeInterval = 3,
                connector: @escaping (String, Int, TimeInterval) throws -> ByteStream = {
                    try TCPSocket.connect(host: $0, port: $1, timeout: $2)
                }) {
        self.config = config
        self.retryDelay = retryDelay
        self.connector = connector
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !stopped else { return }
        started = true
        let thread = Thread { [self] in
            loop()
            exited.signal()
        }
        thread.name = "rtsp"
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let c = client
        client = nil
        lock.unlock()
        c?.close()
        wake.signal()
    }

    /// Test hook: waits for the background thread to finish after `stop()`.
    func waitForExit(timeout: TimeInterval) -> Bool {
        exited.wait(timeout: .now() + timeout) == .success
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func emit(_ status: StreamStatus) {
        if !isStopped { onStatus?(status) }
    }

    private func loop() {
        var first = true
        while !isStopped {
            if first { emit(.connecting) }
            first = false
            do {
                try attempt()
            } catch {
                if isStopped { break }
                emit(.retrying(Self.friendlyMessage(for: error)))
            }
            if isStopped { break }
            _ = wake.wait(timeout: .now() + retryDelay)
        }
    }

    /// One connect-and-run attempt. Returns normally only when stopped.
    private func attempt() throws {
        guard let url = RTSPURL.parse(config.url) else { throw RTSPError.protocolError("invalid URL") }
        let stream = try connector(url.host, url.port, config.connectTimeout)
        defer { stream.close() }
        (stream as? TCPSocket)?.readTimeout = config.readTimeout
        let c = RTSPClient(config: config, stream: stream)
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        client = c
        lock.unlock()
        defer {
            lock.lock()
            if client === c { client = nil }
            lock.unlock()
        }

        var live = false
        try c.run(
            onInfo: { info in if !isStopped { onInfo?(info) } },
            onVideo: { frame in
                if isStopped { return }
                if !live {
                    live = true
                    emit(.live)
                }
                onVideo?(frame)
            },
            onAudio: { packet in if !isStopped { onAudio?(packet) } }
        )
    }

    public static func friendlyMessage(for error: Error) -> String {
        switch error {
        case RTSPError.unauthorized:
            return "Camera rejected the login"
        case NetError.unreachable:
            return "Can't reach the camera"
        case RTSPError.unsupportedCodec(let c):
            return "Unsupported video format (\(c))"
        default:
            return "Connection lost"
        }
    }
}
