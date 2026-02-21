# clubTivi

**Open-source cross-platform IPTV player** with intelligent EPG mapping, multi-provider stream failover, and remote control support.

Built with [Flutter](https://flutter.dev) for Android, macOS, Linux, and Windows.

---

## ✨ Key Features

### Core IPTV Player
- **M3U / M3U Plus** playlist support
- **Xtream Codes API** integration
- Multi-provider playlist management
- Channel favorites, groups, and search
- Picture-in-Picture (PiP) mode

### 📺 EPG (Electronic Program Guide)
- XMLTV EPG support from any URL
- **Intelligent auto-mapping** — automatically matches channels to EPG data
- **EPG mapping management** — manual override and custom mapping profiles
- Compatible with EPG providers (epg.best, etc.)
- Multi-day program guide with timeline view
- Program reminders and recording schedule

### 🔄 Multi-Provider Stream Failover
The headline feature that sets clubTivi apart:

- **Cold Failover** — When buffering is detected, automatically switch to an alternative stream carrying the same content from a different provider. Seamless to the user.
- **Warm Failover** — clubTivi monitors alternative streams in the background, pre-validating they are healthy before switching. When the active stream degrades, it instantly switches to a known-good alternative with zero delay.

### 🎮 Remote Control Support
- Full IR/Bluetooth remote support on Android TV
- Keyboard and gamepad navigation on desktop
- D-pad optimized 10-foot UI
- Customizable remote button mappings

### 🌐 Cross-Platform
- **Android** (Phone, Tablet, Android TV)
- **macOS**
- **Linux**
- **Windows**

---

## 🏗️ Architecture

```
clubTivi/
├── lib/                        # Dart/Flutter source
│   ├── main.dart
│   ├── app/                    # App shell, routing, themes
│   ├── core/                   # Shared utilities, constants
│   ├── data/                   # Data layer
│   │   ├── models/             # Data models (Channel, EPG, Playlist, Provider)
│   │   ├── repositories/       # Repository pattern implementations
│   │   ├── datasources/        # Local DB, remote APIs, file parsers
│   │   └── services/           # Stream monitor, failover engine, EPG mapper
│   ├── features/               # Feature modules
│   │   ├── player/             # Video player + overlay controls
│   │   ├── guide/              # EPG guide views
│   │   ├── channels/           # Channel list, favorites, groups
│   │   ├── providers/          # Provider/playlist management
│   │   ├── epg_mapping/        # EPG mapping management UI
│   │   ├── settings/           # App settings
│   │   └── remote/             # Remote control handling
│   └── platform/               # Platform-specific code
│       ├── android/
│       ├── desktop/
│       └── tv/                 # 10-foot UI adaptations
├── android/
├── macos/
├── linux/
├── windows/
├── test/
├── integration_test/
└── docs/
```

---

## 📖 Documentation

- **[Installation Guide](docs/INSTALL.md)** — Install on Android/TV, macOS, Windows, Linux
- **[Easy Install (Android TV)](docs/EASY_INSTALL.md)** — Phone-to-TV push, QR codes, short codes — zero typing on TV
- **[Remote Control](docs/REMOTE_CONTROL.md)** — Physical remotes, keyboard shortcuts, gamepad, web companion remote
- **[EPG Mapping Engine](docs/EPG_MAPPING.md)** — Auto-mapping, manual management, provider integration
- **[Stream Failover](docs/FAILOVER.md)** — Cold & warm failover architecture, buffering detection, cross-provider switching
- **[Contributing](CONTRIBUTING.md)** — Development setup, architecture, PR process

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.24+)
- For Android: Android Studio + Android SDK
- For macOS: Xcode 15+
- For Linux: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libmpv-dev`
- For Windows: Visual Studio 2022 with C++ desktop development workload

### Build & Run

```bash
# Clone the repo
git clone https://github.com/clubanderson/clubTivi.git
cd clubTivi

# Get dependencies
flutter pub get

# Run on your platform
flutter run                    # default connected device
flutter run -d macos           # macOS
flutter run -d linux           # Linux
flutter run -d windows         # Windows
flutter run -d <android-id>    # Android device/emulator
```

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| UI Framework | Flutter 3.24+ / Dart 3.5+ |
| State Management | Riverpod |
| Video Playback | media_kit (libmpv/FFmpeg) |
| Local Database | Isar / Drift (SQLite) |
| Networking | Dio |
| EPG Parsing | Custom XMLTV parser |
| Playlist Parsing | Custom M3U/M3U+ parser |
| DI | Riverpod |
| Testing | flutter_test, integration_test |

---

## 📋 Roadmap

### Phase 1 — Foundation
- [ ] Project scaffold (Flutter multi-platform)
- [ ] M3U / M3U Plus parser
- [ ] Xtream Codes API client
- [ ] Video player integration (media_kit)
- [ ] Basic channel list UI
- [ ] Local database for playlists and settings

### Phase 2 — EPG & Guide
- [ ] XMLTV EPG parser
- [ ] EPG auto-mapping engine
- [ ] EPG mapping management UI
- [ ] Timeline guide view
- [ ] Program search and reminders

### Phase 3 — Multi-Provider & Failover
- [ ] Multi-provider playlist management
- [ ] Channel cross-referencing across providers
- [ ] Cold failover (buffering detection → switch)
- [ ] Warm failover (background stream health monitoring)
- [ ] Failover analytics and logging

### Phase 4 — Remote & TV
- [ ] Android TV launcher integration
- [ ] IR/Bluetooth remote support
- [ ] 10-foot UI (D-pad navigation, large text)
- [ ] Desktop keyboard/gamepad navigation
- [ ] Custom remote button mappings

### Phase 5 — Polish
- [ ] Theming and customization
- [ ] Backup/restore settings
- [ ] Multi-language support
- [ ] Catch-up / timeshift (provider-dependent)
- [ ] Recording (local DVR)

---

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/amazing-feature`)
3. Commit with sign-off (`git commit -s -m 'feat: add amazing feature'`)
4. Push and open a PR

---

## 📄 License

This project is licensed under the Apache License 2.0 — see the [LICENSE](LICENSE) file for details.

---

## ⚠️ Disclaimer

clubTivi is a media player application. It does not provide any content, streams, or IPTV subscriptions. Users are responsible for ensuring they have the legal right to access any content they configure in the application.
