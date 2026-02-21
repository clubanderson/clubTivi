# Installation Guide

clubTivi runs on **Android (phone/tablet/TV)**, **macOS**, **Windows**, and **Linux**.

> **Looking for the easiest way to install on Android TV?** See [Easy Install Guide](EASY_INSTALL.md) — install without typing anything on your TV.

---

## 📦 Pre-Built Releases (Recommended)

Download the latest release for your platform from the [Releases](https://github.com/clubanderson/clubTivi/releases) page, or visit **[clubtivi.app](https://clubtivi.app)** for auto-detected platform downloads.

| Platform | File | Notes |
|----------|------|-------|
| Android / Android TV | `clubtivi-<version>.apk` | Sideload or install via file manager |
| macOS | `clubtivi-<version>-macos.dmg` | macOS 12 Monterey or later |
| Windows | `clubtivi-<version>-windows.msix` | Windows 10 (1903) or later |
| Linux | `clubtivi-<version>-linux.tar.gz` | Ubuntu 22.04+, Fedora 38+, or equivalent |
| Linux (Flatpak) | `clubtivi-<version>.flatpak` | Any distro with Flatpak support |

---

## 🤖 Android / Android TV

### Install from APK

1. Download `clubtivi-<version>.apk` from [Releases](https://github.com/clubanderson/clubTivi/releases)
2. On your device, enable **Settings → Security → Unknown sources** (or per-app install permission)
3. Open the APK file and tap **Install**

#### Android TV Sideload

**Option A — Using a file manager app:**
1. Install [File Commander](https://play.google.com/store/apps/details?id=com.mobisystems.fileman) or [X-plore](https://play.google.com/store/apps/details?id=com.lonelycatgames.Xplore) from the Play Store on your TV
2. Download the APK to a USB drive or use the app's cloud/LAN transfer feature
3. Navigate to the APK and install

**Option B — Using ADB from your computer:**
```bash
# Ensure your Android TV has Developer Options → ADB debugging enabled
# Find your TV's IP address in Settings → Network

adb connect <tv-ip-address>:5555
adb install clubtivi-<version>.apk
```

**Option C — Using [Downloader](https://play.google.com/store/apps/details?id=com.esaba.downloader) app:**
1. Install **Downloader** from the Play Store on your TV
2. Enter the direct APK download URL from the Releases page
3. Download and install

### Requirements
- Android 7.0 (API 24) or later
- Android TV: any device running Android TV 7.0+ (NVIDIA Shield, Chromecast with Google TV, Fire TV Stick*, etc.)

> \* For Fire TV Stick: use the ADB sideload method or the Downloader app. Fire TV runs a fork of Android and supports standard APK installation.

---

## 📱 iOS / iPadOS

### Build from Source (iOS)

> **Note:** clubTivi is not yet available on the App Store. You can build and run it on your device using Xcode.

```bash
# Prerequisites: Xcode 15+ with iOS platform component installed
# Install Flutter: https://docs.flutter.dev/get-started/install/macos

git clone https://github.com/clubanderson/clubTivi.git
cd clubTivi
flutter pub get
cd ios && pod install && cd ..
flutter run -d <your-device-id>    # or: flutter build ios
```

### Requirements
- iOS 13.0 or later (iPhone, iPad)
- Xcode 15+ with iOS platform installed (Xcode > Settings > Components)
- Apple Developer account (free or paid) for device deployment
- CocoaPods: `sudo gem install cocoapods`

### Notes
- HTTP IPTV streams are supported (App Transport Security is configured)
- Background audio is enabled for listening while the app is backgrounded
- All orientations supported on iPad; portrait + landscape on iPhone

---

## 🍎 macOS

### Install from DMG

1. Download `clubtivi-<version>-macos.dmg` from [Releases](https://github.com/clubanderson/clubTivi/releases)
2. Open the `.dmg` file
3. Drag **clubTivi** to the **Applications** folder
4. On first launch, you may see a Gatekeeper warning:
   - Go to **System Settings → Privacy & Security**
   - Click **Open Anyway** next to the clubTivi message
   - Or right-click the app → **Open** → **Open**

### Requirements
- macOS 12 (Monterey) or later
- Apple Silicon (M1/M2/M3/M4) or Intel

### Build from Source (macOS)

```bash
# Install prerequisites
xcode-select --install
brew install flutter

# Clone and build
git clone https://github.com/clubanderson/clubTivi.git
cd clubTivi
flutter pub get
flutter build macos --release

# The app bundle is at:
# build/macos/Build/Products/Release/clubTivi.app
```

---

## 🪟 Windows

### Install from MSIX

1. Download `clubtivi-<version>-windows.msix` from [Releases](https://github.com/clubanderson/clubTivi/releases)
2. Double-click the `.msix` file
3. Click **Install** in the App Installer window
4. Launch clubTivi from the Start Menu

### Install from ZIP (Portable)

1. Download `clubtivi-<version>-windows.zip` from [Releases](https://github.com/clubanderson/clubTivi/releases)
2. Extract to any folder (e.g., `C:\Programs\clubTivi\`)
3. Run `clubtivi.exe`

### Requirements
- Windows 10 version 1903 (May 2019 Update) or later
- x64 architecture
- [Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) (usually already installed)

### Build from Source (Windows)

```powershell
# Install Flutter SDK: https://docs.flutter.dev/get-started/install/windows
# Install Visual Studio 2022 with "Desktop development with C++" workload

# Clone and build
git clone https://github.com/clubanderson/clubTivi.git
cd clubTivi
flutter pub get
flutter build windows --release

# The executable is at:
# build\windows\x64\runner\Release\clubtivi.exe
```

---

## 🐧 Linux

### Install from Tarball

```bash
# Download and extract
wget https://github.com/clubanderson/clubTivi/releases/download/<version>/clubtivi-<version>-linux.tar.gz
tar -xzf clubtivi-<version>-linux.tar.gz
cd clubtivi

# Run directly
./clubtivi

# Or install system-wide
sudo cp -r . /opt/clubtivi
sudo ln -sf /opt/clubtivi/clubtivi /usr/local/bin/clubtivi
```

### Install from Flatpak

```bash
# If you don't have Flatpak: https://flatpak.org/setup/
flatpak install clubtivi-<version>.flatpak
flatpak run io.github.clubanderson.clubtivi
```

### Install from Snap (coming soon)

```bash
sudo snap install clubtivi
```

### Requirements

**Ubuntu / Debian:**
```bash
sudo apt update
sudo apt install -y libmpv1 libgtk-3-0 libblkid1 liblzma5
```

**Fedora:**
```bash
sudo dnf install -y mpv-libs gtk3
```

**Arch Linux:**
```bash
sudo pacman -S mpv gtk3
```

### Build from Source (Linux)

```bash
# Install system dependencies (Ubuntu/Debian)
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev libmpv-dev liblzma-dev

# Install Flutter SDK: https://docs.flutter.dev/get-started/install/linux
# Ensure flutter is on your PATH

# Clone and build
git clone https://github.com/clubanderson/clubTivi.git
cd clubTivi
flutter pub get
flutter build linux --release

# The executable is at:
# build/linux/x64/release/bundle/clubtivi
```

### Desktop Entry (optional)

Create `~/.local/share/applications/clubtivi.desktop`:
```ini
[Desktop Entry]
Type=Application
Name=clubTivi
Comment=Open-source IPTV player
Exec=/opt/clubtivi/clubtivi
Icon=/opt/clubtivi/data/flutter_assets/assets/icons/clubtivi.png
Categories=AudioVideo;Video;Player;
Keywords=IPTV;TV;streaming;
```

Then update the desktop database:
```bash
update-desktop-database ~/.local/share/applications/
```

---

## 🔧 Build from Source (All Platforms)

### Prerequisites

1. **Flutter SDK 3.24+** — [Install Flutter](https://docs.flutter.dev/get-started/install)
2. **Git** — [Install Git](https://git-scm.com/)
3. Platform-specific tools (see platform sections above)

### Verify Flutter Setup

```bash
flutter doctor
```

Ensure your target platform shows ✅. Fix any issues `flutter doctor` reports.

### Clone and Build

```bash
git clone https://github.com/clubanderson/clubTivi.git
cd clubTivi
flutter pub get

# Run in debug mode
flutter run

# Build for release
flutter build apk --release          # Android APK
flutter build appbundle --release     # Android App Bundle (Play Store)
flutter build macos --release         # macOS
flutter build windows --release       # Windows
flutter build linux --release         # Linux
```

### Run Tests

```bash
flutter test                          # Unit & widget tests
flutter test integration_test/        # Integration tests
```

---

## 🔄 Updating

### Pre-built releases
Download and install the new version. It will replace the previous installation.

### From source
```bash
cd clubTivi
git pull origin main
flutter pub get
flutter build <platform> --release
```

---

## ❓ Troubleshooting

### All Platforms
| Issue | Solution |
|-------|----------|
| Video won't play | Check your playlist URL is accessible. Try opening in VLC first. |
| EPG not loading | Verify the XMLTV URL is reachable. Check **Settings → EPG → Refresh**. |
| App crashes on launch | Run `flutter clean && flutter pub get` and rebuild. |

### iOS / iPadOS
| Issue | Solution |
|-------|----------|
| Build fails: "iOS platform not installed" | Open Xcode → Settings → Components → Download iOS |
| "Untrusted Developer" on device | Go to Settings → General → VPN & Device Management → Trust |
| No audio on some channels | Some eac3 streams may need codec configuration; check player settings |

### Android TV
| Issue | Solution |
|-------|----------|
| Can't find app after install | Look in **Settings → Apps → See all apps** |
| Remote doesn't work | Ensure you're using the D-pad. clubTivi's TV UI is fully D-pad navigable. |
| "App not installed" error | Uninstall any previous version first, or ensure you're using the same signing key. |

### macOS
| Issue | Solution |
|-------|----------|
| "App is damaged" error | Run: `xattr -cr /Applications/clubTivi.app` |
| No audio | Check **System Settings → Sound → Output** and app volume in the player. |

### Linux
| Issue | Solution |
|-------|----------|
| No video output | Install `libmpv1`: `sudo apt install libmpv1` |
| Wayland issues | Try running with: `GDK_BACKEND=x11 ./clubtivi` |
| Missing libgtk | Install: `sudo apt install libgtk-3-0` |

### Windows
| Issue | Solution |
|-------|----------|
| Missing DLL errors | Install [Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) |
| Windows Defender blocks app | Click **More info → Run anyway** on the SmartScreen prompt |
