# epg.best Integration Guide

clubTivi has first-class support for **epg.best** — the most popular third-party EPG provider for IPTV. This document covers the full mapping workflow between your service provider's channels and epg.best's program guide data.

---

## Overview

The core problem: your IPTV service provider gives you channels like `US: ESPN HD` or `ESPN (FHD)`, but epg.best has EPG entries keyed by IDs like `ESPN.us` or `ESPN2.us`. These don't automatically match. clubTivi bridges this gap.

```
┌────────────────────────┐          ┌────────────────────────┐
│  Your IPTV Provider    │          │  epg.best              │
│                        │          │                        │
│  Channel: US: ESPN HD  │    ?     │  EPG ID: ESPN.us       │
│  tvg-id: ""            │◄────────►│  Name: ESPN            │
│  tvg-name: US: ESPN HD │          │  Programs: [...]       │
│                        │          │                        │
│  Channel: CNN Int      │    ?     │  EPG ID: CNNInt.us     │
│  tvg-id: "cnn"         │◄────────►│  Name: CNN Intl        │
│                        │          │  Programs: [...]       │
└────────────────────────┘          └────────────────────────┘

        clubTivi Mapping Engine resolves the "?" automatically
        and gives you full control to fix mismatches
```

---

## Setup

### Step 1: Add Your epg.best Feed

Go to **Settings → EPG Sources → Add Source**:

```
┌──────────────────────────────────────────────────────────────┐
│  Add EPG Source                                              │
│                                                              │
│  Name:  [epg.best                    ]                       │
│  URL:   [http://epg.best/xmltv/epg.xml.gz]                  │
│  Type:  ● XMLTV   ○ Xtream                                  │
│                                                              │
│  ☑ Auto-refresh every [12] hours                             │
│  ☑ Compress (gzip) — faster downloads                        │
│                                                              │
│  [Test Connection]          [Save]                            │
└──────────────────────────────────────────────────────────────┘
```

epg.best offers multiple feeds:
| Feed | URL | Channels |
|------|-----|----------|
| Full | `http://epg.best/xmltv/epg.xml.gz` | ~15,000+ worldwide |
| US/CA | `http://epg.best/xmltv/epg_US.xml.gz` | ~3,000 US/Canada |
| UK | `http://epg.best/xmltv/epg_UK.xml.gz` | ~1,500 UK |
| Custom | Via epg.best dashboard | Your selection |

clubTivi auto-detects gzip compression and handles it transparently.

### Step 2: Auto-Map Channels

After adding the EPG source, clubTivi runs the auto-mapper:

```
┌──────────────────────────────────────────────────────────────┐
│  Auto-Mapping Results                                        │
│                                                              │
│  EPG Source: epg.best (14,823 EPG channels loaded)           │
│  Provider: My IPTV Service (1,247 channels)                  │
│                                                              │
│  ████████████████████░░░░░  82% mapped automatically         │
│                                                              │
│  ✅ Mapped:     1,023 channels (82%)                          │
│  🟡 Suggested:     89 channels (7%)  — need your confirmation │
│  🔴 Unmapped:     135 channels (11%) — need manual mapping    │
│                                                              │
│  [Review Suggestions]  [Map Unmapped]  [Done]                │
└──────────────────────────────────────────────────────────────┘
```

---

## The Mapping Manager

The heart of clubTivi's EPG management. Access via **EPG → Manage Mappings** or **Settings → EPG → Mapping Manager**.

### Main View

