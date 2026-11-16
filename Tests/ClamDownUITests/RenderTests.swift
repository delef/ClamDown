import AppKit
import SwiftUI
import Testing
@testable import ClamDownUI

/// Renders building blocks without a window (`ImageRenderer`) and compares them with reference images in `Snapshots/`,
/// in light and dark. A missing reference, or `CLAMDOWN_RECORD_SNAPSHOTS=1`, writes the image and fails the test, so
/// a new reference is always looked at before it is committed. References are made on macOS 27, as CI runs.
@MainActor @Suite struct RenderTests {
    /// The share of pixels that may differ, for antialiasing between machines. One changed digit is about 0.1 %.
    static let allowedShare = 0.0002
    /// How far one colour channel may move (0–255) before the pixel counts as different.
    static let channelTolerance = 24

    /// The rows the kit lays out itself. The card around them is the system form's, which `ImageRenderer` does not
    /// draw, so it is checked in the settings pictures instead.
    @Test(arguments: [ColorScheme.light, .dark]) func rows(scheme: ColorScheme) throws {
        try check("rows", scheme: scheme) {
            VStack(alignment: .leading, spacing: 12) {
                CDValueRow("Hottest", value: "65 °C (CPU)")
                CDValueRow("Controlled By", value: "ClamDown", tone: .success)
                CDRow("Reinstall Helper", detail: "Installs the helper from this version again.") { Text("Button") }
                CDNote("Fan control paused. ClamDown takes the fans again in a moment.", tone: .warning)
            }
            .frame(width: 420)
            .padding(16)
        }
    }

    @Test func darkDiffersFromLight() throws {
        let view = CDValueRow("Hottest", value: "65 °C").frame(width: 300).padding(8)
        let light = try #require(Self.render(view, scheme: .light))
        let dark = try #require(Self.render(view, scheme: .dark))
        #expect(Self.differingShare(light, dark) > 0.1, "the dark render looks like the light one")
    }

    // MARK: - Helpers

    private func check(_ name: String, scheme: ColorScheme, @ViewBuilder _ view: () -> some View,
                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let image = try #require(Self.render(view(), scheme: scheme))
        let url = Self.directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
        let record = ProcessInfo.processInfo.environment["CLAMDOWN_RECORD_SNAPSHOTS"] == "1"
        guard !record, let reference = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            try Self.png(image).write(to: url)
            Issue.record("Wrote \(url.lastPathComponent). Look at it, commit it, and run the tests again.",
                         sourceLocation: sourceLocation)
            return
        }
        let share = Self.differingShare(image, reference)
        if share > Self.allowedShare {
            let failed = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("failed-\(url.lastPathComponent)")
            try? Self.png(image).write(to: failed)
            Issue.record("\(url.lastPathComponent): \(String(format: "%.3f", share * 100)) % of pixels differ. New render: \(failed.path)",
                         sourceLocation: sourceLocation)
        }
    }

    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Snapshots")

    static func render(_ view: some View, scheme: ColorScheme) -> CGImage? {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var image: CGImage?
        // AppKit colours resolve against the current drawing appearance, SwiftUI ones against the environment.
        appearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)))
            renderer.scale = 2
            image = renderer.cgImage
        }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// The share of pixels whose colour moved by more than the tolerance. Different sizes count as all different.
    static func differingShare(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        let pa = pixels(a), pb = pixels(b)
        var differing = 0
        for index in stride(from: 0, to: pa.count, by: 4) {
            for channel in 0..<4 where abs(Int(pa[index + channel]) - Int(pb[index + channel])) > channelTolerance {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(a.width * a.height)
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
