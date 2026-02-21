# Stream Failover Engine

clubTivi's core differentiator: when a stream buffers or fails, it automatically switches to an alternative source carrying the same content. Supports two modes — **Cold** and **Warm**.

---

## Overview

```
                         ┌─────────────────────────┐
                         │   Failover Controller    │
                         │                          │
                         │  ┌───────────────────┐   │
                         │  │ Stream Health      │   │
                    ┌────┼──│ Monitor            │   │
                    │    │  └───────────────────┘   │
                    │    │            │              │
                    │    │            ▼              │
┌──────────────┐    │    │  ┌───────────────────┐   │    ┌──────────────────┐
│ Active Stream │◄───┘    │  │ Decision Engine   │───┼───►│ Channel Registry │
│ (Provider A)  │         │  │                   │   │    │ (cross-ref map)  │
└──────────────┘         │  └───────────────────┘   │    └──────────────────┘
                         │            │              │
                    ┌────┼────────────┘              │
                    │    │                           │
                    ▼    │  ┌───────────────────┐   │
┌──────────────┐    │    │  │ Background Probes  │   │
│ Backup Stream │◄───┘    │  │ (Warm mode only)  │   │
│ (Provider B)  │         │  └───────────────────┘   │
└──────────────┘         └─────────────────────────┘
```

---

## Failover Modes

### ❄️ Cold Failover

**How it works:** When the active stream shows signs of degradation (buffering, stalling, errors), clubTivi switches to the next available stream source for the same channel.

```
Timeline:

0s      5s      10s     15s     20s     25s
│───────│───────│───────│───────│───────│
│ Stream A playing OK   │ Buffer│ Stall │
│                       │detected│      │
│                       │       ▼       │
│                       │  Switch to B  │
│                       │       │───────│───── Stream B playing
│                       │               │
│                    ~2-5s switch time   │
```

**Characteristics:**
- Zero background resource usage
- Switch time = connection time to new stream (typically 2–5 seconds)
- Brief interruption visible to user (black screen / spinner)
- Tries sources in priority order until one works

**When to use:** Default mode. Good for most users. Minimal battery/bandwidth overhead.

### 🔥 Warm Failover

**How it works:** clubTivi maintains lightweight background probes on alternative streams. It knows which backups are healthy *before* the active stream fails. Switch is near-instant.

```
Timeline:

0s      5s      10s     15s     20s     25s
│───────│───────│───────│───────│───────│
│ Stream A playing OK   │ Buffer│       │
│                       │detected       │
│ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│┄┄┄┄┄┄┄┄┄┄┄┄┄│ Stream B probe (periodic)
│ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│┄┄┄┄┄┄┄┄┄┄┄┄┄│ Stream C probe (periodic)
│                       │  ▼            │
│                       │  B is healthy!│
│                       │  Switch to B  │──── Stream B playing
│                       │               │
│                    ~0.5-1s switch time │
```

**Characteristics:**
- Background probes use ~50-100 KB/s per monitored stream
- Near-instant switch (<1 second) because stream is pre-validated
- Configurable probe interval (default: 30 seconds)
- Probes only fetch stream headers + a few packets — not full playback
- Resource-aware: reduces probe frequency on battery / metered connections

**When to use:** For users who want seamless viewing and have bandwidth to spare. Best on home WiFi with unlimited data.

### Comparison

| Aspect | Cold | Warm |
|--------|------|------|
| Switch time | 2–5 seconds | <1 second |
| Background bandwidth | None | ~50-100 KB/s per alt stream |
| Background CPU | None | Minimal (periodic HEAD + probe) |
| Battery impact | None | Low |
| Reliability | Good | Excellent |
| Best for | Mobile, metered connections | Home WiFi, Android TV, desktop |

---

## Buffering Detection

The stream health monitor tracks multiple signals:

### Signal 1: Buffer Underrun Events
The video player reports when its buffer runs empty. This is the primary signal.

```dart
enum BufferState {
  healthy,    // buffer > 5 seconds
  low,        // buffer 2-5 seconds
  critical,   // buffer < 2 seconds
  empty,      // playback stalled, buffering spinner shown
}
```

### Signal 2: Bitrate Drops
Sudden drops in received bitrate indicate network congestion or server issues:

```dart
// Track rolling average bitrate over 10-second windows
// Trigger if current window drops below 50% of the 1-minute average
bool isBitrateDegraded(double currentBitrate, double rollingAverage) {
  return currentBitrate < rollingAverage * 0.5;
}
```

