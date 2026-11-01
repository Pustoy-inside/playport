// SPDX-License-Identifier: GPL-3.0-or-later
/// A controller as a mouse (S1Probe HostIO; the in-game menu's Controller as mouse, a
/// program the player runs, and the guest's windows): the right stick moves the cursor,
/// RT is the left button and LT the right one, the left stick scrolls, and R3 held moves
/// the cursor slowly. The rest of the pad stays keys (WindowKeys). As Steam Input's
/// desktop layout, without its touchpads.
public struct PadMouse: Sendable {
    /// Below this the sticks rest (worn sticks drift).
    public static let deadZone: Float = 0.15
    /// A trigger past this is its button down; it comes up below `triggerOff`.
    public static let triggerOn: Float = 0.5, triggerOff: Float = 0.3
    /// The cursor's speed with the stick all the way over, in points a second.
    public var speed = 750.0
    /// R3 held: this share of it.
    public var precision = 0.3
    /// The wheel's notches a second with the left stick all the way over.
    public var notches = 8.0

    private var left = false, right = false
    private var wheel = 0.0

    public init() {}

    /// The buttons a new snapshot moves, in order: MOUSEEVENTF_* down or up flags (Pointer).
    public mutating func buttons(_ p: PadInput) -> [UInt32] {
        var out: [UInt32] = []
        let l = Self.held(p.rightTrigger, was: left), r = Self.held(p.leftTrigger, was: right)
        if l != left { out.append(l ? Pointer.leftDown : Pointer.leftUp); left = l }
        if r != right { out.append(r ? Pointer.rightDown : Pointer.rightUp); right = r }
        return out
    }

    /// The up flags of the buttons still down (the mode ends with them held).
    public mutating func release() -> [UInt32] {
        var out: [UInt32] = []
        if left { out.append(Pointer.leftUp); left = false }
        if right { out.append(Pointer.rightUp); right = false }
        wheel = 0
        return out
    }

    /// The motion of `dt` seconds with the sticks as `p` has them: the cursor's move in points
    /// (+y down) and the wheel's whole delta (WHEEL_DELTA 120 a notch, + away from the player).
    public mutating func tick(_ p: PadInput, dt: Double) -> (dx: Double, dy: Double, wheel: Int32) {
        var dx = 0.0, dy = 0.0
        let m = Self.magnitude(p.rx, p.ry)
        if m > 0 {
            let s = Self.curve(m) * speed * (p.rightThumb ? precision : 1) * dt
            dx = Double(p.rx) / Double(m) * s
            dy = -Double(p.ry) / Double(m) * s   // GameController's +y is up
        }
        var out: Int32 = 0
        let w = abs(p.ly) > Self.deadZone ? Self.curve(abs(p.ly)) : 0
        if w > 0 {
            wheel += (p.ly > 0 ? 1 : -1) * w * notches * 120 * dt
            let whole = (wheel / 40).rounded(.towardZero) * 40
            wheel -= whole
            out = Int32(whole)
        } else {
            wheel = 0
        }
        return (dx, dy, out)
    }

    /// The sticks are off rest: the motion needs a clock.
    public static func moving(_ p: PadInput) -> Bool {
        magnitude(p.rx, p.ry) > 0 || abs(p.ly) > deadZone
    }

    /// The stick's deflection past the dead zone, 0 inside it.
    static func magnitude(_ x: Float, _ y: Float) -> Float {
        let m = (x * x + y * y).squareRoot()
        return m > deadZone ? min(m, 1) : 0
    }

    /// Fine near the centre, fast at the edge: the deflection past the dead zone, squared.
    static func curve(_ m: Float) -> Double {
        let s = Double(max(0, min(1, (m - deadZone) / (1 - deadZone))))
        return s * s
    }

    static func held(_ t: Float, was: Bool) -> Bool { was ? t > triggerOff : t > triggerOn }
}
