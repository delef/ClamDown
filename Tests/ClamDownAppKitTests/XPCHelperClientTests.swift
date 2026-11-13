import Foundation
import Testing
import ClamDownShared
@testable import ClamDownAppKit

/// A helper that only answers, served from inside the test process.
final class StubHelper: NSObject, ClamDownHelperXPC, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var enables = 0
    /// How many times this helper was asked to switch the mode on.
    var enableCount: Int { lock.withLock { enables } }

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func connection() -> NSXPCConnection {
        NSXPCConnection(listenerEndpoint: listener.endpoint)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ClamDownHelperXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func enable(lowPowerOnBattery: Bool, reply: @escaping @Sendable (String?) -> Void) {
        lock.withLock { enables += 1 }
        reply(nil)
    }
    func disable(reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
    func setLowPowerOnBattery(_ on: Bool, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
    func heartbeat(reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
    func status(reply: @escaping @Sendable (Bool) -> Void) { reply(false) }
    func setFanPolicy(_ policy: Data, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
    func coolingStatus(reply: @escaping @Sendable (Data?) -> Void) { reply(nil) }

    /// A connection to a helper that has since been replaced: its listener is gone.
    static func connectionToAHelperThatIsGone() -> NSXPCConnection {
        let gone = StubHelper()
        let connection = gone.connection()
        gone.listener.invalidate()
        return connection
    }
}

/// Hands out prepared connections one by one and counts how many were asked for.
final class Connections: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [NSXPCConnection]
    private var handedOut = 0

    init(_ connections: [NSXPCConnection]) { waiting = connections }

    var count: Int { lock.withLock { handedOut } }

    func next() -> NSXPCConnection {
        lock.withLock {
            handedOut += 1
            return waiting.removeFirst()
        }
    }
}

@Suite struct XPCHelperClientTests {
    private func connectionToAHelperThatIsGone() -> NSXPCConnection {
        StubHelper.connectionToAHelperThatIsGone()
    }

    /// Updating the helper leaves the app holding a connection to the old one, and the first call on it fails.
    /// The user pressed Turn On once; it must not take a second press to reach the new helper.
    @Test func callOnAConnectionToAReplacedHelperReachesTheNewOne() async throws {
        let current = StubHelper()
        let connections = Connections([connectionToAHelperThatIsGone(), current.connection()])
        let client = XPCHelperClient(connect: { connections.next() })
        #expect(try await client.heartbeat())
        #expect(connections.count == 2)
    }

    @Test func helperThatCannotBeReachedIsReportedAfterOneMoreAttempt() async {
        let connections = Connections([connectionToAHelperThatIsGone(), connectionToAHelperThatIsGone()])
        let client = XPCHelperClient(connect: { connections.next() })
        await #expect(throws: HelperClientError.connection("The helper did not answer.")) {
            try await client.heartbeat()
        }
        #expect(connections.count == 2)
    }

    @Test func workingConnectionIsKeptForTheNextCall() async throws {
        let current = StubHelper()
        let connections = Connections([current.connection()])
        let client = XPCHelperClient(connect: { connections.next() })
        #expect(try await client.heartbeat())
        #expect(try await client.heartbeat())
        #expect(connections.count == 1)
    }

    /// The helper answered, with an error of its own. Asking again would run the request twice.
    @Test func errorReportedByTheHelperIsNotRetried() async {
        final class Refusing: NSObject, ClamDownHelperXPC, NSXPCListenerDelegate, @unchecked Sendable {
            let listener = NSXPCListener.anonymous()
            private let lock = NSLock()
            private var calls = 0
            var enableCalls: Int { lock.withLock { calls } }

            override init() {
                super.init()
                listener.delegate = self
                listener.resume()
            }

            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                connection.exportedInterface = NSXPCInterface(with: ClamDownHelperXPC.self)
                connection.exportedObject = self
                connection.resume()
                return true
            }

            func enable(lowPowerOnBattery: Bool, reply: @escaping @Sendable (String?) -> Void) {
                lock.withLock { calls += 1 }
                reply("pmset failed")
            }
            func disable(reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
            func setLowPowerOnBattery(_ on: Bool, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
            func heartbeat(reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
            func status(reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
            func setFanPolicy(_ policy: Data, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
            func coolingStatus(reply: @escaping @Sendable (Data?) -> Void) { reply(nil) }
        }
        let helper = Refusing()
        let client = XPCHelperClient(connect: { NSXPCConnection(listenerEndpoint: helper.listener.endpoint) })
        await #expect(throws: HelperClientError.helper("pmset failed")) {
            try await client.enable(lowPowerOnBattery: true)
        }
        #expect(helper.enableCalls == 1)
    }
}
