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

    static let maxAuthRetryDelay: TimeInterval = 60

    /// Doubles the login-failure delay: at least `floor`, capped at 60 s (or `base` if larger).
    static func nextAuthDelay(after current: TimeInterval, base: TimeInterval, floor: TimeInterval = 1) -> TimeInterval {
        min(max(current * 2, floor), max(maxAuthRetryDelay, base))
    }

    /// Test hook: called with each retry delay before sleeping.
    var onRetryDelay: ((TimeInterval) -> Void)?
    /// Floor for login-failure delays so retryDelay 0 can't tight-loop. Lowered only by tests; set before `start()`.
    var minAuthRetryDelay: TimeInterval = 1

    private func loop() {
        var first = true
        // Login failures back off exponentially so a wrong password doesn't hammer the camera.
        let authBase = max(retryDelay, minAuthRetryDelay)
        var authDelay = authBase
        while !isStopped {
            if first { emit(.connecting) }
            first = false
            var delay = retryDelay
            var wentLive = false
            do {
                try attempt(wentLive: &wentLive)
            } catch {
                if isStopped { break }
                if wentLive { authDelay = authBase }
                if case RTSPError.unauthorized = error {
                    delay = authDelay
                    authDelay = Self.nextAuthDelay(after: authDelay, base: authBase, floor: minAuthRetryDelay)
                }
                emit(.retrying(Self.friendlyMessage(for: error)))
            }
            if isStopped { break }
            onRetryDelay?(delay)
            _ = wake.wait(timeout: .now() + delay)
        }
    }

    /// One connect-and-run attempt. Returns normally only when stopped.
    private func attempt(wentLive: inout Bool) throws {
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

        try c.run(
            onInfo: { info in if !isStopped { onInfo?(info) } },
            onVideo: { frame in
                if isStopped { return }
                if !wentLive {
                    wentLive = true
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