```
┌──────────────────────────────────────────────────────────────────────┐
│  EPG Mapping Manager                                                 │
│                                                                      │
│  Provider: [My IPTV Service ▾]   EPG: [epg.best ▾]                  │
│                                                                      │
│  Filter: [All ▾]  Group: [All Groups ▾]  Search: [____________] 🔍  │
│                                                                      │
│  ┌─────┬──────────────────┬──────────────────┬──────┬────────┐      │
│  │ Sta │ Provider Channel  │ epg.best Match   │ Conf │ Action │      │
│  ├─────┼──────────────────┼──────────────────┼──────┼────────┤      │
│  │ ✅  │ US: ESPN HD       │ ESPN.us          │ 97%  │ [Edit] │      │
│  │ ✅  │ US: ESPN2 HD      │ ESPN2.us         │ 95%  │ [Edit] │      │
│  │ ✅  │ US: CNN           │ CNN.us           │ 92%  │ [Edit] │      │
│  │ 🟡  │ US: Fox Sports 1  │ FS1.us (67%)     │ 67%  │ [Map]  │      │
│  │ 🟡  │ UK: Sky Sports PL │ SkySp1.uk (58%)  │ 58%  │ [Map]  │      │
│  │ 🔴  │ US: My Local News │ —                │  0%  │ [Map]  │      │
│  │ 🔴  │ PPV: UFC 300      │ —                │  0%  │ [Map]  │      │
│  │ ✅🔒│ US: NBC           │ NBC.us (manual)  │ 100% │ [Edit] │      │
│  └─────┴──────────────────┴──────────────────┴──────┴────────┘      │
│                                                                      │
│  🔒 = manual override (won't be changed by auto-mapper)              │
│                                                                      │
│  [Auto-Map All]  [Accept Suggestions]  [Export]  [Import]            │
└──────────────────────────────────────────────────────────────────────┘
```

### Mapping a Channel

When you click **[Map]** on an unmapped or suggested channel:

```
┌──────────────────────────────────────────────────────────────┐
│  Map Channel: "US: Fox Sports 1"                             │
│                                                              │
│  Current EPG: (none)                                         │
│  Provider tvg-id: "fox_sports_1"                             │
│  Provider group: US Sports                                   │
│                                                              │
│  ─── Search epg.best ──────────────────────────────────────  │
│  [fox sports                                        ] 🔍     │
│                                                              │
│  Results:                                                    │
│  ◉ FS1.us — "FS1" (Fox Sports 1)                    67% 🟡  │
│  ○ FoxSports.us — "Fox Sports"                      52%     │
│  ○ FS2.us — "FS2" (Fox Sports 2)                    41%     │
│  ○ FoxSportsAsia.sg — "Fox Sports Asia"              28%     │
│  ○ (No EPG mapping)                                          │
│                                                              │
│  ☑ Lock this mapping (manual override)                       │
│                                                              │
│  Preview EPG for selected:                                   │
│  ┌──────────────────────────────────────────────────┐       │
│  │ Now:  College Basketball: Duke vs UNC             │       │
│  │ Next: NFL Live                                    │       │
│  │ 8PM:  SportsCenter                                │       │
│  └──────────────────────────────────────────────────┘       │
│                                                              │
│            [Apply]     [Skip]     [No EPG]                   │
└──────────────────────────────────────────────────────────────┘
```

Key features:
- **Live EPG preview** — see the current/next programs before committing
- **Lock mapping** — prevents auto-mapper from changing it on future runs
- **Search** — full-text search across all epg.best channel names and IDs
- **Fuzzy results** — ranked by match confidence with color indicators

### Bulk Operations

#### Accept All Suggestions
Applies all 🟡 suggested mappings (confidence 40-70%) in one click. Shows a confirmation:

```
Apply 89 suggested mappings?
  67 with confidence > 60%
  22 with confidence 40-60%

[Apply All]  [Apply > 60% Only]  [Cancel]
```

#### Re-Run Auto-Mapper
Useful after provider adds new channels or epg.best updates their channel list:

```
Re-mapping options:
  ○ Only map unmapped channels (keep existing mappings)
  ● Re-map everything except locked (🔒) mappings
  ○ Re-map ALL channels (reset everything)

[Run]
```

---

## EPG ID Patterns in epg.best

Understanding epg.best's naming conventions helps with manual mapping:

| Pattern | Example | Meaning |
|---------|---------|---------|
| `Name.country` | `ESPN.us` | US feed of ESPN |
| `Name2.country` | `ESPN2.us` | ESPN2 US |
| `NameHD.country` | `ESPNHD.us` | HD variant (rare, usually same as base) |
| `NameInt.country` | `CNNInt.us` | International feed |
| `NamePlus.country` | `DiscPlus.us` | "Plus" branded channel |
| `NameSp.country` | `SkySp1.uk` | Sports channel |

