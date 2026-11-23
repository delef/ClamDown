# How ClamDown works

What ClamDown does, with every default and limit. The [README](../README.md) has the short version.

## First run

The first launch opens a setup assistant. It takes about a minute:

1. **Allow the helper.** ClamDown needs a small root helper to change sleep settings and drive the fans. "Allow…" registers it and opens System Settings > General > Login Items & Extensions; switch ClamDown on there. The assistant notices by itself and comes back to the front.
2. **Notifications** (optional). With the lid closed you cannot see the menu, so a notification tells you when ClamDown switched itself off.
3. **Launch at Login** (optional), with a list of the protection that is already on.
4. **Turn On Now**, or Done.

You can close the assistant at any step; the menu then offers "Finish Setup…". Settings > Helper > Setup Assistant opens it again.

ClamDown is a universal app for Apple Silicon and Intel Macs running macOS 13 or later, verified on Apple Silicon; fan control needs Apple Silicon.

## Switching on and off

- One switch in the menu bar. Filled icon: on. Outline icon: off. The icon is a closed laptop (the default), with a moon above it when off and rays when on, or a cup (setting, on the Appearance page). A user who updates from 0.1.2 or earlier keeps the cup, the default until then, and is asked once whether to switch; "Keep the Cup", its card or Escape keeps it. An update is told from a new install by what earlier builds left on the Mac: stored settings, 0.1.2's fan-default mark, the helper ClamDown registered or a finished setup. A user of 0.1.0 or 0.1.1 who never changed a setting and never registered the helper left none of these, so gets the laptop without being asked. While ClamDown is on for a set time, a small clock sits in the icon's corner.
- "Turn On For" starts a timed session (30 minutes to 8 hours, or until switched off). While ClamDown is on, "Turn Off In" changes when it ends, counting from now.
- The settings window has the same switch at the top of the sidebar, next to the app's name and state, with a timer button for "Turn On For" and "Turn Off In".
- While on, closing the lid does not sleep the Mac. Running processes and network connections carry on.
- While on, closing the lid locks the screen (setting, on by default), so the Mac does not open without a password.
- On battery, it switches on Low Power Mode for the battery profile (setting, on by default) and puts your previous value back when it switches off.

## Cooling

macOS keeps a closed MacBook's fans near their lowest speed even when the chip is hot, and lets an open one run hot before they speed up. ClamDown drives the fans along a curve instead. Fan control needs Apple Silicon; on an Intel Mac the Cooling page only shows the readings.

**When.** Fan Control decides when ClamDown drives the fans, and the setup assistant asks once:

- **With Lid Closed** (default): while ClamDown is on and the lid is closed. With the lid open, macOS keeps the fans quiet while you work.
- **Always**: with the lid open too, also while ClamDown is off. Cooler, and louder. It needs the app running and the helper set up.
- **Never**: macOS keeps the fans.

**What the curve follows.** The hottest of the CPU, GPU, battery, SSD, Wi-Fi and airflow sensors.

- The CPU and GPU count the way macOS's own fan control reads them: as the temperature of the chip's die zone (SMC keys `Tf14` and `Tf24`, confirmed against `TCDX` on every reading), averaged over about half a minute. A zone runs about 14 °C under the hottest core and barely moves when a few cores spike for a few seconds, so a short burst does not make the fans roar. Where macOS waits until a zone nears about 76 °C, ClamDown follows its own curve from 40 °C.
- On a Mac without the zone keys, a chip counts as its hottest sensor averaged over about a minute.
- The battery, SSD, Wi-Fi and airflow sensors count as read, without averaging, so a Mac warming in a bag reaches the fans at once.

**How fast.** The fans run at the faster of two rules:

- **The curve.** Standard has two points: by default the fans speed up from 40 °C and reach full speed at 70 °C (both settings). Advanced has five points you drag on a chart.
- **The safety floor**, which ClamDown never goes under: from 70 °C the fans rise in a straight line to full speed at 95 °C.

There is no separate rule for the case. Version 0.1.3 had one, on the airflow sensors (full speed at 44 °C), but those sensors sit by the heatsink and follow the chips' load: they ran the fans at full speed at about 50 °C while the case felt cold.

**Full speed whatever the rules say** when a CPU core sits at its limit (100 °C for 10 seconds), when the battery reaches 45 °C (until it has been under 43 °C for 30 seconds), or when macOS reports the Mac as hot.

