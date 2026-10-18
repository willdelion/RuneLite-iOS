# RuneLite for iOS

Play Old School RuneScape with the [RuneLite](https://runelite.net) client on an iPhone or iPad, with your own Jagex account, plugins, and the Plugin Hub.

This is a fork of [Amethyst (Angel Aura Amethyst) for iOS](https://github.com/AngelAuraMC/Amethyst-iOS), a Java launcher for iOS. It runs the regular desktop RuneLite client inside an embedded Java 17 runtime and adds:

- A simple launcher: **Jagex Account**, **Play**, **Settings**.
- Jagex Account sign-in through the official Jagex login page (the same flow the Jagex Launcher uses).
- Touch controls in the style of OSRS mobile.
- JIT handled automatically through [StikDebug](https://github.com/StephenDev0/StikDebug): tap Play and the game starts by itself.
- Plugin Hub fixes for slow mobile/VPN connections.

> **Unofficial project.** It is not affiliated with or endorsed by Jagex or RuneLite. RuneLite is an approved third-party client on desktop, but running it on iOS this way is not officially supported. Use it at your own risk.

---

## Contents

1. [Requirements](#1-requirements)
2. [Download the IPA](#2-download-the-ipa)
3. [Install the app (sideload)](#3-install-the-app-sideload)
4. [Set up JIT with StikDebug](#4-set-up-jit-with-stikdebug)
5. [First launch and signing in](#5-first-launch-and-signing-in)
6. [Touch controls](#6-touch-controls)
7. [Settings](#7-settings)
8. [Keeping the app working (7-day signing)](#8-keeping-the-app-working-7-day-signing)
9. [Troubleshooting](#9-troubleshooting)
10. [Building from source](#10-building-from-source)
11. [Credits and license](#11-credits-and-license)

---

## 1. Requirements

- **iPhone or iPad on iOS 17 or newer.** A device with **6 GB of RAM or more** is strongly recommended (iPhone 13 Pro / 14 / 15 / 16 / 17 series, M-series iPads). It may start on older devices but can be closed by iOS for using too much memory.
- **A computer (Mac, Windows or Linux) for the one-time setup.** It is needed to install the app the first time and to create the StikDebug pairing file. After that you can play without it.
- **A free Apple ID** (a paid developer account works too and lasts longer, see [section 8](#8-keeping-the-app-working-7-day-signing)).
- **An Old School RuneScape account** (a Jagex Account or a legacy account).

## 2. Download the IPA

1. Open the [**Releases**](../../releases/latest) page of this repository.
2. Download `RuneLite-iOS.ipa` from the **Assets** list.

The IPA is unsigned. Your sideloading tool signs it with your own Apple ID, so every player installs their own copy and nobody's account is shared.

## 3. Install the app (sideload)

Apps outside the App Store have to be *sideloaded*. Pick one of these tools. **SideStore** is recommended because it can also re-sign the app from the phone later.

### Option A: SideStore (recommended)

1. Install SideStore by following the official guide: <https://docs.sidestore.io/docs/installation/prerequisites>. Its setup creates a **pairing file**; keep it, StikDebug uses the same kind of file.
2. On the iPhone, open the downloaded `RuneLite-iOS.ipa` (Files app → share → **SideStore**), or in SideStore go to **My Apps → +** and pick the IPA.
3. Wait for it to finish. A **RuneLite** icon appears on the home screen.

### Option B: AltStore

1. Install AltServer on your computer and AltStore on the phone: <https://faq.altstore.io/>.
2. In AltStore, **My Apps → +** and choose `RuneLite-iOS.ipa`.

### Option C: Sideloadly (computer only)

1. Install [Sideloadly](https://sideloadly.io) on your computer and connect the phone with a cable.
2. Drag `RuneLite-iOS.ipa` into Sideloadly, enter your Apple ID and press **Start**.

### After installing (all options)

- **Trust the developer profile:** Settings → General → VPN & Device Management → your Apple ID → **Trust**.
- **Turn on Developer Mode** (iOS 16+): Settings → Privacy & Security → **Developer Mode** → on, then restart the phone and confirm.

> **TrollStore users:** if your iOS version supports [TrollStore](https://github.com/opa334/TrollStore), install the IPA with TrollStore instead. It is signed permanently and JIT is enabled automatically, so you can skip section 4 and section 8.

## 4. Set up JIT with StikDebug

iOS normally blocks *JIT* (just-in-time compilation). Without it Java, and therefore RuneLite, is far too slow to play. **StikDebug** enables JIT for RuneLite right on the phone, without a computer, every time you press Play.

1. **Install StikDebug.** Get it from the App Store if it is available in your region, or sideload it the same way as RuneLite. See <https://github.com/StephenDev0/StikDebug>.
2. **Create a pairing file** on your computer (one time). Use the [**StikPair / iloader**](https://github.com/StephenDev0/StikDebug) tool linked from the StikDebug page (or the pairing file from your SideStore setup). Connect the phone with a cable, unlock it, tap **Trust** on the phone, and save the `.mobiledevicepairing` / `.plist` file it produces.
3. **Import the pairing file into StikDebug:** send the file to the phone (AirDrop, iCloud Drive, e-mail to yourself), open StikDebug and import it when it asks.
4. **Install LocalDevVPN.** StikDebug talks to the phone through a local VPN app called **LocalDevVPN** (free on the App Store). Install it and allow it to add a VPN configuration. StikDebug will tell you if anything is still missing.

> iOS allows only one VPN at a time. If you use another VPN (Tailscale, a privacy VPN, etc.) it is switched off while LocalDevVPN is active.

## 5. First launch and signing in

1. Open **RuneLite** from the home screen. You get the launcher with three items:
   - **Account card** at the top: shows *Sign in with a Jagex Account*, or your character name once you are signed in.
   - **Play**.
   - **Settings**.
2. **Sign in (Jagex Account holders):** tap the account card. The official Jagex login page opens inside the app. Sign in with your e-mail, password and 2FA as usual, then choose the character you want to play. The launcher now shows your character name.
   - Your session is stored only on your device, in the iOS Keychain. Your password is never seen or stored by the app; you type it only into Jagex's own web page.
   - To switch characters or accounts, tap the account card again (**Jagex Account · Change**) and choose **Switch character**, **Sign in again** or **Sign out**.
3. **Legacy (non-Jagex) accounts:** don't sign in on the launcher. Just tap **Play** and log in on the normal RuneScape login screen inside the game.
4. **Tap Play.** The first time:
   - The app opens StikDebug, which enables JIT and sends you back automatically. The status reads *Waiting for StikDebug to enable JIT. The game will start automatically*.
   - RuneLite then starts. **The first start takes a while** (it downloads the game client and plugins). Later starts are faster.
5. If StikDebug asks which script to use for RuneLite, choose the **Universal JIT** script (the app passes it automatically on most versions).

## 6. Touch controls

The controls mimic the official OSRS mobile app:

| Gesture | Action |
|---|---|
| Tap | Left click (walk, attack, interact) |
| Press and hold | Right click (opens the menu with all options) |
| Hold, then drag | Drag items (inventory, bank) |
| Drag on the game view | Rotate the camera |
| Drag on a side panel / list | Scroll |
| Pinch | Zoom the camera in/out |

- A keyboard appears when you tap a text field (chat, bank search, login).
- A Bluetooth keyboard and mouse also work.
- The RuneLite sidebar (plugins, settings, Plugin Hub) works like on desktop.

## 7. Settings

**Settings → RuneLite Memory** sets how much memory Java may use.

- **Automatic** is a safe default for your device.
- More memory means fewer stutters, but if you set it too high iOS will close the game. If the game quits by itself, lower this value. Changes apply on the next launch.
- Many Plugin Hub plugins or memory-heavy ones (large map overlays) need more of it. The GPU and 117 HD plugins are not available on iOS.

### Display

- In the default **Fixed** layout the game is scaled up to the full screen height, keeping its proportions, with black bars on the sides.
- For a game view that fills the whole screen, switch the in-game layout: **Settings (wrench) → Display → Game client layout → Resizable**. The 3D view is then drawn at the screen's own resolution.
- Upscaling is configured in RuneLite's **Stretched Mode** plugin (enabled by default). Turn *Keep aspect ratio* off there if you prefer a stretched full-width Fixed layout.

## 8. Keeping the app working (7-day signing)

With a **free Apple ID**, Apple lets sideloaded apps run for **7 days**. After that the app won't open until it is signed again. Your RuneLite settings and sign-in are kept when you refresh.

- **SideStore:** open SideStore and tap **Refresh All** (works on the phone itself, but needs LocalDevVPN on). Do it at least once a week.
- **AltStore:** keep AltServer running on a computer on the same Wi-Fi; AltStore refreshes in the background, or tap **Refresh All**.
- **Sideloadly:** install the IPA again from the computer.
- A **paid Apple Developer account** ($99/year) makes signing last one year.

A free Apple ID can have at most **3 sideloaded apps** at once (SideStore/AltStore, StikDebug and RuneLite count towards this if you sideloaded StikDebug).

## 9. Troubleshooting

**"StikDebug Required" message**
StikDebug is not installed, or the app can't open it. Install StikDebug and import the pairing file (section 4).

**Stuck on "Waiting for StikDebug…"**
- Make sure LocalDevVPN is installed and StikDebug shows it as connected.
- Re-import the pairing file in StikDebug. A pairing file stops working after you reset the phone, "Reset Location & Privacy", or update iOS in some cases. Create a new one in that case.
- Tap **Cancel**, close RuneLite from the app switcher and try again.

**The app doesn't open / crashes immediately**
- The 7-day signature expired: refresh it (section 8).
- Developer Mode is off: turn it on (section 3).

**The game closes by itself after a while**
iOS ran out of memory. Lower **Settings → RuneLite Memory**, close other apps, and disable memory-heavy plugins.

**Jagex sign-in fails or loops**
Try again over a stable connection. Turn other VPNs off. If it keeps failing, tap the account card → **Sign out**, then sign in again.

**Plugin Hub plugins don't appear**
The Plugin Hub list can time out on slow connections. Restart the game on a better connection; the last good list is cached and reused automatically.

**It's slow**
JIT is probably not enabled. The launcher status should say *JIT is enabled* after StikDebug ran. Use a newer device if possible, and lower the in-game draw distance.

## 10. Building from source

You only need this if you want to change the code. Requirements: a Mac with Xcode, CMake, `ldid`, `wget`, and a JDK 8 to build the Java parts.

```bash
git clone --recursive https://github.com/willdelion/RuneLite-iOS.git
cd RuneLite-iOS
make java BOOTJDK=/path/to/jdk8/bin
make package PLATFORM=2 BOOTJDK=/path/to/jdk8/bin
```

The unsigned IPA is written to `artifacts/`. Then sign and install it with any tool from section 3.

Developer helpers in `scripts/`:

- `sim-run.sh`: build for the iOS Simulator and launch it there (set the `BOOTJDK` path inside the script).
- `sim-log.sh`: print the game log from the simulator.
- `device-install.sh`: re-sign the device build with your own free Apple ID and install it over USB or Wi-Fi with `xcrun devicectl`. Set `DEVICE`, `BUNDLE_ID` and `IDENTITY` first (see the comments in the script).

The RuneLite-specific code lives in:

- `Natives/RuneLiteLauncherViewController.m`: the launcher screen and settings.
- `Natives/JagexAccount.m`: Jagex Account sign-in and session storage.
- `Natives/JavaGUIViewController.m`: touch controls.
- `JavaApp/src/.../RuneLiteSupport.java`: Java-side fixes (input, Swing repaint, Plugin Hub).
- `RuneLite/`: the bundled RuneLite launcher jar and icon.

## 11. Credits and license

- [Amethyst for iOS](https://github.com/AngelAuraMC/Amethyst-iOS) by the Angel Aura MC team, based on PojavLauncher and Boardwalk. The original README is in [README.amethyst.md](README.amethyst.md).
- [RuneLite](https://github.com/runelite/runelite), BSD 2-Clause license.
- [StikDebug](https://github.com/StephenDev0/StikDebug) and [SideStore](https://sidestore.io) for JIT and sideloading.
- Old School RuneScape is a trademark of Jagex Ltd.

This project is distributed under the same license as Amethyst: see [LICENSE](LICENSE).