clubTivi's auto-mapper knows these patterns and uses them for matching.

---

## Multi-Provider EPG Mapping

When you have multiple IPTV providers, each may have different channel names for the same content:

```
Provider A: "US: ESPN HD"        → ESPN.us
Provider B: "ESPN (USA) FHD"     → ESPN.us
Provider C: "ESPNHD_US"         → ESPN.us
```

clubTivi maps **each provider independently** to epg.best, then uses these shared EPG IDs to build the cross-provider channel map (used for failover):

```
ESPN.us (epg.best) ─┬── Provider A: "US: ESPN HD"    (stream URL A)
                     ├── Provider B: "ESPN (USA) FHD" (stream URL B)
                     └── Provider C: "ESPNHD_US"      (stream URL C)
```

This means EPG mapping directly enables intelligent failover — channels that map to the same epg.best ID are automatically recognized as the same content.

---

## Import / Export Mappings

### Export
Save your mapping work to share or backup:

```json
{
  "format": "clubtivi_epg_mapping_v1",
  "epg_source": "epg.best",
  "provider": "My IPTV Service",
  "exported_at": "2026-02-21T03:00:00Z",
  "stats": {
    "total": 1247,
    "mapped": 1112,
    "manual": 89,
    "unmapped": 135
  },
  "mappings": [
    {
      "provider_channel": "US: ESPN HD",
      "provider_tvg_id": "espn_hd",
      "provider_group": "US Sports",
      "epg_id": "ESPN.us",
      "confidence": 0.97,
      "source": "auto",
      "locked": false
    },
    {
      "provider_channel": "US: NBC",
      "provider_tvg_id": "",
      "provider_group": "US Network",
      "epg_id": "NBC.us",
      "confidence": 1.0,
      "source": "manual",
      "locked": true
    }
  ]
}
```

### Import
Load a previously exported mapping file. Useful when:
- Switching devices
- Sharing mappings with friends who use the same provider
- Restoring after a fresh install
- Community-shared mapping profiles for popular providers

### Community Mapping Profiles (Future)
A shared repository where users can upload and download mapping profiles for specific providers:

```
Popular Mapping Profiles:
  📥 "Provider X → epg.best US" by user123 (1,200 mappings, 94% coverage)
  📥 "Provider Y → epg.best UK" by tvsurfer (800 mappings, 91% coverage)
  📥 "Provider Z → epg.best Full" by iptvfan (2,100 mappings, 88% coverage)
```

---

## Automatic EPG Refresh & Re-mapping

clubTivi keeps EPG data fresh and adapts to changes:

```
Schedule:
  ├── Every 12 hours: Fetch latest epg.best XMLTV data
  ├── Every 24 hours: Refresh provider channel list
  ├── On channel list change: Auto-map new channels
  └── On EPG refresh: Update programme data, keep mappings stable

Mapping stability:
  - Existing mappings are NEVER changed automatically
  - Only NEW/unmapped channels trigger auto-mapping
  - Locked (🔒) mappings are never touched
  - User is notified of new unmapped channels
```

---

## Troubleshooting

### "No EPG data showing for mapped channel"
1. Check the mapping: **EPG → Manage Mappings → Search for channel**
2. Verify the epg.best ID is correct — click [Edit] and check EPG preview
3. Check EPG refresh: **Settings → EPG → Last Refresh** — force refresh if stale
4. Some epg.best channels have limited programme data for certain time zones

### "Auto-mapper matched wrong channel"
1. Click [Edit] on the incorrectly mapped channel
2. Search for the correct epg.best channel
3. Check **Lock this mapping** so it won't be overridden
4. The auto-mapper learns from your corrections for similar channel patterns

### "Many channels unmapped"
Common reasons:
- Provider uses unusual channel naming (e.g., coded names like `CH_12847`)
- Channels are regional/local with no epg.best coverage
- Provider's tvg-id fields are empty or nonsensical

Solutions:
- Use bulk manual mapping (sort by group, map similar channels together)
- Import a community mapping profile for your provider
- For uncovered channels, consider adding a second EPG source
