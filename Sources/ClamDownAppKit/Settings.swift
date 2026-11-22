import Foundation
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

    /// The sessions offered wherever the user turns ClamDown on for a set time ("Turn On For"); "Until Switched Off"
    /// comes after them.
    public static let sessions: [AutoOffTimer] = [.minutes30, .hour1, .hours2, .hours4, .hours8]

    /// Nil means the mode stays on until something else switches it off.
    public var duration: Duration? {
        self == .never ? nil : .seconds(rawValue * 60)
    }

    public var title: String {
        switch self {
        case .never: String(localized: "Never")
        case .minutes30: String(localized: "30 minutes")
        case .hour1: String(localized: "1 hour")
        case .hours2: String(localized: "2 hours")
        case .hours4: String(localized: "4 hours")
        case .hours8: String(localized: "8 hours")
        }
    }
}

/// How long the battery must stay at or above its limit before ClamDown switches off.
public enum BatteryHeatHold: Int, Codable, CaseIterable, Sendable {
    case seconds30 = 30
    case minute1 = 60
    case minutes2 = 120
    case minutes5 = 300

    /// In seconds.
    public var duration: Double { Double(rawValue) }

    public var title: String {
        switch self {
        case .seconds30: String(localized: "30 seconds")
        case .minute1: String(localized: "1 minute")
        case .minutes2: String(localized: "2 minutes")
        case .minutes5: String(localized: "5 minutes")
        }
    }
}

/// The symbol shown in the menu bar. Each style has a plain and a filled form for off and on.
/// Two styles (owner, 2026-11-22: "оставляем только две"): the Cup that every release so far had as its default,
/// and the drawn Lid. Eye, Bolt and Sun were dropped; a setting that names one of them reads as the default.
public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable {
    case cup, lid

    /// The names `clamdown.lid` and `clamdown.lid.fill` are not SF Symbols: the app draws them itself.
    public var offSymbol: String {
        switch self {
        case .cup: "cup.and.saucer"
        case .lid: "clamdown.lid"
        }
    }

    public var onSymbol: String { offSymbol + ".fill" }

    public var title: String {
        switch self {
        case .cup: String(localized: "Cup")
        case .lid: String(localized: "Lid")
        }
    }
}

/// When ClamDown drives the fans.
public enum FanControlMode: String, Codable, CaseIterable, Sendable {
    /// Never: macOS keeps the fans.
    case never
    /// While ClamDown is on and the lid is closed, where macOS would leave the fans near idle.
    case lidClosed
    /// Whenever the app runs and the helper is set up: with the lid open too, and while ClamDown is off.
    case always

    public var title: String {
        switch self {
        case .never: String(localized: "Never")
        case .lidClosed: String(localized: "With Lid Closed")
        case .always: String(localized: "Always")
        }
    }

