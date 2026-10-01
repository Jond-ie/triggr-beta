# Triggr

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**Triggr** is an Activator-lite for **rootless Dopamine on iOS 15–16**. Assign
actions to the Home, lock and volume buttons, Touch ID, the mute switch, status bar
taps, Home Screen icon flicks and shaking, or to events like plugging in a charger,
joining a Wi-Fi network, a battery level or a time of day. It's laid out like
Activator, and it stays light: the main library loads into SpringBoard only, and
nothing runs for a trigger that isn't assigned.

> AI assisted in development (Claude Code), all testing and debugging done by me on device.

## Screenshots

<p>
  <img src="screenshots/1-main.png" alt="Main page" width="200">
  <img src="screenshots/2-place.png" alt="A place: what's assigned, then every kind of trigger" width="200">
  <img src="screenshots/3-events.png" alt="Custom events" width="200">
  <img src="screenshots/4-picker.png" alt="Action picker: folded categories and search" width="200">
  <img src="screenshots/5-switches.png" alt="Switches: toggle, turn on or turn off" width="200">
  <img src="screenshots/6-all-assignments.png" alt="All Assignments, by trigger or by action" width="200">
  <img src="screenshots/7-options.png" alt="Options" width="200">
</p>

## Install

1. In **Sileo** (or Zebra): Sources → **+** → add `https://jond-ie.github.io/repo/`
   (or open [jond-ie.github.io/repo](https://jond-ie.github.io/repo/) on your device and tap **Add to Sileo**).
2. Install **Triggr**. Sileo installs **AltList** (BigBoss) and **PreferenceLoader**
   with it; if it can't find AltList, add BigBoss first.
3. Respring, then set it up in **Settings → Triggr**.

To remove it, uninstall **Triggr** in your package manager. Install from the repo,
not by building the source: the repo always has the current build.

## Supported devices

| Device | Status |
|---|---|
| **A11 and older (arm64) with Touch ID**, iOS 15–16 | Tested on iPhone 8 Plus (iOS 16.7) and iPhone 7 (iOS 15.8.6) |
| **A12 and newer** (iPhone XS / XR and later, all Face ID devices) | Included in the John's Repo build since 1.0.0~beta6 (arm64e), not confirmed on a device yet. If it lands you in safe mode, open Sileo and uninstall Triggr, then please [report it](../../issues/new/choose). |

With **Options → Replace Button Actions** on (the default), an assigned button
press runs instead of the button's own action, like Activator; unassigned presses
work as usual. Triggr leaves the presses that Emergency SOS counts to iOS. If you
rely on SOS, check it still starts with your setup.

## Building

Most people should install from [John's Repo](https://jond-ie.github.io/repo/).
To build it yourself you need:

- [Theos](https://theos.dev/docs/installation) with an iOS SDK (built against the
  iOS 16.5 SDK from [theos/sdks](https://github.com/theos/sdks)).
- The **rootless** package scheme (Dopamine, `/var/jb`).
- AltList's headers and framework are vendored in `vendor/` (for linking only), so nothing else is needed
  to compile. On the device, the package depends on `mobilesubstrate`,
  `preferenceloader`, `com.opa334.altlist` and iOS 15 or later.

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

The `.deb` lands in `packages/`. The Makefile builds arm64 only. Release builds
add a new-ABI arm64e slice for A12+, which needs Xcode's clang on macOS
(`make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless ARCHS="arm64 arm64e"`);
the Linux toolchain's arm64e output doesn't load on iOS 15–16.

## Bugs and feature requests

Please use [**Issues**](../../issues/new/choose):

- **Crash report:** Triggr or SpringBoard crashed, or you hit safe mode.
- **Bug report:** something doesn't work as expected.
- **Feature request:** ideas, or something from Activator you miss.

Always include your **device model, iOS version, jailbreak and Triggr version**.

### Getting a crash log

1. Open **Settings → Privacy & Security → Analytics & Improvements → Analytics Data**.
2. Find the entry from the time of the crash. Look for **SpringBoard**,
   **Preferences** or **Triggr** in the name.
3. Tap it, then share or copy the text into your crash report.

**Check before posting:** crash logs and exported setups can include personal
details. Examples are app names, Wi-Fi network or Bluetooth device names used in
your events, and shell commands. Remove anything you don't want public.

## Documentation

### Settings layout

Like Activator, but with less scrolling: every page fits on one screen until you
open something.

- **Main page:** the Enabled switch, the four places, All Assignments, Menus,
  Options, and Profiles & Sharing. Rows show how many assignments they hold.
- **A place** (Anywhere, At Home Screen, In Apps, At Lock Screen): what's already
  assigned there, then one row per kind of trigger. A place's own assignment
  replaces Anywhere's; with nothing set, a trigger's row shows `Anywhere: <actions>`.
- **The action picker:** actions are folded into categories (System, Switches,
  Media, Levels, Open, Text & Commands, Menus); a closed category shows what's
  picked inside it, and the search field finds any action. A switch asks whether
  to Toggle, Turn On or Turn Off.
- **Swipe left** to remove things: an assignment (from a place's Assigned list or
  All Assignments), a custom event, a menu, a profile.
- **All Assignments** lists every assignment, by trigger (grouped by place) or by
  action. Assigned rows show the trigger with what it runs underneath.

### Triggers

| Group | Triggers | Behaviour |
|---|---|---|
| Home Button | Single, Double, Triple, Short Hold, Long Hold | Replaces the system press when assigned (see **Replace Button Actions**). If Triple is assigned, a double press waits 0.35 s. |
| Touch ID | Light Double Tap; Finger Rest, Finger Match (Lock Screen) | Light Double Tap replaces Reachability; Finger Rest and Match run alongside unlocking. iOS doesn't report single taps or holds while unlocked. |
| Lock Button | Single, Double, Triple, Hold | An assigned Single Press or Hold replaces locking or the power-off slider. See **Lock button** below. |
| Volume Buttons | Up, Down, Up Hold, Down Hold, Up then Down, Down then Up, Press Both, Hold Both | A press replaces the volume step. A hold fires after 0.5 s. Up then Down (and the reverse) are two quick presses that run alongside. For Both, the first button may still move the volume one step. |
| Mute Switch | Silent, Ring, Toggled | Replaces muting / unmuting when assigned (see **Replace Button Actions**); the switch's position and the ringer can then differ until it's flipped back. |
| Status Bar | Tap, Double Tap | Home Screen and in apps (apps relay the tap to SpringBoard) |
| Home Screen Icons | Flick Up, Down, Left, Right | A quick flick that starts on an app or folder icon on the Home Screen or in the Dock. Flick Left / Right take over page swipes that start on an icon, Flick Down takes over the pull for Search. Widgets, the App Library and jiggle mode are left alone. |
| Motion | Shake Device | Uses iOS's own shake detection (the one behind Shake to Undo): no sensor runs for Triggr. Works while unlocked and awake. |
| Charger & Headphones | Charger, Headphones connected/disconnected | Observed only while assigned |
| State Changes | Wi-Fi on/off, joined/left a network, Bluetooth on/off, Low Power on/off, Device Locked/Unlocked, Screen Turned On/Off | Runs after the change. For 1 s after Triggr changes a state itself (for example toggling Wi-Fi), that kind of change is ignored so assignments can't loop; other changes still run. |
| Custom Events | A specific Wi-Fi network (joined/left), a specific Bluetooth device (connected/disconnected), battery rises above/drops below X %, an app opened, a scheduled time (every day / weekdays / weekends), a flick on one app's icon (runs instead of the plain flick in that direction) | Wi-Fi and Bluetooth are picked from your saved networks and paired devices. "Drops Below 20" runs at 19 %, "Rises Above 80" at 81 %; "Above 100" means fully charged. |

Devices without a Home button (Face ID) don't see the Home Button or Touch ID
groups, and the Lock Button is called the Side Button there (Top Button on iPad).
This is read from MobileGestalt's `HomeButtonType`, with `LAContext.biometryType`
as a fallback, so it doesn't depend on a passcode being set.

### Actions

- **System:** Go to Home Screen, App Switcher, Last App, Quit Current App, Control
  Center, Notification Center, Spotlight, Reachability, Siri, Take Screenshot,
  Vibrate, and Do Nothing (takes a trigger away from iOS without running anything).
- **Power:** Sleep (a lock button press: the screen turns off and the phone
  locks, as the button does), Lock Device (locks but leaves the screen on), Respring,
  Power Off Slider, Safe Mode, Restart, Power Off. Safe Mode restarts SpringBoard through ElleKit's own Safe Mode (no tweaks,
  Triggr included) until it's left from the Safe Mode screen. Restart and Power
  Off act at once, without asking, and the jailbreak stays off until Dopamine is
  run again; the picker warns before adding any of these.
- **Switches** (Toggle / Turn On / Turn Off): Flashlight, Wi-Fi, Bluetooth, Airplane
  Mode, Cellular Data, Do Not Disturb, Low Power Mode, Rotation Lock, Mute, Dark
  Mode, Night Shift, Auto-Brightness, Keep Screen Awake (until the next respring),
  Location Services.
- **Media:** Play/Pause, Next, Previous, Volume Up, Volume Down.
- **Levels:** Brightness %, Media Volume %, Ringer Volume %.
- **Open:** an app, a Settings page, a Shortcut, a URL.
- **Text & Commands:** Show Message, Speak Text, Run Command
  (`/var/jb/bin/sh -c` as **mobile**, inside SpringBoard, with an explicit PATH).
- **Menus:** a pop-up list of actions to choose from (Triggr → Menus).

Tick several actions to run them in order. **Order & Pauses** reorders them and
adds pauses between them. Tap an action there to add a pause after it. Pauses
left dangling after an action is removed are cleared automatically. Adding an
action that conflicts with the list shows a warning: something after Respring,
Toggle and On/Off for the same switch, or two full-screen panels without a pause.

### Replace Button Actions

**Options → Replace Button Actions** (on by default) decides what an assigned
button press does to the button's own action:

- **On:** it runs instead, like Activator: an assigned Home press doesn't go Home,
  an assigned volume press doesn't change the volume, an assigned lock press
  doesn't lock, an assigned mute switch flip doesn't mute. To keep the button's
  own action as well, add the matching action to the list (Go to Home Screen,
  App Switcher, Siri, Reachability, Volume Up / Down, Sleep, Power Off Slider,
  Mute On / Off).
- **Off:** every press reaches iOS untouched and Triggr's actions run alongside.

Touch ID Finger Rest / Match, volume holds and Up then Down always run alongside.

### Lock button

With Replace Button Actions on, the lock button works like Activator's sleep
button:

- An assigned **Single Press** runs instead of locking. With only Single Press
  assigned it runs at once; when Double or Triple Press is assigned too, presses
  wait 0.4 s after the last press to be counted.
- An assigned **Hold** runs instead of the power-off slider (the Power Off Slider
  action brings it back on another trigger).
- A count with nothing assigned is handed back to iOS after the wait, so an
  unassigned single press still locks.
- A press that starts on a dark screen always just wakes the phone.
- Four or more presses are never acted on. Triggr only skips iOS's reaction to a
  recognised press; the button-down events that Emergency SOS counts, the hold
  with a volume button and the force restart don't pass through it.
- Keep another way to lock, e.g. Lock Device on a different trigger.
- Like any assignment, it only replaces the button where it's assigned: a Single
  Press set At Home Screen leaves the button locking normally inside apps and on
  the Lock Screen. Assign it in Anywhere to replace it everywhere.

With Replace Button Actions off, every press reaches iOS and Triggr's actions run
alongside once the presses stop. Reset to Defaults turns it back on.

### Lock Screen

Apps, URLs, Shortcuts and Settings pages can't open over the Lock Screen, so they
wait until you unlock. iOS's own unlock action block
(`SBLockScreenManager setUnlockActionBlock:`) runs them once you authenticate. With
**Commands Need Passcode** on (the default), shell commands wait too when a
passcode is set.

### Extras

- **Profiles & Sharing:**
  - Save your setup as a profile and switch between profiles.
  - **Export** a setup as a `.json` file (share sheet), or **Import** one from
    Files. Import keeps only known settings and value types, shows a summary
    (assignments, menus, shell commands, URLs) and warns about shell commands
    before replacing anything. Export warns when the setup includes Wi-Fi or
    Bluetooth names or shell commands.
  - **Reset to Defaults** clears everything except saved profiles.
- **Options → Block List:** triggers are ignored inside chosen apps.
- **Options → Show Action Banners:** a small pill naming what just ran.

### API (for other tweaks and scripts)

Off by default: **Settings → Triggr → Options → Allow API**. Darwin notifications carry no
sender, so any process could post one. That's why the API can only run
**built-in actions, your assigned triggers and your menus**, never arbitrary shell
commands, URLs or apps. Profiles and imports never switch it on.

- Tweaks: `notify_post("com.johndie.triggr/api/run/<action>")`, `…/api/trigger/<trigger>`,
  `…/api/menu/<menu id>`.
- Command line: `triggr list`, `triggr run toggle.flashlight`,
  `triggr trigger statusbar.doubletap`, `triggr menu Quick`.
- Shortcuts: use the **Run Script Over SSH** action (host `127.0.0.1`, user
  `mobile`) with a `triggr` command. This needs OpenSSH.

There's no `triggr://` URL scheme. iOS only opens schemes that belong to an
installed app, and the request fails in the calling app before SpringBoard sees
it.

### Performance

Triggr is two libraries. The main one loads into SpringBoard only. Apps get a
tiny relay (it links nothing but UIKit) that reports their status bar taps and
shakes, and it sends nothing unless one of those triggers is assigned.

SpringBoard keeps the set of assigned triggers in memory. Every hook first checks
that set and returns straight away if its trigger isn't assigned. Events, timers,
icon gesture recognizers and API listeners exist only while something uses them,
and nothing reads the motion sensors. Settings changes arrive
by Darwin notification; nothing is polled. Open App launches through SpringBoard,
never with a synchronous LaunchServices call on the main thread.

### Notes and limits

- Verified on an iPhone 8 Plus (A11, arm64), iOS 16.7 and an iPhone 7 (A10), iOS
  15.8.6, both Dopamine. A12+ (arm64e) and Face ID devices are untested so far.
- **Untested:**
  - Volume Up then Down / Down then Up with the real buttons (the press logic is
    verified through code)
  - Restart and Power Off (running them would have dropped the test phone's
    jailbreak)
  - Siri beyond opening: the action presents Siri, but on the test phone Siri's
    own daemon (assistantd) crashes whenever a request starts, however Siri is
    opened, so it closes again at once there
  - Finger Rest and Finger Match
  - Status bar taps on the Lock Screen
  - Wired headphones
  - Devices without a passcode
  - Face ID devices
- **Menus** don't open while the device is locked.
- **Scheduled** events are skipped if iOS runs the timer more than 5 minutes late
  (e.g. while the phone sleeps).
- Taking an AirPod out of your ear can count as "Headphones Disconnected", because
  iOS moves audio to the speaker.
- Control Center's Wi-Fi button only disconnects from the network (Left Wi-Fi
  Network); Wi-Fi stays on.
- Flashlight *events* aren't offered: SpringBoard can't read the Control Center
  flashlight state.
- **Last App** only knows the apps opened since the last respring.
- Turning **Dark Mode** on or off ends an automatic (sunset) appearance schedule.

### Not in Triggr (that Activator had)

- **Triggers:** slide-in edge gestures and Home Screen pinch / spread (they would
  compete with system gestures), status bar holds and swipes (apps draw their own
  status bar, so it would need a hook in every app's touch handling), lock button
  short hold, headset button, keyboard shortcuts, incoming notifications, other
  motion than shake (it would keep a sensor running).
- **Actions:** VPN and Personal Hotspot (no entry point SpringBoard can use
  safely), composing a message, email or tweet (Open URL with `sms:`,
  `mailto:` or `tel:` covers most of it).
- Keys from older builds that aren't in the catalogue are ignored.

## License

Triggr is free software under the [GNU General Public License v3.0](LICENSE).

## Credits

- **Triggr** by **John d_ie** ([John's Repo](https://jond-ie.github.io/repo/)).
- Inspired by **Activator** by Ryan Petrich.
- **[AltList](https://github.com/opa334/AltList)** by opa334 (Lars Fröder) for the
  app pickers, MIT License; its headers and framework in `vendor/` keep their own
  license ([vendor/AltList-LICENSE](vendor/AltList-LICENSE)).
- Built with [Theos](https://theos.dev/).
