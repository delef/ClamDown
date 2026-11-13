import CoreGraphics

/// Asks the window server which displays are connected. Works only inside the user's session, so the app
/// uses it and the helper cannot.
public struct SystemDisplays: DisplayReading {
    public init() {}

    public func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return true }
        guard count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