### Signal 3: Frame Drop Rate
High frame drops indicate the stream can't maintain quality:

```dart
// Trigger if frame drop rate exceeds 10% over 5 seconds
bool isFrameDropHigh(int droppedFrames, int totalFrames) {
  return totalFrames > 0 && (droppedFrames / totalFrames) > 0.10;
}
```

### Signal 4: Connection Errors
TCP/HTTP errors, timeouts, and stream EOF indicate hard failures:

```dart
enum StreamError {
  timeout,        // no data received for N seconds
  connectionReset,
  httpError,      // 4xx/5xx from server
  streamEnded,    // unexpected EOF
  formatError,    // corrupt/unparseable data
}
```

### Failover Trigger Logic

```dart
class FailoverTrigger {
  // Configurable thresholds
  final Duration bufferStallThreshold = Duration(seconds: 3);
  final int maxConsecutiveStalls = 2;
  final Duration bitrateWindowSize = Duration(seconds: 10);
  
  bool shouldFailover(StreamHealthSnapshot health) {
    // Immediate failover on hard errors
    if (health.hasConnectionError) return true;
    
    // Failover after sustained buffering
    if (health.bufferState == BufferState.empty &&
        health.stallDuration >= bufferStallThreshold) return true;
    
    // Failover after repeated stalls (even if brief)
    if (health.consecutiveStalls >= maxConsecutiveStalls) return true;
    
    // Failover on severe bitrate degradation + buffer critical
    if (health.isBitrateDegraded && 
        health.bufferState == BufferState.critical) return true;
    
    return false;
  }
}
```

---

## Channel Cross-Reference Map

For failover to work, clubTivi must know which streams across providers carry the same content.

### Building the Cross-Reference

```
Provider A channels:          Provider B channels:
  ESPN HD (tvg-id: espn.hd)     ESPN (tvg-id: ESPN_US)
  CNN (tvg-id: cnn.us)          CNN Int (tvg-id: cnn-intl)
  FOX News (tvg-id: fox.news)   Fox News HD (tvg-id: FOXNEWS)

                    ▼ Cross-Reference Engine ▼

Unified Channel Map:
  ESPN     → [ProvA/espn.hd, ProvB/ESPN_US]
  CNN      → [ProvA/cnn.us, ProvB/cnn-intl]
  FOX News → [ProvA/fox.news, ProvB/FOXNEWS]
```

### Matching Strategies
1. **EPG mapping match** — channels mapped to the same EPG channel are the same content
2. **Normalized name match** — same fuzzy matching used in EPG auto-mapper
3. **tvg-id cross-reference** — normalize and compare tvg-ids
4. **Manual linking** — user explicitly links channels across providers

### Data Model

```dart
class UnifiedChannel {
  final String id;                    // clubTivi's internal unified ID
  final String displayName;
  final String? epgChannelId;
  final String? logoUrl;
  final List<StreamSource> sources;   // ordered by priority
  final int? channelNumber;
}

class StreamSource {
  final String providerId;
  final String providerChannelId;
  final String streamUrl;
  final int priority;               // 1 = highest, user-configurable
  final StreamHealth lastKnownHealth;
  final DateTime? lastProbeTime;
}

enum StreamHealth {
  unknown,    // never probed
  healthy,    // probe succeeded, good quality
  degraded,   // probe succeeded, quality issues
  down,       // probe failed
}
```

---

## Warm Mode: Background Probes

### Probe Strategy

Probes are lightweight checks — they do NOT fully play the stream:

```dart
class StreamProbe {
  /// Probe a stream URL to check if it's alive and responsive.
  /// 
  /// 1. Send HTTP HEAD/GET request with range header
  /// 2. Wait for response headers (validates server is responding)
  /// 3. Read first ~64KB of data (validates stream is producing data)
  /// 4. Attempt to parse a few TS packets or HLS segment headers
  /// 5. Measure response time and initial bitrate
  /// 6. Close connection
  ///
  /// Total data usage per probe: ~64-128KB
  /// Total time per probe: ~1-3 seconds
  
  Future<ProbeResult> probe(String streamUrl) async {
    final stopwatch = Stopwatch()..start();
    
    final request = await HttpClient().getUrl(Uri.parse(streamUrl));
    request.headers.set('Range', 'bytes=0-65535');
    
    final response = await request.close()
        .timeout(Duration(seconds: 5));
    
    if (response.statusCode >= 400) {
      return ProbeResult.down(responseTime: stopwatch.elapsed);
    }
    
    // Read initial data
    int bytesRead = 0;
    await for (var chunk in response.take(2)) {
      bytesRead += chunk.length;
    }
    
    return ProbeResult.healthy(
      responseTime: stopwatch.elapsed,
      initialBitrate: bytesRead / stopwatch.elapsedMilliseconds * 1000,
    );
  }
}
```