Fan speed rises at once and falls by at most 150 rpm every 3 seconds, so short dips in load do not make the fans hunt.

If ClamDown cannot control the fans, it hands them back to macOS and tries again by itself. When it has stopped, it tells you once: a line in the menu and, with notifications on, one notification.

## Switching itself off

It switches itself off and lets the Mac sleep when:

- the battery falls to the cut-off (default 10%, setting: 5–50% or off). This applies only on battery, so a charging Mac at 5% stays awake; Macs without a battery have no battery rule;
- the system thermal state reaches the cut-off (default `serious`, setting: `fair`, `serious`, `critical`, or never);
- the battery has stayed at or above its limit for the hold time (default 55 °C for 1 minute, setting: 50–60 °C, 30 seconds to 5 minutes, or off);
- the power adapter is unplugged (setting, off by default);
- the timer ends (setting: never, or 30 minutes to 8 hours).

After a battery or heat switch-off with nobody at the Mac, it puts the Mac to sleep (setting, on by default), so an app that keeps the Mac awake cannot leave it running in a bag. Nobody is at the Mac when the lid is closed, no external display is connected, and the keyboard and pointer have been still for a minute. If the Mac does not fall asleep, ClamDown asks again, three times in all. It leaves the Mac alone when the lid is open, a display is connected, or someone has just typed.

It posts a notification that names the reason whenever it switches itself off (setting, on by default). When you open the lid after ClamDown let the Mac sleep, it tells you why, in a window that stays until you close it.

## The helper and its safeguards

ClamDown changes sleep settings and drives the fans through a small root helper.

- **Watchdog.** While on, the app sends the helper a heartbeat about every 30 seconds. If the heartbeat stops for about 90 seconds, or the app quits or crashes, the helper puts sleep, Low Power Mode and the fans back as they were, by itself. If the lid is then closed for sleep and the keyboard and pointer have been still for a minute, the helper also puts the Mac to sleep; it stops trying when someone opens the lid, and after five minutes.
- **Fans.** The helper hands the fans back to macOS whenever the mode switches off for any reason, you set Fan Control to Never, the lid opens (with "With Lid Closed"), the app quits or stops checking in while ClamDown is off (with "Always"), the Mac goes to sleep while ClamDown is off, no temperature can be read, or it cannot set a fan; after an error it tries again by itself. It records that it holds the fans before it touches them, so a helper restart after a crash hands them back too. It applies the safety floor itself, so a wrong curve from the app cannot take the fans below it, and it never sets a fan outside that fan's own minimum and maximum speed.
- **Reboots.** The helper runs at load and resets any leftover state every time it starts.
- **Original settings.** The first time ClamDown switches on, the helper records your sleep and Low Power Mode settings and never replaces that record. Remove Helper in Settings > Helper puts them back first; if they cannot be put back, the helper stays installed.
- **Narrow helper.** The helper can only keep the Mac from sleeping or let it sleep again, turn Low Power Mode on or off for the battery profile, read both values, read the temperature sensors and fans, and set fan speeds within each fan's own range while the mode is on, or while the app keeps asking for it with Fan Control set to Always; if handing the fans back to macOS fails, it runs them at full speed until the hand-back works. It accepts connections only from the signed ClamDown app (same Team ID, same bundle identifier).

When ClamDown cannot work until you do something, for example after macOS took the helper's approval back, the menu bar icon carries a small exclamation mark and the Dock icon, when shown, a "!" badge.

## Settings

Six pages: General, Sleep, Protection, Cooling, Appearance and Helper.

- The Cooling page has the Fan Control choice, the curve chart, the hottest temperature and each sensor group's (as the curve follows them), each fan's speed and whether ClamDown or macOS controls the fans.
- The Helper page shows the helper's state and can reinstall or remove it. Settings > Helper > Setup Assistant opens the setup assistant again.

## Updates

ClamDown checks GitHub for a new version once a day and asks before it installs one. The check downloads the release feed (`appcast.xml`) from GitHub Releases and sends nothing about you or your Mac. Turn it off, or check by hand, in Settings > General > Updates, or choose Check for Updates… in the menu.

Updates go through [Sparkle](https://sparkle-project.org). Each update must carry an EdDSA signature from the ClamDown release key, and macOS checks the Developer ID signature and notarization as usual. Version 0.1.0 has no updater: install a newer release by hand once.
