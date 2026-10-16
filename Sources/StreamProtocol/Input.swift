import Foundation

/// Client → host input. Positions are fractions of the streamed video frame (0…1 across its width
/// and height), whatever size the client draws it at; the host maps them onto the source's screen
/// rectangle. That keeps the client ignorant of Mac geometry and survives window moves.
public enum PointerAction: String, Codable {
    case move       // cursor only (Pencil hover, finger position)
    case leftDown
    case leftUp
    case rightDown
    case rightUp
}

public enum InputEvent: Codable, Hashable {
    case pointer(PointerAction, x: Double, y: Double)

    /// Scroll with the cursor at (x, y). dx/dy are fractions of the frame the content should move,
    /// natural-scrolling sign: positive dy means the content moves down (finger dragged down).
    case scroll(x: Double, y: Double, dx: Double, dy: Double)

    /// Text from the software keyboard. "\n", "\t" and "\u{8}" (backspace) are delivered as the
    /// matching keys; everything else is typed as Unicode.
    case text(String)

    /// Scroll gesture boundaries, so the Mac sees a trackpad-like gesture (rubber-banding, and
    /// momentum after the fingers lift) rather than a bare wheel. Sent around `.scroll` deltas:
    /// began → deltas… → ended, then optionally momentumBegan → deltas… → momentumEnded, with the
    /// client generating the decaying momentum deltas itself.
    case scrollGesture(ScrollPhase, x: Double, y: Double)

    /// A key by USB HID usage (UIKeyboardHIDUsage.rawValue on iOS) with UIKeyModifierFlags bits,
    /// which are the same bit positions as CGEventFlags for shift/control/option/command.
    case key(hidUsage: UInt16, down: Bool, modifiers: UInt64)
}

public enum ScrollPhase: String, Codable {
    case began, ended, momentumBegan, momentumEnded
}

/// Kind 8 on a host whose catalog carries `inputGeneration`. The generation belongs to the
/// source selection, so input delayed across another device's pick cannot target its new source.
public struct SourceInput: Codable {
    public var event: InputEvent
    public var generation: String
    public var videoEpoch: UUID?

    public init(event: InputEvent, generation: String, videoEpoch: UUID? = nil) {
        self.event = event; self.generation = generation; self.videoEpoch = videoEpoch
    }

    /// An older host has no generation and still expects the original InputEvent payload.
    public static func payload(_ event: InputEvent, generation: String?, videoEpoch: UUID? = nil) -> Data {
        guard let generation else { return Wire.encode(event) }
        return Wire.encode(SourceInput(event: event, generation: generation, videoEpoch: videoEpoch))
    }
}
