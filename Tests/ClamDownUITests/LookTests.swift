import Testing
@testable import ClamDownUI

@Test func glassFromMacOS26() { #expect(CDLook.resolve(osMajorVersion: 26, forceClassic: false) == .glass) }
@Test func glassOnLaterVersions() { #expect(CDLook.resolve(osMajorVersion: 27, forceClassic: false) == .glass) }
@Test func classicBefore26() { #expect(CDLook.resolve(osMajorVersion: 15, forceClassic: false) == .classic) }
@Test func forcedClassicWins() { #expect(CDLook.resolve(osMajorVersion: 27, forceClassic: true) == .classic) }
