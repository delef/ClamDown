import Foundation

/// Locks the screen with the login framework call the system's own "Lock Screen" menu item uses.
/// That call is private, so when it is missing the display goes to sleep instead, which locks the Mac
/// when macOS asks for a password after the display sleeps (the default).
public struct LiveScreenLocker: ScreenLocking {
    public init() {}

    public func lock() {
        if let lockScreen = Self.lockScreenFunction() {
            _ = lockScreen()
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try? process.run()
        }
    }

    private static func lockScreenFunction() -> (@convention(c) () -> Int32)? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }
}
