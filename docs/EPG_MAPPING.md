# EPG Mapping Engine

clubTivi's EPG mapping engine automatically matches playlist channels to EPG program data — and gives users full control to override, tune, and manage those mappings.

---

## Overview

Most IPTV playlists have incomplete or inconsistent EPG identifiers. Channels might have a `tvg-id` that doesn't match any EPG source, or no `tvg-id` at all. clubTivi solves this with a multi-strategy auto-mapper plus a management UI for manual control.

```
┌──────────────────┐     ┌───────────────────┐     ┌──────────────────┐
│  Playlist Channels│     │  EPG Sources       │     │  Mapping Store   │
│                  │     │                   │     │                  │
│  - tvg-id        │────►│  - XMLTV URLs      │────►│  channel_id →    │
│  - tvg-name      │     │  - epg.best        │     │    epg_channel_id│
│  - group-title   │     │  - Xtream EPG      │     │  + confidence    │
│  - channel number│     │  - Custom sources   │     │  + source        │
└──────────────────┘     └───────────────────┘     │  + manual_override│
                                                    └──────────────────┘
```

---

## Auto-Mapping Strategies

The mapper runs multiple strategies in order of confidence, combining scores:

### Strategy 1: Exact tvg-id Match (Confidence: 1.0)
```
Playlist: tvg-id="ESPN.us"
EPG:      channel id="ESPN.us"
→ Direct match, highest confidence
```

### Strategy 2: Normalized ID Match (Confidence: 0.95)
Normalize both IDs by lowercasing, stripping whitespace, removing common suffixes:
```
Playlist: tvg-id="ESPN_US_HD"
EPG:      channel id="espn.us"
→ Normalize: "espnus" == "espnus" → match
```

Normalization rules:
- Lowercase
- Remove: `.`, `-`, `_`, spaces
- Strip suffixes: `HD`, `FHD`, `UHD`, `4K`, `SD`, `HEVC`, `H265`, `H.265`
- Strip country codes when matching fails: `US`, `UK`, `CA`, etc.

### Strategy 3: Fuzzy Name Match (Confidence: 0.6–0.9)
Compare `tvg-name` (or channel display name) against EPG channel display names using:
- Levenshtein distance (edit distance)
- Jaro-Winkler similarity
- Token-based overlap (split into words, compare sets)

```
Playlist: tvg-name="ESPN Sports HD"
EPG:      display-name="ESPN" + display-name="ESPN Sports"
→ Token overlap: {"ESPN","Sports"} ∩ {"ESPN","Sports"} = 1.0
→ Confidence: 0.85 (high token overlap, name length difference penalty)
```

### Strategy 4: Channel Number Match (Confidence: 0.5)
If playlist provides `tvg-chno` and EPG has channel numbers:
```
Playlist: tvg-chno="206"
EPG:      channel number="206"
→ Number match, moderate confidence (numbers can differ by provider)
```

### Strategy 5: Logo/Icon URL Similarity (Confidence: 0.4)
Compare `tvg-logo` URLs — same logo URL often means same channel:
```
Playlist: tvg-logo="https://cdn.example.com/logos/espn.png"
EPG:      icon src="https://cdn.example.com/logos/espn.png"
→ Exact URL match, supplemental confidence boost
```

### Combined Scoring
```dart
double computeConfidence(List<StrategyResult> results) {
  // Take the highest-confidence strategy as base
  double base = results.map((r) => r.confidence).reduce(max);
  
  // Boost for multiple corroborating strategies (diminishing returns)
  double corroboration = 0;
  for (var r in results.where((r) => r.confidence > 0.3)) {
    corroboration += r.confidence * 0.1;
  }
  
  return min(1.0, base + corroboration);
}
```

Mappings with confidence ≥ 0.7 are auto-applied. Mappings between 0.4–0.7 are suggested (shown in UI for user confirmation). Below 0.4 are not mapped.

---

## EPG Sources

### Supported Formats
- **XMLTV** — standard XML format, most common
- **Xtream Codes EPG** — fetched via Xtream API (`get_short_epg`, `get_simple_data_table`)
- **JTV** — legacy binary format (limited support)

### Provider Integration

#### epg.best
```
URL: http://epg.best/xmltv/epg.xml.gz
Channels: ~10,000+ worldwide
Format: XMLTV (gzipped)
Refresh: Every 12 hours recommended
```

#### Custom XMLTV
Users can add any XMLTV URL. clubTivi fetches, parses, and indexes it.

