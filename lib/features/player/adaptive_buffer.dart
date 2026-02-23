import 'dart:async';
import 'dart:convert';

import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:shared_preferences/shared_preferences.dart';

import 'player_service.dart';

/// Adaptive per-stream buffer manager.
///
/// Monitors `demuxer-cache-duration` to gauge stream health and adjusts
/// mpv buffer properties bidirectionally across three tiers:
///   - **fast**:       Small buffer, fast channel switching (good streams)
///   - **normal**:     Default balanced buffer
///   - **aggressive**: Large buffer for flaky streams
///
/// Tier is persisted per stream URL so returning to a channel uses the
/// learned profile immediately. Tiers float both ways based on a rolling
/// window of buffer health observations.
class AdaptiveBufferManager {
  static const _prefsKey = 'adaptive_buffer_profiles';

  // Buffer tier definitions (mpv properties)
  // All tiers share high maximums, but differ in pause behavior:
  //   fast:       Never pause for buffer — instant channel switching
  //   normal:     Brief pause if buffer critically empty
  //   aggressive: Pause up to 3s to build buffer, more readahead
  static const _tierConfig = <String, Map<String, String>>{
    'fast': {
      'cache': 'yes',
      'cache-secs': '180',
      'cache-pause-initial': 'no',
      'cache-pause-wait': '1',
      'demuxer-max-bytes': '800M',
      'demuxer-max-back-bytes': '200M',
      'demuxer-readahead-secs': '60',
    },
    'normal': {
      'cache': 'yes',
      'cache-secs': '180',
      'cache-pause-initial': 'no',
      'cache-pause-wait': '2',
      'demuxer-max-bytes': '800M',
      'demuxer-max-back-bytes': '200M',
      'demuxer-readahead-secs': '120',
    },
    'aggressive': {
      'cache': 'yes',
      'cache-secs': '180',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': '3',
      'demuxer-max-bytes': '800M',
      'demuxer-max-back-bytes': '200M',
      'demuxer-readahead-secs': '180',
    },
  };

  static const _tierOrder = ['fast', 'normal', 'aggressive'];

  /// Seconds of stable buffer before downgrading tier.
  static const _downgradeAfterStableSecs = 60;

  /// Number of low-buffer observations before upgrading tier.
  static const _upgradeAfterStallCount = 3;

  /// Cache duration below which we consider the buffer stressed.
  static const _lowBufferThreshold = 1.5;

  /// Cache duration above which we consider the buffer healthy.
  static const _healthyBufferThreshold = 4.0;

  Timer? _monitorTimer;
  String _currentTier = 'normal';
  String? _currentUrl;

  // Health tracking — reset per stream
  int _stableSeconds = 0;
  int _stallCount = 0;

  /// Current tier for display/debugging.
  String get currentTier => _currentTier;

  /// Apply buffer settings for a stream URL and begin monitoring.
  Future<void> applyForStream(String url, PlayerService ps) async {
    _monitorTimer?.cancel();
    _currentUrl = url;
    _stableSeconds = 0;
    _stallCount = 0;

    // Load saved tier or default to 'normal'
    _currentTier = await _loadTier(url);
    await _applyTier(_currentTier, ps);
    _startMonitoring(url, ps);
  }

  /// Stop monitoring (call on stream stop or dispose).
  void stop() {
    _monitorTimer?.cancel();
    _currentUrl = null;
  }

  // ---------------------------------------------------------------------------
  // Monitoring loop
  // ---------------------------------------------------------------------------

  void _startMonitoring(String url, PlayerService ps) {
    _monitorTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_currentUrl != url) return; // stream changed

      final raw = await ps.getMpvProperty('demuxer-cache-duration');
      final cacheSecs = double.tryParse(raw ?? '');
      if (cacheSecs == null) return; // not available yet

      if (cacheSecs < _lowBufferThreshold) {
        // Buffer stressed
        _stallCount++;
        _stableSeconds = 0;

        if (_stallCount >= _upgradeAfterStallCount) {
          final upgraded = _upgradeTier();
          if (upgraded) {
            await _applyTier(_currentTier, ps);
            await _saveTier(url, _currentTier);
            _stallCount = 0;
          }
        }
      } else if (cacheSecs > _healthyBufferThreshold) {
        // Buffer healthy
        _stableSeconds += 2;
        _stallCount = (_stallCount > 0) ? _stallCount - 1 : 0;

        if (_stableSeconds >= _downgradeAfterStableSecs) {
          final downgraded = _downgradeTier();
          if (downgraded) {
            await _applyTier(_currentTier, ps);
            await _saveTier(url, _currentTier);
          }
          _stableSeconds = 0;
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Tier management
  // ---------------------------------------------------------------------------

  /// Move to a higher buffer tier. Returns true if tier changed.
  bool _upgradeTier() {
    final idx = _tierOrder.indexOf(_currentTier);
    if (idx < _tierOrder.length - 1) {
      _currentTier = _tierOrder[idx + 1];
      return true;
    }
    return false;
  }

  /// Move to a lower buffer tier. Returns true if tier changed.
  bool _downgradeTier() {
    final idx = _tierOrder.indexOf(_currentTier);
    if (idx > 0) {
      _currentTier = _tierOrder[idx - 1];
      return true;
    }
    return false;
  }

  Future<void> _applyTier(String tier, PlayerService ps) async {
    final config = _tierConfig[tier] ?? _tierConfig['normal']!;
    for (final entry in config.entries) {
      await _setMpvProperty(ps, entry.key, entry.value);
    }
  }

  Future<void> _setMpvProperty(PlayerService ps, String key, String value) async {
    try {
      final np = ps.player.platform;
      if (np is native_player.NativePlayer) {
        await np.setProperty(key, value);
      }
    } catch (_) {
      // Property might not be settable mid-stream — that's OK
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence (SharedPreferences)
  // ---------------------------------------------------------------------------

  /// Use a short hash of the URL as key to keep storage compact.
  String _urlKey(String url) => url.hashCode.toRadixString(36);

  Future<String> _loadTier(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      if (json != null) {
        final map = jsonDecode(json) as Map<String, dynamic>;
        final tier = map[_urlKey(url)] as String?;
        if (tier != null && _tierConfig.containsKey(tier)) return tier;
      }
    } catch (_) {}
    return 'normal';
  }

  Future<void> _saveTier(String url, String tier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      final map = json != null
          ? (jsonDecode(json) as Map<String, dynamic>)
          : <String, dynamic>{};
      map[_urlKey(url)] = tier;
      // Keep only last 200 entries to avoid unbounded growth
      if (map.length > 200) {
        final keys = map.keys.toList();
        for (var i = 0; i < keys.length - 200; i++) {
          map.remove(keys[i]);
        }
      }
      await prefs.setString(_prefsKey, jsonEncode(map));
    } catch (_) {}
  }
}
