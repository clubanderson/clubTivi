# clubTivi Easy Install System

Making installation so simple a 5-year-old can do it — especially on Android TV.

---

## The Problem

Installing apps on Android TV is painful:
- Sideloading requires enabling developer options and unknown sources
- Typing URLs on a TV remote is miserable
- ADB requires a computer and command-line knowledge
- Even Downloader app requires typing a long URL with a D-pad

**clubTivi solves this with multiple dead-simple installation paths.**

---

## Installation Methods (Easiest → Most Technical)

### 1. 📱 Phone-to-TV Push (Recommended — Zero Typing on TV)

The flagship install method. **No URL typing. No ADB. No computer.**

```
┌─────────────┐                              ┌─────────────┐
│    Phone     │        Same WiFi             │  Android TV  │
│              │◄────────────────────────────►│              │
│ 1. Scan QR   │   Auto-discover TV via       │ Just turn on │
│ 2. Tap "Send │   SSDP/mDNS/ADB-mdns        │ and wait     │
│    to TV"    │                              │              │
│ 3. Done!     │   Push APK wirelessly        │ Auto-install │
└─────────────┘                              └─────────────┘
```

**How it works:**
1. Parent/user visits **`clubtivi.app`** on their phone (or scans a QR code)
2. The web page downloads a tiny **clubTivi Installer** (< 2MB) on the phone
3. Open the installer → it auto-discovers Android TVs on the same WiFi network
4. Tap the TV name → installer pushes clubTivi APK to the TV
5. TV shows "Install clubTivi?" → tap OK with remote
6. Done. Delete the installer from phone if you want.

**Technical detail:** Uses Android's `WiFi Direct` or discovers TV via network scan + Android TV's built-in install-from-network capability. Falls back to generating an ADB pairing flow with on-screen instructions if needed.

---

### 2. 🔢 Short Code Install (For Downloader App)

Instead of typing a 60-character GitHub URL, type **one short code**.

```
In Downloader app, type:

    clubtivi.app

That's it. 10 characters. Auto-redirects to latest APK.
```

Or even shorter with a custom domain:

```
    ctv.to
```

**5 characters.** The shortest possible URL that works in Downloader.

The landing page auto-detects the platform:
- Android TV → direct APK download
- Android phone → APK + offer to "Send to TV"
- Desktop → platform-specific installer
- Unknown → shows all options

---

### 3. 📷 QR Code Install

Every clubTivi release includes a QR code. Put it anywhere:

```
┌─────────────────────────────────┐
│                                 │
│     ██████████████████████      │
│     ██ ▄▄▄▄▄ █▄█▄█ ▄▄▄▄▄ ██   │
│     ██ █   █ █▄▄ █ █   █ ██   │
│     ██ █▄▄▄█ ██▄██ █▄▄▄█ ██   │
│     ██████████████████████      │
│                                 │
│    Scan to install clubTivi     │
│    clubtivi.app                 │
│                                 │
└─────────────────────────────────┘
```

**Use cases:**
- Print and stick on the TV / fridge / wall
- Share in a group chat
- Show on a computer screen, scan with phone
- Include in YouTube video descriptions / tutorials
- NFC tags with the URL (tap phone → install page)

The QR links to `clubtivi.app/install?v=latest` which smart-redirects based on device.

---

### 4. 📺 Channel Code Install (TV-Native)

For TVs that already have a web browser or the Downloader app:

```
┌──────────────────────────────────────┐
│                                      │
│   Install clubTivi                   │
│                                      │
│   Go to:  clubtivi.app              │
│                                      │
│   Or enter code:  8 4 7 2           │
│   at clubtivi.app/code              │
│                                      │
└──────────────────────────────────────┘
```

- Short numeric codes (4 digits) that map to specific releases
- Rotated periodically, posted on the website/Reddit/Discord
- User types `clubtivi.app/code` in browser, enters 4 digits, download starts

---

### 5. 🔊 Voice Install (Future — If on App Stores)

```
"Hey Google, install clubTivi"
"Alexa, install clubTivi"  (Fire TV)
```

