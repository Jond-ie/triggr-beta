# Triggr: closed beta

**Triggr** is an Activator-lite for **rootless Dopamine on iOS 15–16**. It lets you
assign actions to buttons, gestures and events, laid out like Activator.

> **This is a closed beta.** It isn't in any Sileo repo yet. Please don't
> re-upload or redistribute the `.deb`; share this page instead. The source code
> isn't public.

## Install

1. Install the requirements from your package manager:
   - **AltList** (`com.opa334.altlist`, BigBoss)
   - **PreferenceLoader**
2. Download the `.deb` from [**Releases**](../../releases).
3. Open it with Sileo or Filza, or run `dpkg -i` as root. Then respring.
4. Set it up in **Settings → Triggr**.

To remove it, uninstall **Triggr** in your package manager.

## Supported devices

| Device | Status |
|---|---|
| **A11 and older (arm64) with Touch ID**, iOS 15–16 | Tested on iPhone 8 Plus, iOS 16.7 |
| **A12 and newer (arm64e)** | **Untested.** The package includes an arm64e build, but it may not load. Please report either way. |
| **Face ID devices** | **Untested.** Home Button and Touch ID triggers are hidden and switched off. The lock button is labelled **Side Button**; its triggers run alongside the system, so a double-click still opens Wallet and a triple-click still runs the Accessibility Shortcut. |

Triggr never delays or blocks the lock/side button, so **Emergency SOS always works**.

## What it does

- **Triggers:**
  - Home button (single, double, triple, short and long hold).
  - Touch ID light double tap (replaces Reachability).
  - Lock/side button double, triple and hold.
  - Volume buttons (press, hold, both buttons).
  - Mute switch.
  - Status bar taps.
  - Charger and headphones.
  - Wi-Fi, Bluetooth, Low Power and lock state changes.
  - Custom events: a specific Wi-Fi network or Bluetooth device, battery %, an app
    opening, a scheduled time.
- **Actions:**
  - System actions.
  - Toggle / on / off switches.
  - Media controls.
  - Brightness and volume levels.
  - Messages and spoken text.
  - Settings pages.
  - Apps, URLs, Shortcuts and shell commands.
  - Menus.
- **Several actions per trigger,** with pauses and reordering.
- **Modes:** Anywhere, Home Screen, In App, Lock Screen.
- **Lock Screen safety:** apps, URLs and shell commands wait for you to unlock.
- **Extras:**
  - Block List.
  - Action banners.
  - Profiles.
  - Export and import of setups.
  - Reset to defaults.
  - An opt-in API and a `triggr` command-line tool.

## Known limits

- Menus don't open while the device is locked.
- Scheduled events are skipped if iOS runs them more than 5 minutes late (e.g.
  while the phone sleeps).
- Not tested yet:
  - Battery events.
  - Finger Rest / Match.
  - Status bar taps on the Lock Screen.
  - Wired headphones.
  - Devices without a passcode.

## Feedback

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

## Credits

Triggr is by **John d_ie**, inspired by Activator (Ryan Petrich). It was developed
with AI assistance (Claude Code) and tested on-device.
