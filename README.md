# ClamDown

A macOS menu bar app that keeps a MacBook awake with the lid closed, so terminal and agent sessions keep running without a cloud machine. It switches itself off on low battery or when the Mac runs hot.

Caffeine-style tools hold a power assertion, and that does not stop the Mac from sleeping when the lid closes. ClamDown uses `pmset disablesleep`, which does, and wraps it in the safety rules a closed laptop needs.

## What it does

- One switch in the menu bar. Filled icon: on. Outline icon: off. "Turn On For" starts a timed session. The icon style is a setting.
- While on, closing the lid does not sleep the Mac. Running processes and network connections carry on.
- While on, closing the lid locks the screen (setting, on by default), so the Mac does not open without a password.
- On battery, it switches on Low Power Mode for the battery profile (setting, on by default) and puts your previous value back when it switches off.
- It switches itself off and lets the Mac sleep when:
  - the battery falls to the cut-off (default 10%, setting: 5–50% or off), or
  - the system thermal state reaches the cut-off (default `serious`, setting: `fair`, `serious`, `critical`, or never), or
  - the power adapter is unplugged (setting, off by default), or
  - the timer ends (setting: never, or 30 minutes to 8 hours).
- It posts a notification that names the reason whenever it switches itself off (setting, on by default).

Settings has five pages: General, Sleep, Protection, Appearance and Helper. The Helper page shows the helper's state and can reinstall or remove it.

## Requirements

macOS 13 or later. Verified on Apple Silicon.

## Install

Download the notarized `ClamDown.zip` from the GitHub Releases page, unzip it, and move `ClamDown.app` to `/Applications`. Or build it yourself (see below).

## First run

ClamDown needs a small root helper to run `pmset`. The first click on the switch registers it, and macOS asks you to approve it: open System Settings > General > Login Items & Extensions and enable ClamDown. Click the switch again afterwards.

## Safety behavior

- **Cut-offs.** Battery and thermal cut-offs switch ClamDown off and let the Mac sleep. The battery rule applies only while running on battery, so a charging Mac at 5% stays awake. Macs without a battery have no battery rule.
- **Watchdog.** While on, the app sends the helper a heartbeat about every 30 seconds. If the heartbeat stops for about 90 seconds, or the app quits or crashes, the helper resets `disablesleep` and Low Power Mode by itself.
- **Reboots.** The helper runs at load and resets any leftover state every time it starts.
- **Narrow helper.** The helper can only turn `disablesleep` on or off, turn Low Power Mode on or off for the battery profile, and read both values. It accepts connections only from the signed ClamDown app (same Team ID, same bundle identifier).

## Security note

ClamDown does not lock your screen. With the mode on, opening the lid brings you straight back to an unlocked session. If you leave the Mac unattended, lock it first (Control-Command-Q).

## Uninstall

Switch ClamDown off, quit it, then delete the app. If the Mac refuses to sleep afterwards, or Low Power Mode is wrong, put them back by hand:

```
sudo pmset disablesleep 0
sudo pmset -b lowpowermode 0   # or 1, whichever you had before
```

## Build from source

You need Xcode with a Swift 6 toolchain and a code-signing identity.

```
cp Config/Signing.xcconfig.example Config/Signing.local.xcconfig
# edit Config/Signing.local.xcconfig: your bundle ID and signing identities
swift test
scripts/build-app.sh debug      # Apple Development identity; use "release" for Developer ID
scripts/verify-bundle.sh
```

`scripts/build-app.sh release` followed by `scripts/notarize.sh` produces a notarized `build/ClamDown.zip`. Notarization uploads the app to Apple and needs a `notarytool` keychain profile (`xcrun notarytool store-credentials`).

The helper only talks to an app signed with the same Team ID as itself, so a build signed with your own identity works with its own helper and with no one else's.

## License

Apache License 2.0. See [LICENSE](LICENSE).