Requires listing on Google Play Store and Amazon Appstore. Goal for v1.0 stable release.

---

### 6. 💾 USB Stick Install

The "give it to grandma" method:

1. Download APK on computer
2. Copy to USB stick
3. Plug USB into TV
4. TV's file manager sees the APK → tap to install

We provide a **USB installer creator** on the website:
- Download a ZIP that contains the APK + a `readme.txt` with instructions
- `readme.txt` has ONE step: "Plug this USB into your TV and open the file"

---

## clubtivi.app — Smart Landing Page

The website at `clubtivi.app` (or `ctv.to`) is the hub:

```
┌──────────────────────────────────────────────────────────────┐
│  🎬 clubTivi                                                 │
│  Free IPTV Player for Every Screen                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ We detected you're on: [iPhone / Android / Mac / etc] │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐     │   │
│  │  │  📥 Download for [Your Platform]             │     │   │
│  │  └─────────────────────────────────────────────┘     │   │
│  │                                                       │   │
│  │  📺 Install on Android TV instead?                    │   │
│  │     → Send to TV (scan your network)                  │   │
│  │     → Short code: clubtivi.app (type on TV)           │   │
│  │     → QR code (print or show on screen)               │   │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  All Platforms:                                              │
│  [Android] [Android TV] [Fire TV] [macOS] [Windows] [Linux]  │
│                                                              │
│  Other install methods:                                      │
│  [USB Stick] [Downloader App] [ADB] [Build from Source]      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Auto-Detection Logic
```
User-Agent contains "Android TV" → Android TV APK
User-Agent contains "Android"    → Phone APK + "Send to TV" option
User-Agent contains "Fire"       → Fire TV APK (same APK, different instructions)
User-Agent contains "Macintosh"  → macOS DMG
User-Agent contains "Windows"    → Windows MSIX + ZIP
User-Agent contains "Linux"      → Linux tarball + Flatpak
```

---

## Phone-to-TV Push — Technical Design

### Discovery
The phone installer finds TVs using multiple methods in parallel:

```dart
class TVDiscovery {
  /// Discover Android TV devices on the local network.
  /// Uses multiple strategies for maximum compatibility.
  
  Stream<DiscoveredTV> discover() async* {
    // Strategy 1: mDNS — look for _androidtvremote2._tcp
    // Most Android TVs advertise this service
    yield* _mdnsDiscovery();
    
    // Strategy 2: SSDP/UPnP — look for MediaRenderer devices
    // Works on most smart TVs and streaming devices
    yield* _ssdpDiscovery();
    
    // Strategy 3: ADB mDNS — look for _adb-tls-pairing._tcp
    // Works if wireless debugging is enabled (Android 11+ TVs)
    yield* _adbMdnsDiscovery();
    
    // Strategy 4: Network scan — probe common ports on local subnet
    // Fallback: scan x.x.x.1-254 for ADB port (5555) or custom port
    yield* _networkScan();
  }
}

class DiscoveredTV {
  final String name;        // "Living Room TV"
  final String ipAddress;
  final String model;       // "NVIDIA Shield", "Chromecast", "Fire TV"
  final TVCapability capability;
}

enum TVCapability {
  adbWireless,      // Can push APK via ADB
  directInstall,    // Can send install intent
  browserOnly,      // Can only open URL — fall back to short-code method
}
```

### APK Push Flow
```
Phone                               TV
  │                                  │
  │  1. Discover TV via mDNS/SSDP   │
  │─────────────────────────────────►│
  │                                  │
  │  2. Request ADB pairing          │
  │─────────────────────────────────►│
  │           (TV shows pairing code) │
  │  3. User reads 6-digit code      │◄┐
  │     from TV and enters on phone  │ │ TV displays:
  │─────────────────────────────────►│ │ "Allow debugging?
  │                                  │ │  Code: 482916"
  │  4. ADB connection established   │
  │─────────────────────────────────►│
  │                                  │
  │  5. Push APK (adb install)       │
  │─────────────────────────────────►│
  │                                  │
  │  6. TV installs, shows confirm   │
  │           ◄──────────────────────│
  │  7. Done! Launch clubTivi        │
  │                                  │
