# Triggr — beta builds and feedback

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Release](https://img.shields.io/badge/release-1.5.0-informational)
![Next](https://img.shields.io/badge/next-2.0%20beta%20coming%20soon-orange)

> **This repo is for Triggr beta builds and beta feedback.** The current release's source, documentation and
> issues live in **[Jond-ie/triggr](https://github.com/Jond-ie/triggr)**. Install Triggr from
> **[John's Repo](https://jond-ie.github.io/repo/)**. The source folders here are from older betas.

**Triggr** is an Activator-style trigger tool for rootless jailbreaks (Dopamine) on **iOS 15–18**, arm64 and
arm64e. Assign actions to buttons, screen edges, the status bar, Home Screen gestures, sensors and events.

The goal: **the lightest trigger tool there is.** The main library loads into SpringBoard only, and nothing runs
for a trigger you haven't assigned: no timers, no polling, no extra daemons.

> AI assisted in development (Claude Code), all testing and debugging done by me on device.

## Current release: 1.5

<p>
  <img src="screenshots/8-triggers-1.5.png" alt="Trigger list in 1.5" width="200">
  <img src="screenshots/9-lock-volume.png" alt="Lock + Volume press and hold" width="200">
  <img src="screenshots/10-screen-edges.png" alt="Screen Edges, one and two fingers" width="200">
</p>

New in 1.5:
- **Lock / Side + Volume:** press or hold the lock (side) button with Volume Up or Down. A press can replace the
  screenshot on Face ID iPhones; holding still brings up the power-off slider and Emergency SOS.
- **Screen edges:** slide in from the left or right edge, also with **two fingers** (like Activator), so apps keep
  their swipe back.
- **Phone calls** (incoming, answered, outgoing, ended), **music** (started, paused, song changed),
  **any notification**, **weekly schedules** and **Brightness Up / Down** steps.
- A Respring or Safe Mode run from a Volume Up trigger waits until you let go, so it can't land in Safe Mode.

Tested on A10 (iOS 15.8.6), A11 (iOS 16.7), A13 Face ID (iOS 16.2), A13 Touch ID (iOS 17.5.1) and
A13 Face ID (iOS 18.6.2).

**RootHide:** [Triggr 1.5 RootHide](https://github.com/Jond-ie/triggr-beta/releases/tag/v1.5.0-roothide)
(pre-release, untested on a RootHide device; feedback welcome).

## Triggr 2.0 beta — coming soon

2.0 makes Triggr smarter without making it heavier: every new feature costs nothing until you use it.

Planned:
- **Conditions ("only if"):** run an assignment only at certain times, on a Wi-Fi network, with a Bluetooth device
  or headphones connected, while charging, locked or unlocked, with music playing, in your pocket.
- **If / Else steps** in sequences, plus wait-for-event and repeat.
- **Bottom swipe zones:** swipe up from the bottom-left, center or right.
- **Edge swipes up / down** along the side of the screen.
- **HTTP request** and **Home Assistant** actions (webhooks, smart home), and a **toast** action.
- **Missed / declined call** trigger, done properly.
- A tested **RootHide** build, and performance numbers (CPU, wakeups, memory) with every release.

Not planned on purpose: an always-on web server, background MQTT listeners or a bundled script interpreter. They
cost battery and memory even when idle.

Want to test the 2.0 betas? Watch this repo (Releases only), and tell me your device and iOS version in an issue.

## Bugs and feature requests

Please use **[Issues on Jond-ie/triggr](https://github.com/Jond-ie/triggr/issues/new/choose)**:
- **Crash report:** Triggr or SpringBoard crashed, or you hit safe mode. Include the crash log (Settings → Privacy &
  Security → Analytics & Improvements → Analytics Data) and your device, iOS and jailbreak.
- **Bug report:** something doesn't work as expected.
- **Feature request:** a trigger or action you want. If Activator had it, say so.

If anything ever puts you in safe mode, open Sileo (it still works there) and uninstall Triggr.

## License and credits

GPL-3.0. Original work by **John d_ie**, inspired by Activator (Ryan Petrich). App pickers by AltList (opa334).
