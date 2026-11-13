import Foundation

/// The strings and links on the About page.
public struct AboutInfo: Equatable, Sendable {
    public static let website = URL(string: "https://clamdown.app")!
    public static let releaseNotes = URL(string: "https://github.com/delef/ClamDown/releases")!
    public static let sourceCode = URL(string: "https://github.com/delef/ClamDown")!

    public let appVersion: String
    public let build: String
    public let macOSVersion: String

    public init(appVersion: String, build: String, macOSVersion: String) {
        self.appVersion = appVersion
        self.build = build
        self.macOSVersion = macOSVersion
    }

    public var versionLine: String { "Version \(appVersion) (\(build))" }

    /// What "Copy version info" puts on the pasteboard.
    public var clipboardText: String { "ClamDown \(appVersion) (\(build)), macOS \(macOSVersion)" }

    /// A new GitHub issue with both versions already in its body.
    public var reportProblemURL: URL {
        var components = URLComponents(string: "https://github.com/delef/ClamDown/issues/new")!
        components.queryItems = [URLQueryItem(name: "body",
                                              value: "\n\n---\nClamDown \(appVersion) (\(build))\nmacOS \(macOSVersion)")]
        return components.url!
    }
}

/// Where the update check stands, as the About page words it.
public enum UpdateStatus: Equatable, Sendable {
    case available(String)
    case checking
    case upToDate(lastCheck: Date?)

    public func title() -> String {
        switch self {
        case .available(let version): "Version \(version) is available"
        case .checking: "Checking…"
        case .upToDate: "You have the latest version"
        }
    }

    /// "Checked 5 minutes ago"; nil when there is no check to report. The app's copy is English, so the wording is
    /// too, whatever language the Mac runs in.
    public func detail(now: Date) -> String? {
        guard case .upToDate(let lastCheck?) = self else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateTimeStyle = .named
        return "Checked " + formatter.localizedString(for: lastCheck, relativeTo: now)
    }
}
