import AppKit
import SwiftUI
import ClamDownAppKit
import ClamDownUI

extension AboutInfo {
    /// The versions of this build and of the Mac it runs on.
    static var current: AboutInfo {
        let info = Bundle.main.infoDictionary
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var macOS = "\(system.majorVersion).\(system.minorVersion)"
        if system.patchVersion != 0 { macOS += ".\(system.patchVersion)" }
        return AboutInfo(appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
                         build: info?["CFBundleVersion"] as? String ?? "0",
                         macOSVersion: macOS)
    }
}

/// The About page: the app icon and its version, the state of updates, and the links.
struct AboutPage: View {
    @ObservedObject var updater: Updater
    private let info = AboutInfo.current
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        CDSettingsPage(header: { header }, content: {
            CDSection(String(localized: "Updates")) {
                CDRow(updater.status.title(), detail: updater.status.detail(now: Date())) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .cdButtonStyle(isAvailable ? .primary : .secondary)
                        .disabled(!updater.canCheckForUpdates)
                }
                CDSwitchRow(String(localized: "Check Automatically"),
                            detail: String(localized: """
                                Looks for a new version on GitHub once a day. Sends nothing about you or your Mac.
                                """),
                            isOn: $updater.checksAutomatically)
            }
            CDSection(String(localized: "Links"),
                      footer: String(localized: "Apache License 2.0 \u{00B7} Updates by Sparkle")) {
                LinkRow(String(localized: "Website"), destination: AboutInfo.website)
                LinkRow(String(localized: "Release Notes"), destination: AboutInfo.releaseNotes)
                LinkRow(String(localized: "Source Code"), destination: AboutInfo.sourceCode)
                LinkRow(String(localized: "Report a Problem"), destination: info.reportProblemURL)
            }
        })
        .onAppear { updater.refreshStatus() }
    }

    private var isAvailable: Bool {
        if case .available = updater.status { return true }
        return false
    }

    private var header: some View {
        VStack(spacing: 6) {
            CDAppIcon(size: 96, glow: true)
                .padding(.bottom, 8)
            Text("ClamDown").font(.title2.bold())
            Text("Keeps a closed MacBook awake for your coding agents.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(info.versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(copied ? String(localized: "Copied") : String(localized: "Copy"), action: copyVersion)
                    .cdButtonStyle(.secondary)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    /// Puts the version and the macOS version on the pasteboard, and says so on the button for two seconds.
    private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info.clipboardText, forType: .string)
        copied = true
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}

/// A row that opens a web page.
private struct LinkRow: View {
    let title: String
    let destination: URL

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: CDMetric.rowSpacing)
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
