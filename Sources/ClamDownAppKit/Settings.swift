import ClamDownShared

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
    case lid, cup, eye, bolt, sun

    /// The names `clamdown.lid` and `clamdown.lid.fill` are not SF Symbols: the app draws them itself.
    public var offSymbol: String {
        switch self {
        case .lid: "clamdown.lid"
        case .cup: "cup.and.saucer"
        case .eye: "eye"
        case .bolt: "bolt"
        case .sun: "sun.max"
        }
    }

    public var onSymbol: String { offSymbol + ".fill" }

    /// Whether the app draws this style itself instead of taking an SF Symbol.
    public var isDrawn: Bool { self == .lid }

    public var title: String {
        switch self {
        case .lid: "Lid"
        case .cup: "Cup"
        case .eye: "Eye"
        case .bolt: "Bolt"
        case .sun: "Sun"
        }
    }
}

/// Which fan curve the Cooling page shows and the fans follow.
public enum FanCurveMode: String, Codable, CaseIterable, Sendable {
    /// Two points: "speeds up from" at 0 % and "full speed at" at 100 %.
    case standard
    /// Five points the user places.
    case advanced
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
    /// After a battery or heat switch-off with the lid closed, put the Mac to sleep at once.
    public var sleepAfterProtection = true

    // Cooling
    /// Off leaves the fans to macOS.
    public var fanControlEnabled = true
    public var fanCurveMode: FanCurveMode = .standard
    /// The Standard curve's two temperatures.
    public var fanStartTemperature = StandardCurve.defaultStart
    public var fanFullSpeedTemperature = StandardCurve.defaultFull
    /// The Advanced curve's five points. Nil until Advanced is first chosen.
    public var fanAdvancedPoints: [FanPoint]?
    public var fansOnlyWhenLidClosed = true

    // General
    public var launchAtLogin = false
    public var showDockIcon = false
    public var notificationsEnabled = true

    // Appearance
    public var menuBarIcon: MenuBarIconStyle = .lid

    public init() {}

    /// What the helper gets for the fans. No points means fan control is off.
    public var fanPolicy: FanPolicy {
        let points: [FanPoint]
        if !fanControlEnabled {
            points = []
        } else {
            switch fanCurveMode {
            case .standard: points = StandardCurve.points(start: fanStartTemperature, full: fanFullSpeedTemperature)
            case .advanced: points = fanAdvancedPoints ?? FanCurveEditor.defaultAdvanced
            }
        }
        return FanPolicy(points: points, onlyWhenLidClosed: fansOnlyWhenLidClosed)
    }

    public func clamped() -> Settings {
        var copy = self
        copy.batteryCutoffPercent = min(max(batteryCutoffPercent, Self.batteryCutoffRange.lowerBound), Self.batteryCutoffRange.upperBound)
        (copy.fanStartTemperature, copy.fanFullSpeedTemperature) =
            StandardCurve.clamped(start: fanStartTemperature, full: fanFullSpeedTemperature)
        copy.fanAdvancedPoints = fanAdvancedPoints.map { FanPolicy(points: $0).repaired().points }
        return copy
    }

    // Decoding keeps every setting that is present and falls back to the default for the rest,
    // so settings saved by an older build, or with an unknown value, still load.
    private enum CodingKeys: String, CodingKey {
        case autoOffTimer, lockScreenWhenLidClosed, turnOffWhenUnplugged, autoLowPowerOnBattery
        case batteryCutoffEnabled, batteryCutoffPercent, thermalCutoff, sleepAfterProtection
        case fanControlEnabled, fanCurveMode, fanStartTemperature, fanFullSpeedTemperature, fanAdvancedPoints
        case fansOnlyWhenLidClosed
        case launchAtLogin, showDockIcon, notificationsEnabled, menuBarIcon
    }

    /// Keys only older builds wrote. Read once at the update, never written.
    private enum LegacyKeys: String, CodingKey {
        /// Up to 0.1.2: "system", "curve" or "fullSpeed".
        case fanMode
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
        sleepAfterProtection = (try? c.decodeIfPresent(Bool.self, forKey: .sleepAfterProtection)) ?? sleepAfterProtection
        if c.contains(.fanControlEnabled) {
            fanControlEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .fanControlEnabled)) ?? fanControlEnabled
        } else {
            migrateFanMode(from: decoder)
        }
        fanCurveMode = (try? c.decodeIfPresent(FanCurveMode.self, forKey: .fanCurveMode)) ?? fanCurveMode
        fanAdvancedPoints = (try? c.decodeIfPresent([FanPoint].self, forKey: .fanAdvancedPoints)) ?? fanAdvancedPoints
        fanStartTemperature = (try? c.decodeIfPresent(Int.self, forKey: .fanStartTemperature)) ?? fanStartTemperature
        fanFullSpeedTemperature = (try? c.decodeIfPresent(Int.self, forKey: .fanFullSpeedTemperature)) ?? fanFullSpeedTemperature
        fansOnlyWhenLidClosed = (try? c.decodeIfPresent(Bool.self, forKey: .fansOnlyWhenLidClosed)) ?? fansOnlyWhenLidClosed
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? launchAtLogin
        showDockIcon = (try? c.decodeIfPresent(Bool.self, forKey: .showDockIcon)) ?? showDockIcon
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? notificationsEnabled
        menuBarIcon = (try? c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIcon)) ?? menuBarIcon
    }

    /// Turns an older build's fan mode into the switch and the two curves, so nothing changes for the user.
    private mutating func migrateFanMode(from decoder: Decoder) {
        guard let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
              let mode = try? legacy.decodeIfPresent(String.self, forKey: .fanMode) else { return }
        switch mode {
        case "system":
            fanControlEnabled = false
        case "curve":
            fanControlEnabled = true
            fanCurveMode = .standard
        case "fullSpeed":
            fanControlEnabled = true
            fanCurveMode = .advanced
            fanAdvancedPoints = [40, 50, 60, 70, 80].map { FanPoint(temperature: $0, speed: 100) }
        default:
            break
        }
    }
}
