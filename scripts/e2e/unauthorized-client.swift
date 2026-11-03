import Foundation

// Connects to the Wakeup helper's Mach service from a process that is not the signed Wakeup app
// and asks for its status. A correctly locked-down helper refuses: expect "REFUSED", never "ACCEPTED".
// Only meaningful while the helper is registered and running; with no helper you get REFUSED for the wrong reason.
//
// Usage: swift scripts/e2e/unauthorized-client.swift <bundle id>.helper

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift unauthorized-client.swift <bundle id>.helper\n".utf8))
    exit(2)
}

@objc protocol HelperStatus {
    func status(reply: @escaping @Sendable (Bool) -> Void)
}

let connection = NSXPCConnection(machServiceName: CommandLine.arguments[1], options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: HelperStatus.self)
connection.resume()

let done = DispatchSemaphore(value: 0)
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    print("REFUSED: \(error.localizedDescription)")
    done.signal()
} as! HelperStatus
proxy.status { enabled in
    print("ACCEPTED (this is a bug): the helper answered, enabled=\(enabled)")
    done.signal()
}
if done.wait(timeout: .now() + 5) == .timedOut {
    print("TIMEOUT: neither a reply nor an error")
}
