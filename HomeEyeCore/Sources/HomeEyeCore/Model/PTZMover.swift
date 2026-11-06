import Foundation

public protocol PTZControlling: AnyObject {
    func continuousMove(pan: Double, tilt: Double) async throws
    func stop() async throws
}

public enum JoystickMath {
    public static func quantize(_ v: Double) -> Double {
        if abs(v) < 0.2 { return 0 }
        return min(1, max(-1, (v * 4).rounded() / 4))
    }

    public static func normalize(dx: Double, dy: Double, radius: Double) -> (x: Double, y: Double, knobX: Double, knobY: Double) {
        guard radius > 0 else { return (0, 0, 0, 0) }
        let dist = (dx * dx + dy * dy).squareRoot()
        let scale = dist > radius ? radius / dist : 1
        let kx = dx * scale
        let ky = dy * scale
        return (kx / radius + 0, -ky / radius + 0, kx, ky)
    }

    public static func command(x: Double, y: Double, invertPan: Bool, invertTilt: Bool) -> (pan: Double, tilt: Double)? {
        let pan = quantize(invertPan ? -x : x)
        let tilt = quantize(invertTilt ? -y : y)
        if pan == 0 && tilt == 0 { return nil }
        return (pan, tilt)
    }
}

/// Conflates joystick events: only the latest pending command is sent, strictly in order.
/// Deliberately not an actor, so unordered Task hops cannot reorder events.
public final class PTZMover: @unchecked Sendable {
    private enum Command {
        case move(pan: Double, tilt: Double)
        case stop
    }

    private let controller: PTZControlling
    private let onError: (String) -> Void
    private let lock = NSLock()
    private var pending: Command?
    private var draining = false

    // Only touched by the single drain task.
    private var moving = false
    private var lastSent: (Double, Double)?
    private var reportedError = false

    public init(controller: PTZControlling, onError: @escaping (String) -> Void) {
        self.controller = controller
        self.onError = onError
    }

    public func move(pan: Double, tilt: Double) { submit(.move(pan: pan, tilt: tilt)) }

    public func stop() { submit(.stop) }

    private func submit(_ command: Command) {
        lock.lock()
        pending = command
        let start = !draining
        if start { draining = true }
        lock.unlock()
        if start { Task { await self.drain() } }
    }

    private func nextPending() -> Command? {
        lock.lock()
        defer { lock.unlock() }
        if let p = pending {
            pending = nil
            return p
        }
        draining = false
        return nil
    }

    private func drain() async {
        while let command = nextPending() {
            await execute(command)
        }
    }

    private func execute(_ command: Command) async {
        do {
            switch command {
            case .stop:
                let wasMoving = moving
                moving = false
                lastSent = nil
                reportedError = false
                if wasMoving { try await controller.stop() }
            case let .move(pan, tilt):
                if let last = lastSent, last == (pan, tilt) { return }
                moving = true
                lastSent = (pan, tilt)
                try await controller.continuousMove(pan: pan, tilt: tilt)
            }
        } catch {
            if !reportedError {
                reportedError = true
                onError(error.localizedDescription)
            }
        }
    }
}
