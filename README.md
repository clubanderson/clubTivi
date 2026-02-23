# ⚡ clubTivi

**The open-source IPTV player that never buffers.** Combine multiple providers into one seamless experience with Smart Channels, intelligent EPG matching, and automatic stream failover.

Built with [Flutter](https://flutter.dev) for Android, macOS, Linux, and Windows.

---

## Why clubTivi?

Most IPTV players let you watch one provider at a time. When a stream buffers, you're stuck. clubTivi changes that — it **combines all your providers** into a single unified experience and **automatically switches streams** when problems are detected. No more buffering. No more manually hunting for a working channel.

---

## ✨ Features

### ⚡ Smart Channels
The headline feature that sets clubTivi apart. Group the same channel from multiple providers into a single **Smart Channel**:

- **One-click creation** — multi-select matching channels, hit "New Smart Channel"
- **Automatic failover** — when buffering is detected, instantly switches to the next healthy stream
- **Priority ordering** — arrange streams in your preferred order; the best source plays first
- **Full EPG integration** — Smart Channels show the same guide data as regular channels
- **Visual indicators** — amber ⚡ bolt icon, playing-stream highlight, expand to see all members
- **Right-click management** — rename, delete, remove members, add channels to existing groups

### 📺 EPG (Electronic Program Guide)
- **4-tier intelligent auto-matching** — explicit mapping → tvgId lookup → normalized name match → call-sign extraction (WABC, WCBS, etc.)
- **Full timeline guide view** — horizontally scrollable multi-day programme grid with now-playing highlight
- **EPG for Smart Channels** — guide data pulls from the best-matched member automatically
- **XMLTV support** — load EPG from any URL or local file
- **Compatible with EPG providers** like epg.best and others
- **Now-playing text** on every channel row — see what's on without opening the guide

### 🔄 Multi-Provider Management
- **Unlimited providers** — add as many M3U, M3U Plus, or Xtream Codes sources as you want
- **Unified channel list** — all providers merge into one searchable, filterable view
- **Provider badges** — see which provider each stream comes from at a glance
- **324K+ channels tested** — handles massive playlists with instant startup via phased loading

### ⭐ Favorites & Organization
- **Multiple favorite lists** — create custom lists (Sports, News, Movies, etc.)
- **Sidebar navigation** — browse by provider group, favorite list, or "All Channels"
- **Smart search** — real-time filtering with debounced search across all channels
- **Vanity names** — rename any channel without affecting the underlying data
- **Channel history** — backspace to toggle between current and previous channel

### 🎮 Keyboard & Remote Control
- **Full keyboard navigation** — arrow keys, Enter for fullscreen, number keys for direct channel entry
- **Volume control** — left/right arrow keys adjust volume with visual overlay
- **D-pad optimized** — Android TV remote and gamepad support with focus-based navigation
- **Multi-select** — Shift+click or Cmd+click to select multiple channels for batch operations
- **Debug dialog** — press `D` to see stream details, EPG mapping, provider info, and failover alternatives

### 🖥️ Player & Playback
- **media_kit** powered — libmpv/FFmpeg backend for broad codec support
- **Fullscreen mode** — double-click or press Enter to toggle
- **Preview row** — see a live preview of the selected channel before committing
- **Info overlay** — channel name, EPG now-playing, and provider shown on channel switch
- **Multi-audio track support** — handles streams with multiple audio tracks (EAC-3, AAC, etc.)

### 🚀 Performance
- **Instant startup** — favorites and providers load first (Phase 0), everything else loads in background
- **Phased loading** — splash screen → favorites → sidebar groups → EPG → full channel list
- **Lazy EPG loading** — guide data fetched only for visible/favorite channels first
- **Efficient logo caching** — channel logos load once and persist across sessions
- **Session persistence** — remembers your last channel, scroll position, and sidebar state

### 🌐 Cross-Platform
| Platform | Status |
|----------|--------|
| **macOS** | ✅ Full support |
| **Android** (Phone/Tablet/TV) | ✅ Full support |
| **Linux** | ✅ Full support |
| **Windows** | ✅ Full support |

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.29+)
- For Android: Android Studio + Android SDK
- For macOS: Xcode 15+
- For Linux: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libmpv-dev`
- For Windows: Visual Studio 2022 with C++ desktop development workload

### Build & Run

```bash
git clone https://github.com/clubanderson/clubTivi.git
cd clubTivi
flutter pub get
flutter run -d macos       # or linux, windows, <android-id>
```

### First Launch
1. Go to **Settings** (gear icon) and add your IPTV provider (M3U URL or Xtream Codes credentials)
2. Add an EPG source URL for programme guide data
3. Channels load automatically — star your favorites ⭐
4. Multi-select channels → create **Smart Channels** ⚡ for automatic failover

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| UI Framework | Flutter 3.29+ / Dart 3.11+ |
| State Management | Riverpod |
| Video Playback | media_kit (libmpv/FFmpeg) |
| Local Database | Drift (SQLite) |
| EPG Parsing | Custom XMLTV parser |
| Playlist Parsing | Custom M3U/M3U+ & Xtream Codes parser |

---

## 🏗️ Architecture

```
lib/
├── main.dart                      # App entry point
├── data/
│   ├── datasources/local/         # Drift database, queries, migrations
│   ├── models/                    # Channel, EPG, Provider models
│   └── services/                  # Stream alternatives, failover engine
├── features/
│   ├── channels/                  # Channel list, guide view, Smart Channels, sidebar
│   ├── player/                    # Video player, failover, playback controls
│   ├── providers/                 # Provider management (add/edit/delete)
│   ├── settings/                  # App settings, EPG config
│   └── shows/                     # VOD / series browser
└── platform/                      # Platform-specific adaptations
```

**Key design decisions:**
- **Single-screen architecture** — channels, guide, search, and Smart Channels all live in `channels_screen.dart` for instant navigation
- **Phased startup** — favorites render in <1s, full channel list loads incrementally in background
- **Smart Channel groups** stored in SQLite (`failover_groups` + `failover_group_channels` tables) with in-memory index for O(1) lookups
- **EPG matching** runs 4 tiers of heuristics so channels match guide data without manual configuration

---

## 📋 Roadmap

### ✅ Shipped
- [x] Multi-platform Flutter app (macOS, Android, Linux, Windows)
- [x] M3U / M3U Plus / Xtream Codes parser
- [x] Video player with media_kit
- [x] Channel list with favorites, search, groups
- [x] XMLTV EPG parser with 4-tier auto-matching
- [x] Full timeline guide view
- [x] Multi-provider management
- [x] Smart Channels with automatic failover
- [x] Keyboard, gamepad, and remote control navigation
- [x] Instant startup with phased loading
- [x] Session persistence

### 🔜 Coming Next
- [ ] Warm failover (background stream health monitoring)
- [ ] Catch-up / timeshift (provider-dependent)
- [ ] Recording (local DVR)
- [ ] Theming and customization
- [ ] Backup/restore settings and Smart Channel configs
- [ ] Multi-language support
- [ ] Web companion remote control

---

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/amazing-feature`)
3. Commit with DCO sign-off (`git commit -s -m 'feat: add amazing feature'`)
4. Push and open a PR

---

## 📄 License

This project is licensed under the Apache License 2.0 — see the [LICENSE](LICENSE) file for details.

---

## ⚠️ Disclaimer

clubTivi is a media player application. It does not provide any content, streams, or IPTV subscriptions. Users are responsible for ensuring they have the legal right to access any content they configure in the application.
