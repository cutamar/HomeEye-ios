import XCTest
@testable import HomeEyeCore

private final class FakePTZ: PTZControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _moves: [(Double, Double)] = []
    private var _stops = 0
    var delayNanos: UInt64 = 50_000_000
    var failure: Error?

    var moves: [(Double, Double)] { lock.lock(); defer { lock.unlock() }; return _moves }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }

    func continuousMove(pan: Double, tilt: Double) async throws {
        try await Task.sleep(nanoseconds: delayNanos)
        lock.lock(); _moves.append((pan, tilt)); lock.unlock()
        if let failure { throw failure }
    }

    func stop() async throws {
        lock.lock(); _stops += 1; lock.unlock()
        if let failure { throw failure }
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

final class PTZMoverTests: XCTestCase {
    private func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    func testRapidMovesAreConflated() async {
        let fake = FakePTZ()
        let mover = PTZMover(controller: fake, onError: { _ in })
        for i in 1...20 { mover.move(pan: Double(i) / 20, tilt: 0) }
        await settle()
        XCTAssertLessThanOrEqual(fake.moves.count, 2)
        XCTAssertEqual(fake.moves.last?.0, 1.0)
    }

    func testMoveThenStopCallsStop() async {
        let fake = FakePTZ()
        fake.delayNanos = 1_000_000
        let mover = PTZMover(controller: fake, onError: { _ in })
        mover.move(pan: 0.5, tilt: 0)
        await settle()
        mover.stop()
        await settle()
        XCTAssertEqual(fake.moves.count, 1)
        XCTAssertEqual(fake.stops, 1)
    }

    func testStopAloneDoesNothing() async {
        let fake = FakePTZ()
        let mover = PTZMover(controller: fake, onError: { _ in })
        mover.stop()
        await settle()
        XCTAssertEqual(fake.stops, 0)
        XCTAssertEqual(fake.moves.count, 0)
    }

    func testDuplicateMoveIgnored() async {
        let fake = FakePTZ()
        fake.delayNanos = 1_000_000
        let mover = PTZMover(controller: fake, onError: { _ in })
        mover.move(pan: 0.5, tilt: 0.25)
        await settle()
        mover.move(pan: 0.5, tilt: 0.25)
        await settle()
        XCTAssertEqual(fake.moves.count, 1)
    }

    func testErrorsReportedOnceUntilStop() async {
        let fake = FakePTZ()
        fake.delayNanos = 1_000_000
        fake.failure = Boom()
        let lock = NSLock()
        var errors: [String] = []
        let mover = PTZMover(controller: fake, onError: { m in lock.lock(); errors.append(m); lock.unlock() })
        mover.move(pan: 0.5, tilt: 0)
        await settle()
        mover.move(pan: 0.75, tilt: 0)
        await settle()
        lock.lock(); XCTAssertEqual(errors, ["boom"]); lock.unlock()
        mover.stop()
        await settle()
        mover.move(pan: 1, tilt: 0)
        await settle()
        lock.lock(); XCTAssertEqual(errors, ["boom", "boom"]); lock.unlock()
    }

    func testQuantize() {
        XCTAssertEqual(JoystickMath.quantize(0.19), 0)
        XCTAssertEqual(JoystickMath.quantize(-0.19), 0)
        XCTAssertEqual(JoystickMath.quantize(0.2), 0.25)
        XCTAssertEqual(JoystickMath.quantize(0.375), 0.5)
        XCTAssertEqual(JoystickMath.quantize(-1.3), -1)
        XCTAssertEqual(JoystickMath.quantize(1.3), 1)
        XCTAssertEqual(JoystickMath.quantize(0.6), 0.5)
    }

    func testNormalizeClampsToRadius() {
        let r = JoystickMath.normalize(dx: 100, dy: 0, radius: 50)
        XCTAssertEqual(r.x, 1, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.knobX, 50, accuracy: 1e-9)
        let s = JoystickMath.normalize(dx: 0, dy: -25, radius: 50)
        XCTAssertEqual(s.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.knobY, -25, accuracy: 1e-9)
        let d = JoystickMath.normalize(dx: 30, dy: 40, radius: 25)
        XCTAssertEqual(hypot(d.knobX, d.knobY), 25, accuracy: 1e-9)
    }

    func testCommand() {
        XCTAssertNil(JoystickMath.command(x: 0.1, y: -0.1, invertPan: false, invertTilt: false))
        let c = JoystickMath.command(x: 0.5, y: 0.1, invertPan: false, invertTilt: false)
        XCTAssertEqual(c?.pan, 0.5)
        XCTAssertEqual(c?.tilt, 0)
        let i = JoystickMath.command(x: 0.5, y: 0.5, invertPan: true, invertTilt: true)
        XCTAssertEqual(i?.pan, -0.5)
        XCTAssertEqual(i?.tilt, -0.5)
    }
}
