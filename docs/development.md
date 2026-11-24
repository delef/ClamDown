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

- Every rule that decides the fan speed (what the curve follows, the curve, the safety floor, the full-speed overrides and how fast the fans may slow down) lives in `Sources/ClamDownShared/FanRules/`; `FanDecision.swift` lists the steps in order. Which SMC keys feed each sensor group and each chip's die zone is in `Sources/ClamDownSensors/SensorKeys.swift`.
- A change that users from an older build may want to keep as it was gets a one-time question: call `ChangeQuestionWindow.ask(_:showIf:onNew:onOld:)` at launch (see `askAboutChanges()` in `Sources/ClamDown/AppDelegate.swift`) with a new, never reused id. It shows only after an update, only once, and only when `showIf` holds.
- User-visible text lives in `Resources/Localizable.xcstrings`, which `scripts/sync-strings.sh` refreshes from the code.
- What the app does for its users, with every default, is in [how-it-works.md](how-it-works.md).

## Tests

- `scripts/coverage.sh` runs the tests with code coverage and fails when the helper, sensor, shared or app module drops under its limit; CI runs it on every pull request.
- `swift test --repeat-until fail --maximum-repetitions 100` looks for a test that fails only now and then; the `flaky` workflow does the same every week.
- The sensor tests replay real SMC key dumps from `Tests/ClamDownSensorsTests/Fixtures`; `.build/debug/ClamDownFanProbe keys "<machine>"` takes a new one without root.
- The helper tests replay real sensor recordings from `Tests/ClamDownHelperKitTests/Fixtures`; `.build/debug/ClamDownFanProbe sensors <seconds>` records one without root and without touching the fans. Add a recording of every new situation, such as a Mac in a bag.

## Logs

ClamDown writes down what it changes and why, so a problem on a user's Mac can be traced afterwards. Up to 0.2.0 it kept nothing: the helper wrote its few errors to stderr, which launchd sends nowhere, and the app logged at `info`, which macOS keeps in memory only. A look at a Mac running 0.2.0 with the lid closed could see the fans now, not what they had done for the two hours before (agent, 2026-11-23). The agent proposed the two records below and the owner agreed: «Да» (owner, 2026-11-24).

- **The system log**, subsystem `app.clamdown`, for changes and failures: the mode switching on or off with who or what asked, who drives the fans and why that changed, faults, full-speed overrides, recovery, the sleep owed to an abandoned Mac, the turn-on steps and what the user was told. Changes are `notice` and failures `error`, the levels macOS keeps on disk for some days; `info` is only for what repeats on a timer. Each entry is written when something changes, never on every tick, and carries its cause and the values behind it. The helper's categories are `JournalTopic`; the app's are `turn-on`, `mode` and `fans`. Read it with `/usr/bin/log show --predicate 'subsystem == "app.clamdown"' --last 3d --info`: zsh, the shell macOS starts, has a `log` of its own that takes no arguments.
- **The fan trace**, `/Library/Logs/ClamDown/fans-<UTC hour>.csv`: every fan tick's readings, the temperature the curve followed, the speed asked for, the override, each fan's speed and target, and what the tick did. One file per hour, the last 24 hours kept, an hour capped at 2 MB (`FanTraceFile`). A file's header names its columns, and those follow the sensor groups, so a helper updated mid-hour goes on in `fans-<UTC hour>Z-2.csv` rather than write rows under a header that does not fit them (agent, 2026-11-24). Its first columns are a sensor recording's, so the sensor groups and die zones of a trace copied into `Tests/ClamDownHelperKitTests/Fixtures` replay in `SensorTraceTests` as they are; the hottest core and the lid do not replay yet. The system log was rejected for this (agent, 2026-11-24): about 29,000 lines a day would push the changes out, and they would not replay.
- Every value in both is public: temperatures, speeds, settings and error codes say nothing about the user beyond when the Mac ran and whether its lid was closed. On a path that changes the Mac's settings, the fans or the files the helper keeps, an error is never dropped with `try?`: write it down where it happens, once per new problem when it repeats on every tick.

## Release

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist.template`. Sparkle compares `CFBundleVersion`, so it must grow with every release.
2. `scripts/build-app.sh release`, then `scripts/notarize.sh` (notarizes and staples the app), then `scripts/make-dmg.sh` (packs it into a signed, notarized `build/ClamDown.dmg`). Notarization uploads the app and the disk image to Apple and needs a `notarytool` keychain profile (`xcrun notarytool store-credentials`).
3. `scripts/make-appcast.sh` signs the disk image with the Sparkle EdDSA key and writes `build/appcast.xml`. It refuses to finish if the signature does not match `SUPublicEDKey` in the app. The private key lives outside the repository, in `CLAMDOWN_SPARKLE_KEY_FILE` (default `~/.config/clamdown/sparkle-ed25519.key`).
4. `gh release create vX.Y.Z build/ClamDown.dmg build/appcast.xml`. Installed copies find the new version through `releases/latest/download/appcast.xml`.

`scripts/stats.sh` prints GitHub's download counters for each release: disk image downloads, and update checks, which approximate how many copies are in use each day.
