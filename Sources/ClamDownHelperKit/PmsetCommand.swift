/// The only `pmset` invocations the helper can ever run.
/// Payloads are `Bool` on purpose: no caller-supplied string reaches `pmset`.
public enum PmsetCommand: Equatable, Sendable {
    case setSleepDisabled(Bool)
    case setBatteryLowPowerMode(Bool)
    case readGlobal
    case readCustom

    public var arguments: [String] {
        switch self {
        case .setSleepDisabled(let on): ["disablesleep", on ? "1" : "0"]
        case .setBatteryLowPowerMode(let on): ["-b", "lowpowermode", on ? "1" : "0"]
        case .readGlobal: ["-g"]
        case .readCustom: ["-g", "custom"]
        }
    }
}