### EPG Data Model
```dart
class EpgChannel {
  final String id;            // XMLTV channel id
  final List<String> names;   // display-name elements (can have multiple)
  final String? icon;         // channel icon URL
  final String? number;       // channel number
  final String source;        // which EPG source this came from
}

class EpgProgramme {
  final String channelId;     // references EpgChannel.id
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? subtitle;     // episode title
  final String? description;
  final String? category;     // genre
  final String? icon;         // program artwork
  final String? episodeNum;   // e.g., "S02E05"
  final String? rating;       // parental rating
  final bool isNew;           // first airing
}
```

---

## Mapping Management UI

### Views

#### 1. Mapping Overview
Shows all channels with their current EPG mapping status:

```
┌─────────────────────────────────────────────────────────────────┐
│ EPG Mappings                              [Auto-Map All] [Import]│
├─────────────────────────────────────────────────────────────────┤
│ 🟢 Mapped (842)  🟡 Suggested (23)  🔴 Unmapped (45)  Total: 910│
├─────────────────────────────────────────────────────────────────┤
│ Channel              │ EPG Match          │ Confidence │ Source  │
│──────────────────────│────────────────────│────────────│─────────│
│ ESPN HD              │ ESPN               │ ██████ 95% │ auto    │
│ CNN International    │ CNN Int'l          │ █████░ 82% │ auto    │
│ FOX Sports 1         │ FS1                │ ████░░ 67% │ suggest │
│ My Local Channel     │ —                  │ ░░░░░░  0% │ none    │
│ ...                  │                    │            │         │
└─────────────────────────────────────────────────────────────────┘
```

#### 2. Manual Mapping Editor
For unmapped or incorrectly mapped channels:

```
┌──────────────────────────────────────────┐
│ Map: "FOX Sports 1"                      │
│                                          │
│ Search EPG: [fox sports          ] 🔍    │
│                                          │
│ Suggestions:                             │
│  ○ FS1 (epg.best)           — 67%       │
│  ○ Fox Sports 1 (xtream)    — 72%       │
│  ○ FOX Sports (epg.best)    — 58%       │
│  ○ No EPG mapping                        │
│                                          │
│             [Apply]  [Skip]              │
└──────────────────────────────────────────┘
```

#### 3. Bulk Operations
- **Auto-map all unmapped** — run auto-mapper on all unmapped channels
- **Accept all suggestions** — apply all suggested mappings above a confidence threshold
- **Clear all mappings** — reset to unmapped state
- **Import/Export** — save/load mapping profiles as JSON

### Mapping Profiles
Users can save mapping configurations and share them:

```json
{
  "profile_name": "US Cable Package",
  "epg_sources": ["http://epg.best/xmltv/epg.xml.gz"],
  "mappings": {
    "ESPN.HD": { "epg_id": "ESPN.us", "source": "manual" },
    "CNN.INT": { "epg_id": "CNN.International", "source": "auto", "confidence": 0.95 }
  },
  "created": "2026-02-21T03:00:00Z",
  "channel_count": 910
}
```

---

## Database Schema

```sql
CREATE TABLE epg_sources (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  url TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'xmltv',  -- xmltv, xtream
  last_refresh INTEGER,                 -- epoch ms
  refresh_interval INTEGER DEFAULT 43200000, -- 12h in ms
  enabled INTEGER DEFAULT 1,
  channel_count INTEGER DEFAULT 0
);

CREATE TABLE epg_channels (
  id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  display_name TEXT,
  icon_url TEXT,
  channel_number TEXT,
  PRIMARY KEY (id, source_id),
  FOREIGN KEY (source_id) REFERENCES epg_sources(id)
);

CREATE TABLE epg_programmes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  channel_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  start_time INTEGER NOT NULL,          -- epoch ms
  end_time INTEGER NOT NULL,
  title TEXT NOT NULL,
  subtitle TEXT,
  description TEXT,
  category TEXT,
  icon_url TEXT,
  episode_num TEXT,
  rating TEXT,
  is_new INTEGER DEFAULT 0,
  FOREIGN KEY (channel_id, source_id) REFERENCES epg_channels(id, source_id)
);

CREATE INDEX idx_programmes_time ON epg_programmes(channel_id, start_time, end_time);

CREATE TABLE epg_mappings (
  playlist_channel_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  epg_channel_id TEXT,
  epg_source_id TEXT,
  confidence REAL DEFAULT 0,
  source TEXT DEFAULT 'auto',           -- auto, manual, suggested
  manual_override INTEGER DEFAULT 0,
  updated_at INTEGER,
  PRIMARY KEY (playlist_channel_id, provider_id)
);

CREATE TABLE epg_mapping_profiles (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  data TEXT NOT NULL,                    -- JSON blob
  created_at INTEGER,
  updated_at INTEGER
);
```
