public enum ThermalCutoff: String, Codable, CaseIterable, Sendable {
    case fair, serious, critical, never

    /// The lowest thermal level that switches ClamDown off. Nil means never.
    public var level: ThermalLevel? {
        switch self {
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        case .never: nil
        }
    }
}

/// How long the mode stays on before it switches itself off.
public enum AutoOffTimer: Int, Codable, CaseIterable, Sendable {
    case never = 0
    case minutes30 = 30
    case hour1 = 60
    case hours2 = 120
    case hours4 = 240
    case hours8 = 480

    /// Nil means the mode stays on until something else switches it off.
    public var duration: Duration? {
        self == .never ? nil : .seconds(rawValue * 60)
    }

    public var title: String {
        switch self {
        case .never: "Never"
        case .minutes30: "30 minutes"
        case .hour1: "1 hour"
        case .hours2: "2 hours"
        case .hours4: "4 hours"
        case .hours8: "8 hours"
        }
    }
}

/// The symbol shown in the menu bar. Each style has a plain and a filled form for off and on.
public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable {
    case cup, eye, bolt, sun

    public var offSymbol: String {
        switch self {
        case .cup: "cup.and.saucer"
        case .eye: "eye"
        case .bolt: "bolt"
        case .sun: "sun.max"
        }
    }

    public var onSymbol: String { offSymbol + ".fill" }

    public var title: String {
        switch self {
        case .cup: "Cup"
        case .eye: "Eye"
        case .bolt: "Bolt"
        case .sun: "Sun"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public static let batteryCutoffRange = 5...50

    // Sleep
    public var autoOffTimer: AutoOffTimer = .never
    public var lockScreenWhenLidClosed = true
    public var turnOffWhenUnplugged = false
    public var autoLowPowerOnBattery = true

    // Protection
    public var batteryCutoffEnabled = true
    public var batteryCutoffPercent = 10
    public var thermalCutoff: ThermalCutoff = .serious

    // General
    public var launchAtLogin = false
    public var showDockIcon = false
    public var notificationsEnabled = true

    // Appearance
    public var menuBarIcon: MenuBarIconStyle = .cup

    public init() {}

    public func clamped() -> Settings {
        var copy = self
        copy.batteryCutoffPercent = min(max(batteryCutoffPercent, Self.batteryCutoffRange.lowerBound), Self.batteryCutoffRange.upperBound)
        return copy
    }

    // Decoding keeps every setting that is present and falls back to the default for the rest,
    // so settings saved by an older build, or with an unknown value, still load.
    private enum CodingKeys: String, CodingKey {
        case autoOffTimer, lockScreenWhenLidClosed, turnOffWhenUnplugged, autoLowPowerOnBattery
        case batteryCutoffEnabled, batteryCutoffPercent, thermalCutoff
        case launchAtLogin, showDockIcon, notificationsEnabled, menuBarIcon
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoOffTimer = (try? c.decodeIfPresent(AutoOffTimer.self, forKey: .autoOffTimer)) ?? autoOffTimer
        lockScreenWhenLidClosed = (try? c.decodeIfPresent(Bool.self, forKey: .lockScreenWhenLidClosed)) ?? lockScreenWhenLidClosed
        turnOffWhenUnplugged = (try? c.decodeIfPresent(Bool.self, forKey: .turnOffWhenUnplugged)) ?? turnOffWhenUnplugged
        autoLowPowerOnBattery = (try? c.decodeIfPresent(Bool.self, forKey: .autoLowPowerOnBattery)) ?? autoLowPowerOnBattery
        batteryCutoffEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .batteryCutoffEnabled)) ?? batteryCutoffEnabled
        batteryCutoffPercent = (try? c.decodeIfPresent(Int.self, forKey: .batteryCutoffPercent)) ?? batteryCutoffPercent
        thermalCutoff = (try? c.decodeIfPresent(ThermalCutoff.self, forKey: .thermalCutoff)) ?? thermalCutoff
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? launchAtLogin
        showDockIcon = (try? c.decodeIfPresent(Bool.self, forKey: .showDockIcon)) ?? showDockIcon
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? notificationsEnabled
        menuBarIcon = (try? c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIcon)) ?? menuBarIcon
    }
}