### Probe Scheduling

```dart
class ProbeScheduler {
  // Default: probe each backup stream every 30 seconds
  Duration probeInterval = Duration(seconds: 30);
  
  // Adaptive scheduling:
  // - If a stream was healthy last probe → increase interval (up to 60s)
  // - If a stream was degraded → decrease interval (down to 10s)
  // - If on battery → double all intervals
  // - If on metered connection → disable warm mode entirely
  
  // Max concurrent probes: 3 (avoid saturating the connection)
  final int maxConcurrentProbes = 3;
  
  // Probe priority: only probe alternatives for the CURRENT channel
  // Don't waste bandwidth probing channels the user isn't watching
}
```

### Resource Management

```dart
class WarmModeResourceManager {
  bool shouldEnableWarmMode() {
    // Check platform constraints
    if (Platform.isAndroid) {
      // Check battery level — disable below 20%
      // Check if on WiFi vs cellular
      // Check available memory
    }
    
    // Check user preference
    // Check number of alternative streams (>10 = too many to probe)
    
    return true;
  }
  
  int maxProbedStreams() {
    // Limit number of simultaneously monitored streams
    // Desktop: up to 5
    // Android TV (plugged in): up to 5
    // Android phone on WiFi: up to 3
    // Android phone on cellular: 0 (warm mode disabled)
    return 5;
  }
}
```

---

## Failover Execution

### Cold Failover Sequence

```
1. Stream health monitor detects degradation
2. FailoverTrigger.shouldFailover() returns true
3. FailoverController retrieves StreamSource list for current channel
4. Skip current source, take next by priority
5. Player switches to new stream URL
6. If new stream also fails → try next source
7. If all sources exhausted → show error, offer manual retry
8. Log failover event for analytics
```

### Warm Failover Sequence

```
1. Stream health monitor detects degradation
2. FailoverTrigger.shouldFailover() returns true
3. FailoverController checks pre-probed health of alternatives
4. Pick highest-priority source with health == healthy
5. Player switches to pre-validated stream URL
6. If switch fails (stale probe) → fall back to cold failover sequence
7. Resume background probing with new active stream excluded
8. Log failover event for analytics
```

### User Experience

During failover:
- **Cold**: Brief loading spinner (2-5s), toast notification: "Switched to Provider B"
- **Warm**: Near-instant switch, subtle toast: "Switched to Provider B"
- User can see failover history in **Settings → Failover → History**
- User can manually trigger failover: long-press OK button or press configurable hotkey

---

## Configuration

```dart
class FailoverConfig {
  FailoverMode mode;           // cold, warm, off
  
  // Cold mode settings
  Duration stallThreshold;     // how long to wait before switching (default: 3s)
  int maxRetries;              // max sources to try (default: 5)
  
  // Warm mode settings
  Duration probeInterval;      // how often to probe (default: 30s)
  int maxProbeStreams;          // max simultaneous probes (default: 5)
  bool adaptiveProbing;        // adjust interval based on health (default: true)
  bool disableOnBattery;       // save power (default: true)
  bool disableOnCellular;      // save data (default: true)
  
  // Shared
  bool showNotification;       // show toast on failover (default: true)
  bool logHistory;             // record failover events (default: true)
}
```

---

## Analytics & Logging

clubTivi tracks failover events locally for the user:

```dart
class FailoverEvent {
  final DateTime timestamp;
  final String channelName;
  final String fromProvider;
  final String toProvider;
  final FailoverMode mode;           // cold or warm
  final String reason;               // buffering, error, manual
  final Duration switchTime;         // how long the switch took
  final bool success;
}
```

Displayed in **Settings → Failover → History**:
```
Today
  14:23  ESPN  ProviderA → ProviderB  (buffering, cold, 3.2s)  ✅
  14:45  CNN   ProviderB → ProviderA  (error, warm, 0.4s)      ✅
  15:01  FOX   ProviderA → ProviderB  (buffering, cold, 4.1s)  ✅
  15:01  FOX   ProviderB → ProviderC  (error, cold, 2.8s)      ✅

Yesterday
  ...
```

This helps users identify which providers are most reliable and tune their priority settings.