    /// One sentence on what the mode does, for Settings and the setup assistant.
    public var detail: String {
        switch self {
        case .never:
            String(localized: "macOS keeps the fans, also with the lid closed.")
        case .lidClosed:
            String(localized: """
                While ClamDown is on and the lid is closed. With the lid open, macOS keeps the fans quiet while you work.
                """)
        case .always:
            String(localized: """
                With the lid open too, also while ClamDown is off. macOS lets the Mac run hot before its fans speed up.
                """)
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
    public static let batteryHeatLimitRange = 50...60

    // Sleep
    public var autoOffTimer: AutoOffTimer = .never
    public var lockScreenWhenLidClosed = true
    public var turnOffWhenUnplugged = false
    public var autoLowPowerOnBattery = true

    // Protection
    public var batteryCutoffEnabled = true
    public var batteryCutoffPercent = 10
    public var thermalCutoff: ThermalCutoff = .serious
    /// Switch off when the battery has stayed this hot (whole °C) for `batteryHeatHold`.
    public var batteryHeatCutoffEnabled = true
    public var batteryHeatLimit = 55
    public var batteryHeatHold: BatteryHeatHold = .minute1
    /// After a battery or heat switch-off with the lid closed, put the Mac to sleep at once.
    public var sleepAfterProtection = true

    // Cooling
    public var fanControl: FanControlMode = .lidClosed
    public var fanCurveMode: FanCurveMode = .standard
    /// The Standard curve's two temperatures.
    public var fanStartTemperature = StandardCurve.defaultStart
    public var fanFullSpeedTemperature = StandardCurve.defaultFull
    /// The Advanced curve's five points. Nil until Advanced is first chosen.
    public var fanAdvancedPoints: [FanPoint]?
    /// The case rule's two temperatures: the fans speed up with the airflow sensors from the first, full at the second.
    public var caseStartTemperature = CaseRamp.defaultStart
    public var caseFullSpeedTemperature = CaseRamp.defaultFull

    // General
    public var launchAtLogin = false
    public var showDockIcon = false
    public var notificationsEnabled = true

    // Appearance
    public var menuBarIcon: MenuBarIconStyle = .cup

    public init() {}

    /// False leaves the fans to macOS. Switching it on picks Only With Lid Closed, unless a mode that drives the
    /// fans is already chosen.
    public var fanControlEnabled: Bool {
        get { fanControl != .never }
        set { fanControl = newValue ? (fanControl == .never ? .lidClosed : fanControl) : .never }
    }

    /// What the helper gets for the fans. No points means fan control is off.
    public var fanPolicy: FanPolicy {
        FanPolicy(points: fanControlEnabled ? fanCurvePoints : [], onlyWhenLidClosed: fanControl != .always,
                  caseRamp: caseRamp)
    }

    public var caseRamp: CaseRamp {
        CaseRamp(start: caseStartTemperature, full: caseFullSpeedTemperature).clamped()
    }

    /// The curve of the visible mode, whether fan control is on or not: what the Cooling page's chart shows.
    public var fanCurvePoints: [FanPoint] {
        switch fanCurveMode {
        case .standard: StandardCurve.points(start: fanStartTemperature, full: fanFullSpeedTemperature)
        case .advanced: Self.validAdvanced(fanAdvancedPoints) ?? FanCurveEditor.defaultAdvanced
        }
    }

    public func clamped() -> Settings {
        var copy = self
        copy.batteryCutoffPercent = min(max(batteryCutoffPercent, Self.batteryCutoffRange.lowerBound), Self.batteryCutoffRange.upperBound)
        copy.batteryHeatLimit = min(max(batteryHeatLimit, Self.batteryHeatLimitRange.lowerBound), Self.batteryHeatLimitRange.upperBound)
        (copy.fanStartTemperature, copy.fanFullSpeedTemperature) =
            StandardCurve.clamped(start: fanStartTemperature, full: fanFullSpeedTemperature)
        copy.fanAdvancedPoints = Self.validAdvanced(fanAdvancedPoints).map { FanPolicy(points: $0).repaired().points }
        (copy.caseStartTemperature, copy.caseFullSpeedTemperature) = (caseRamp.start, caseRamp.full)
        return copy
    }

    /// A stored Advanced list that is not exactly five points (corrupt or hand-edited) counts as absent, so it can
    /// never turn into an empty policy that switches the fans off while the switch shows On.
    private static func validAdvanced(_ points: [FanPoint]?) -> [FanPoint]? {
        guard let points, points.count == FanCurveEditor.advancedPointCount else { return nil }
        return points
    }

    // Decoding keeps every setting that is present and falls back to the default for the rest,
    // so settings saved by an older build, or with an unknown value, still load.
    private enum CodingKeys: String, CodingKey {
        case autoOffTimer, lockScreenWhenLidClosed, turnOffWhenUnplugged, autoLowPowerOnBattery
        case batteryCutoffEnabled, batteryCutoffPercent, thermalCutoff, sleepAfterProtection
        case batteryHeatCutoffEnabled, batteryHeatLimit, batteryHeatHold
        case fanControl, fanCurveMode, fanStartTemperature, fanFullSpeedTemperature, fanAdvancedPoints
        case caseStartTemperature, caseFullSpeedTemperature
        case launchAtLogin, showDockIcon, notificationsEnabled, menuBarIcon
    }

    /// Keys only older builds wrote. Read once at the update, never written.
    private enum LegacyKeys: String, CodingKey {
        /// Up to 0.1.2: "system", "curve" or "fullSpeed".
        case fanMode
        /// 0.1.3 builds before the fan control mode: a switch and Only With Lid Closed.
        case fanControlEnabled, fansOnlyWhenLidClosed
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
        batteryHeatCutoffEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .batteryHeatCutoffEnabled)) ?? batteryHeatCutoffEnabled
        batteryHeatLimit = (try? c.decodeIfPresent(Int.self, forKey: .batteryHeatLimit)) ?? batteryHeatLimit
        batteryHeatHold = (try? c.decodeIfPresent(BatteryHeatHold.self, forKey: .batteryHeatHold)) ?? batteryHeatHold
        if let mode = try? c.decodeIfPresent(FanControlMode.self, forKey: .fanControl) {
            fanControl = mode
        } else {
            migrateFanControl(from: decoder)
        }
        fanCurveMode = (try? c.decodeIfPresent(FanCurveMode.self, forKey: .fanCurveMode)) ?? fanCurveMode
        fanAdvancedPoints = Self.validAdvanced((try? c.decodeIfPresent([FanPoint].self, forKey: .fanAdvancedPoints)) ?? fanAdvancedPoints)
        fanStartTemperature = (try? c.decodeIfPresent(Int.self, forKey: .fanStartTemperature)) ?? fanStartTemperature
        fanFullSpeedTemperature = (try? c.decodeIfPresent(Int.self, forKey: .fanFullSpeedTemperature)) ?? fanFullSpeedTemperature
        caseStartTemperature = (try? c.decodeIfPresent(Int.self, forKey: .caseStartTemperature)) ?? caseStartTemperature
        caseFullSpeedTemperature = (try? c.decodeIfPresent(Int.self, forKey: .caseFullSpeedTemperature)) ?? caseFullSpeedTemperature
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? launchAtLogin
        showDockIcon = (try? c.decodeIfPresent(Bool.self, forKey: .showDockIcon)) ?? showDockIcon
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? notificationsEnabled
        menuBarIcon = (try? c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIcon)) ?? menuBarIcon
    }

    /// Turns an older build's fan settings into the mode and the two curves, so nothing changes for the user.
    /// Fan control that also ran with the lid open becomes Always, the nearest mode.
    private mutating func migrateFanControl(from decoder: Decoder) {
        guard let legacy = try? decoder.container(keyedBy: LegacyKeys.self) else { return }
        // 0.1.2 and the 0.1.3 builds before the mode both stored this next to their own fan switch.
        let lidOpenToo = (try? legacy.decodeIfPresent(Bool.self, forKey: .fansOnlyWhenLidClosed)) == false
        let driven: FanControlMode = lidOpenToo ? .always : .lidClosed
        if let enabled = try? legacy.decodeIfPresent(Bool.self, forKey: .fanControlEnabled) {
            fanControl = enabled ? driven : .never
            return
        }
        guard let mode = try? legacy.decodeIfPresent(String.self, forKey: .fanMode) else {
            fanControl = driven
            return
        }
        switch mode {
        case "system":
            fanControl = .never
        case "curve":
            fanControl = driven
            fanCurveMode = .standard
        case "fullSpeed":
            fanControl = driven
            fanCurveMode = .advanced
            fanAdvancedPoints = [40, 50, 60, 70, 80].map { FanPoint(temperature: $0, speed: 100) }
        default:
            break
        }
    }
}
