import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/channel.dart' hide Provider;

/// Cold failover engine.
///
/// When buffering is detected on the current stream, switches to the next
/// alternative stream that carries the same content (matched via EPG mapping).
/// "Cold" = switch happens on-demand with a brief gap (2-5s).
///
/// Flow:
/// 1. Player reports buffering stall > threshold
/// 2. FailoverEngine picks the next alternative stream
/// 3. Player switches to new URL
/// 4. If new stream also fails, tries the next one (round-robin)
class ColdFailoverEngine {
  /// Buffer stall duration before triggering failover.
  final Duration stallThreshold;

  /// Max consecutive failover attempts before giving up.
  final int maxAttempts;

  ColdFailoverEngine({
    this.stallThreshold = const Duration(seconds: 3),
    this.maxAttempts = 5,
  });

  int _currentIndex = 0;
  int _attemptCount = 0;
  DateTime? _stallStart;
  bool _isStalling = false;

  /// The list of alternative stream URLs for the current content.
  List<String> _alternatives = [];

  /// Set up failover alternatives for a channel.
  /// [primaryUrl] is the current stream, [alternatives] are same-content
  /// streams from other providers (matched via EPG ID).
  void configure({
    required String primaryUrl,
    required List<String> alternatives,
  }) {
    _alternatives = [primaryUrl, ...alternatives];
    _currentIndex = 0;
    _attemptCount = 0;
    _stallStart = null;
    _isStalling = false;
  }

  /// Call this on every buffering state change from the player.
  /// Returns a new URL to switch to, or null if no switch needed.
  String? onBufferingChanged(bool isBuffering) {
    if (isBuffering && !_isStalling) {
      _isStalling = true;
      _stallStart = DateTime.now();
      return null;
    }

    if (!isBuffering) {
      _isStalling = false;
      _stallStart = null;
      _attemptCount = 0;
      return null;
    }

    // Still buffering — check if threshold exceeded
    if (_isStalling &&
        _stallStart != null &&
        DateTime.now().difference(_stallStart!) >= stallThreshold) {
      return _getNextUrl();
    }

    return null;
  }

  /// Force a manual failover to the next stream.
  String? switchToNext() => _getNextUrl();

  String? _getNextUrl() {
    if (_alternatives.length <= 1) return null;
    if (_attemptCount >= maxAttempts) return null;

    _attemptCount++;
    _currentIndex = (_currentIndex + 1) % _alternatives.length;
    _stallStart = null;
    _isStalling = false;

    return _alternatives[_currentIndex];
  }

  /// Current stream URL.
  String? get currentUrl =>
      _alternatives.isNotEmpty ? _alternatives[_currentIndex] : null;

  /// Whether failover has alternatives available.
  bool get hasAlternatives => _alternatives.length > 1;

  /// Number of failover attempts made.
  int get attemptCount => _attemptCount;

  /// Whether max attempts have been exhausted.
  bool get isExhausted => _attemptCount >= maxAttempts;

  void reset() {
    _currentIndex = 0;
    _attemptCount = 0;
    _stallStart = null;
    _isStalling = false;
  }
}

/// Cross-provider channel matcher.
///
/// Finds alternative streams across providers that carry the same content.
/// Channels are matched when they share the same EPG channel ID
/// (e.g., both map to "ESPN.us").
class CrossProviderMatcher {
  /// Given a channel's EPG ID, find all streams across providers that
  /// map to the same EPG channel.
  List<String> findAlternativeStreams({
    required String currentChannelId,
    required String epgChannelId,
    required List<Channel> allChannels,
    required Map<String, String> channelToEpgMap, // channelId → epgChannelId
  }) {
    if (epgChannelId.isEmpty) return [];

    return allChannels
        .where((c) =>
            c.id != currentChannelId &&
            channelToEpgMap[c.id] == epgChannelId &&
            c.streamUrl.isNotEmpty)
        .map((c) => c.streamUrl)
        .toList();
  }
}

/// Riverpod providers.
final coldFailoverProvider = Provider<ColdFailoverEngine>((ref) {
  return ColdFailoverEngine();
});

final crossProviderMatcherProvider = Provider<CrossProviderMatcher>((ref) {
  return CrossProviderMatcher();
});
