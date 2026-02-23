import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Tracks per-stream health metrics for ranking failover alternatives.
///
/// Metrics: stall count, average buffer level, time-to-first-frame.
/// Persisted to SharedPreferences, decayed over time so recent data
/// weighs more than old data.
class StreamHealthTracker {
  static const _prefsKey = 'stream_health_scores';
  static const _maxEntries = 300;
  static const _decayDays = 7;

  Map<String, _StreamMetrics> _metrics = {};
  bool _loaded = false;

  /// Load persisted metrics from disk.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      if (json != null) {
        final map = jsonDecode(json) as Map<String, dynamic>;
        _metrics = map.map((k, v) => MapEntry(k, _StreamMetrics.fromJson(v)));
      }
    } catch (_) {}
    _loaded = true;
  }

  /// Record a buffering stall on a stream.
  void recordStall(String url) {
    final m = _getOrCreate(url);
    m.stallCount++;
    m.lastUpdated = DateTime.now();
    _scheduleSave();
  }

  /// Record a buffer level sample (seconds of cache).
  void recordBufferSample(String url, double seconds) {
    final m = _getOrCreate(url);
    m.bufferSamples++;
    m.bufferSum += seconds;
    m.lastUpdated = DateTime.now();
    // Don't save on every sample — too frequent
  }

  /// Record time-to-first-frame in milliseconds.
  void recordTTFF(String url, int ms) {
    final m = _getOrCreate(url);
    m.ttffMs = ms;
    m.lastUpdated = DateTime.now();
    _scheduleSave();
  }

  /// Get a health score for a stream URL (0.0 = terrible, 1.0 = excellent).
  /// Unknown streams return 0.5 (neutral).
  double getScore(String url) {
    final key = _urlKey(url);
    final m = _metrics[key];
    if (m == null) return 0.5;

    // Apply time decay — halve weight after _decayDays
    final age = DateTime.now().difference(m.lastUpdated).inHours;
    final decay = 1.0 / (1.0 + age / (_decayDays * 24));

    // Score components (0-1 each)
    final stallScore = 1.0 / (1.0 + m.stallCount * 0.3);
    final bufferScore = m.bufferSamples > 0
        ? ((m.bufferSum / m.bufferSamples) / 10.0).clamp(0.0, 1.0)
        : 0.5;
    final ttffScore = m.ttffMs > 0
        ? (1.0 - (m.ttffMs / 10000.0)).clamp(0.0, 1.0)
        : 0.5;

    // Weighted average with decay
    return ((stallScore * 0.5 + bufferScore * 0.3 + ttffScore * 0.2) * decay)
        .clamp(0.0, 1.0);
  }

  /// Get scores for multiple URLs, sorted best-first.
  List<MapEntry<String, double>> rankUrls(List<String> urls) {
    final scored = urls.map((u) => MapEntry(u, getScore(u))).toList();
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored;
  }

  _StreamMetrics _getOrCreate(String url) {
    final key = _urlKey(url);
    return _metrics.putIfAbsent(key, () => _StreamMetrics(url: url));
  }

  String _urlKey(String url) => url.hashCode.toRadixString(36);

  bool _saveScheduled = false;

  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    Future.delayed(const Duration(seconds: 5), () async {
      _saveScheduled = false;
      await _save();
    });
  }

  /// Force a save (call on app shutdown).
  Future<void> save() => _save();

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Prune old entries
      if (_metrics.length > _maxEntries) {
        final entries = _metrics.entries.toList()
          ..sort((a, b) => a.value.lastUpdated.compareTo(b.value.lastUpdated));
        for (var i = 0; i < entries.length - _maxEntries; i++) {
          _metrics.remove(entries[i].key);
        }
      }
      final json = _metrics.map((k, v) => MapEntry(k, v.toJson()));
      await prefs.setString(_prefsKey, jsonEncode(json));
    } catch (_) {}
  }
}

class _StreamMetrics {
  final String url;
  int stallCount;
  double bufferSum;
  int bufferSamples;
  int ttffMs;
  DateTime lastUpdated;

  _StreamMetrics({
    required this.url,
    this.stallCount = 0,
    this.bufferSum = 0,
    this.bufferSamples = 0,
    this.ttffMs = 0,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'url': url,
        'stalls': stallCount,
        'bufSum': bufferSum,
        'bufN': bufferSamples,
        'ttff': ttffMs,
        'ts': lastUpdated.millisecondsSinceEpoch,
      };

  factory _StreamMetrics.fromJson(Map<String, dynamic> j) => _StreamMetrics(
        url: j['url'] ?? '',
        stallCount: j['stalls'] ?? 0,
        bufferSum: (j['bufSum'] ?? 0).toDouble(),
        bufferSamples: j['bufN'] ?? 0,
        ttffMs: j['ttff'] ?? 0,
        lastUpdated: DateTime.fromMillisecondsSinceEpoch(j['ts'] ?? 0),
      );
}
