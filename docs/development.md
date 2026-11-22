# Developing ClamDown

## Build from source

You need Xcode with a Swift 6 toolchain and a code-signing identity.

```
cp Config/Signing.xcconfig.example Config/Signing.local.xcconfig
# edit Config/Signing.local.xcconfig: your bundle ID and signing identities
swift test
scripts/build-app.sh debug      # Apple Development identity; use "release" for Developer ID
scripts/verify-bundle.sh
```

The helper only talks to an app signed with the same Team ID as itself, so a build signed with your own identity works with its own helper and with no one else's.

## Where things live

- Every rule that decides the fan speed (what the curve follows, the curve, the safety floor, the case rule, the full-speed overrides and how fast the fans may slow down) lives in `Sources/ClamDownShared/FanRules/`; `FanDecision.swift` lists the steps in order. Which SMC keys feed each sensor group and each chip's die zone is in `Sources/ClamDownSensors/SensorKeys.swift`.
- A change that users from an older build may want to keep as it was gets a one-time question: call `ChangeQuestionWindow.ask(_:showIf:onNew:onOld:)` at launch (see `askAboutChanges()` in `Sources/ClamDown/AppDelegate.swift`) with a new, never reused id. It shows only after an update, only once, and only when `showIf` holds.
- User-visible text lives in `Resources/Localizable.xcstrings`, which `scripts/sync-strings.sh` refreshes from the code.
- What the app does for its users, with every default, is in [how-it-works.md](how-it-works.md).

## Tests

- `scripts/coverage.sh` runs the tests with code coverage and fails when the helper, sensor, shared or app module drops under its limit; CI runs it on every pull request.
- `swift test --repeat-until fail --maximum-repetitions 100` looks for a test that fails only now and then; the `flaky` workflow does the same every week.
- The sensor tests replay real SMC key dumps from `Tests/ClamDownSensorsTests/Fixtures`; `.build/debug/ClamDownFanProbe keys "<machine>"` takes a new one without root.
- The helper tests replay real sensor recordings from `Tests/ClamDownHelperKitTests/Fixtures`; `.build/debug/ClamDownFanProbe sensors <seconds>` records one without root and without touching the fans. Add a recording of every new situation, such as a Mac in a bag.

## Release

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist.template`. Sparkle compares `CFBundleVersion`, so it must grow with every release.
2. `scripts/build-app.sh release`, then `scripts/notarize.sh` (notarizes and staples the app), then `scripts/make-dmg.sh` (packs it into a signed, notarized `build/ClamDown.dmg`). Notarization uploads the app and the disk image to Apple and needs a `notarytool` keychain profile (`xcrun notarytool store-credentials`).
3. `scripts/make-appcast.sh` signs the disk image with the Sparkle EdDSA key and writes `build/appcast.xml`. It refuses to finish if the signature does not match `SUPublicEDKey` in the app. The private key lives outside the repository, in `CLAMDOWN_SPARKLE_KEY_FILE` (default `~/.config/clamdown/sparkle-ed25519.key`).
4. `gh release create vX.Y.Z build/ClamDown.dmg build/appcast.xml`. Installed copies find the new version through `releases/latest/download/appcast.xml`.

`scripts/stats.sh` prints GitHub's download counters for each release: disk image downloads, and update checks, which approximate how many copies are in use each day.