```

### Simplified Flow (No ADB)
For TVs where ADB isn't available, the phone acts as a local web server:

```
Phone                               TV
  │                                  │
  │  1. Phone starts local HTTP server│
  │     serving the APK file         │
  │                                  │
  │  2. Phone shows a short URL:     │
  │     "On your TV, open:           │
  │      192.168.1.42:8080"          │
  │     (or displays QR code for     │
  │      Downloader app to scan)     │
  │                                  │
  │  3. TV browser/Downloader hits   │
  │     the URL                      │
  │◄─────────────────────────────────│
  │                                  │
  │  4. Phone serves APK directly    │
  │─────────────────────────────────►│
  │                                  │
  │  5. TV installs APK              │
  │                                  │
```

This avoids needing ANY external internet on the TV — the phone serves the file locally.

---

## Fire TV Specific

Fire TV has some extra quirks:

### Method A: Downloader App (Most Common)
```
1. Install "Downloader" from Amazon Appstore (free, trusted)
2. Type: clubtivi.app (or ctv.to)
3. Auto-downloads APK → Install → Done
```

### Method B: Phone-to-Fire-TV
Same as the Phone-to-TV push above. Fire TV supports ADB over WiFi.

### Method C: Send to Fire TV (Amazon Feature)
```
1. On phone, open Amazon Appstore
2. If clubTivi is listed → "Deliver to: [Your Fire TV]"
```
Requires Amazon Appstore listing.

---

## Post-Install First-Run Experience

After installation, clubTivi's first-run wizard makes setup just as easy:

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│  🎬 Welcome to clubTivi!                                     │
│                                                              │
│  Let's get you watching TV in 3 steps:                       │
│                                                              │
│  Step 1: Add your TV provider                                │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  How do you want to add channels?                    │    │
│  │                                                      │    │
│  │  [🔗 Paste M3U URL        ]  (most common)          │    │
│  │  [🌐 Xtream Codes Login   ]  (server/user/pass)     │    │
│  │  [📁 Load from File       ]  (M3U file on device)   │    │
│  │  [📷 Scan QR Code         ]  (scan provider QR)     │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  Step 2: We'll auto-setup your EPG (program guide)           │
│                                                              │
│  Step 3: Start watching!                                     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### QR Code Playlist Import
Providers or users can encode playlist URLs as QR codes. On Android TV:
- clubTivi shows "Scan QR Code" option
- User points phone camera at provider's QR
- Phone opens clubTivi deep link which sends config to TV via local network
- TV auto-configures — user never types anything

---

## Domain Strategy

| Domain | Purpose |
|--------|---------|
| `clubtivi.app` | Main site, smart installer, documentation |
| `ctv.to` | Ultra-short redirect for TV typing (5 chars) |
| `clubtivi.app/code` | Numeric code installer |
| `clubtivi.app/remote` | Web companion remote landing page |
| `clubtivi.app/qr/<version>` | Version-specific QR code pages |

---

## Summary: Install Difficulty by Method

| Method | Difficulty | Steps | Typing on TV? | Needs Computer? |
|--------|-----------|-------|---------------|-----------------|
| Phone-to-TV Push | ⭐ Easiest | 3 taps | No | No |
| QR Code → Phone → TV | ⭐ Easy | Scan + 2 taps | No | No |
| Short URL in Downloader | ⭐⭐ Easy | Type 10 chars | Yes (minimal) | No |
| Short Code at clubtivi.app/code | ⭐⭐ Easy | Type 4 digits | Yes (minimal) | No |
| USB Stick | ⭐⭐ Easy | Plug in | No | Yes (to prep USB) |
| Desktop (Mac/Win/Linux) | ⭐ Easiest | Download + open | N/A | N/A |
| ADB from computer | ⭐⭐⭐⭐ Technical | CLI commands | No | Yes |
| Build from source | ⭐⭐⭐⭐⭐ Developer | Many | No | Yes |
