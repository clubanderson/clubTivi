import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../datasources/local/database.dart' as db;
import '../models/channel.dart' hide Provider;
import 'stream_health_tracker.dart';
import '../../features/providers/provider_manager.dart';

/// Maintains a real-time index of alternative streams for each channel.
///
/// Channels are grouped for failover using this priority chain:
///   1. **Same vanity name** — user explicitly confirmed channels are interchangeable
///   2. **Same tvgId** across providers — provider-assigned content ID
///   3. **Same EPG + same call sign** — avoids false matches across local affiliates
///      (e.g., ABC WABC New York ≠ ABC WLS Chicago even though both map to "ABC" EPG)
///   4. **Normalized name match** (strip HD/SD/region tags)
///   5. **Fuzzy keyword match** (lowest confidence)
///
/// NOTE: EPG assignment alone is NOT sufficient for grouping. Local channels
/// (ABC, CBS, NBC, FOX) share network EPG but air different local programming.
/// Only channels with matching call signs or user-confirmed vanity names are
/// considered truly interchangeable.
class StreamAlternativesService {
  final db.AppDatabase _db;
  final StreamHealthTracker _health;

  /// Vanity name → list of channels (user-confirmed grouping).
  Map<String, List<Channel>> _vanityIndex = {};

  /// EPG channel ID → list of channels (from all providers).
  Map<String, List<Channel>> _epgIndex = {};

  /// tvgId → list of channels.
  Map<String, List<Channel>> _tvgIdIndex = {};

  /// Normalized name → list of channels.
  Map<String, List<Channel>> _nameIndex = {};

  /// All channels cached for fuzzy fallback.
  List<Channel> _allChannels = [];

  StreamAlternativesService(this._db, this._health);

  /// Rebuild the index. Call on init, after EPG refresh, or provider changes.
  Future<void> rebuild() async {
    _vanityIndex.clear();
    _epgIndex.clear();
    _tvgIdIndex.clear();
    _nameIndex.clear();

    final channels = await _db.getAllChannels();
    final mappings = await _db.getAllMappings();
    _allChannels = channels.map(_dbToChannel).toList();

    // Load vanity names from SharedPreferences
    Map<String, String> vanityNames = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final vanityJson = prefs.getString('channel_vanity_names');
      if (vanityJson != null) {
        final decoded = jsonDecode(vanityJson) as Map<String, dynamic>;
        vanityNames = decoded.map((k, v) => MapEntry(k, v as String));
      }
    } catch (_) {}

    // Build channelId → epgChannelId lookup from mappings
    final channelToEpg = <String, String>{};
    for (final m in mappings) {
      channelToEpg[m.channelId] = m.epgChannelId;
    }

    for (final ch in _allChannels) {
      if (ch.streamUrl.isEmpty) continue;

      // 1. Vanity name index (user-confirmed grouping — highest trust)
      final vanity = vanityNames[ch.id];
      if (vanity != null && vanity.isNotEmpty) {
        final key = vanity.toLowerCase().trim();
        _vanityIndex.putIfAbsent(key, () => []).add(ch);
      }

      // 2. EPG-based index
      final epgId = channelToEpg[ch.id] ?? ch.epgChannelId;
      if (epgId != null && epgId.isNotEmpty) {
        _epgIndex.putIfAbsent(epgId, () => []).add(ch);
      }

      // 3. tvgId-based index
      if (ch.tvgId != null && ch.tvgId!.isNotEmpty) {
        _tvgIdIndex.putIfAbsent(ch.tvgId!, () => []).add(ch);
      }

      // 4. Normalized name index
      final normName = _normalizeName(ch.name);
      if (normName.isNotEmpty) {
        _nameIndex.putIfAbsent(normName, () => []).add(ch);
      }
    }
  }

  /// Get ranked alternative stream URLs for a channel.
  ///
  /// Returns URLs sorted by health score (best first), excluding
  /// [excludeUrl] (the currently-playing stream).
  List<String> getAlternatives({
    required String channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    required String excludeUrl,
  }) {
    final seen = <String>{excludeUrl};
    final results = <String>[];

    void addCandidates(List<Channel>? channels) {
      if (channels == null) return;
      for (final ch in channels) {
        if (ch.id != channelId &&
            ch.streamUrl.isNotEmpty &&
            seen.add(ch.streamUrl)) {
          results.add(ch.streamUrl);
        }
      }
    }

    // Priority 1: Same vanity name (user-confirmed interchangeable)
    if (vanityName != null && vanityName.isNotEmpty) {
      final key = vanityName.toLowerCase().trim();
      addCandidates(_vanityIndex[key]);
    }

    // Priority 2: Same tvgId across providers
    if (tvgId != null && tvgId.isNotEmpty) {
      addCandidates(_tvgIdIndex[tvgId]);
    }

    // Priority 3: Same EPG + same call sign
    // Only match if channels share a call sign (e.g., both WABC)
    // to avoid false matches across local affiliates
    if (epgChannelId != null && epgChannelId.isNotEmpty) {
      final callSign = _extractCallSign(channelName ?? '');
      final epgGroup = _epgIndex[epgChannelId];
      if (epgGroup != null && callSign != null) {
        final sameCallSign = epgGroup.where((ch) {
          final otherCall = _extractCallSign(ch.name);
          return otherCall != null && otherCall == callSign;
        }).toList();
        addCandidates(sameCallSign);
      } else if (callSign == null) {
        // Non-local channel (ESPN, CNN, etc.) — EPG match is safe
        addCandidates(epgGroup);
      }
    }

    // Priority 4: Normalized name match
    if (channelName != null && channelName.isNotEmpty) {
      final normName = _normalizeName(channelName);
      addCandidates(_nameIndex[normName]);
    }

    // Priority 5: Fuzzy keyword match
    if (results.isEmpty && channelName != null) {
      final words = _normalizeName(channelName)
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 2)
          .toList();
      if (words.isNotEmpty) {
        for (final ch in _allChannels) {
          if (ch.id != channelId &&
              ch.streamUrl.isNotEmpty &&
              seen.add(ch.streamUrl)) {
            final lower = ch.name.toLowerCase();
            if (words.every((w) => lower.contains(w))) {
              results.add(ch.streamUrl);
            }
          }
        }
      }
    }

    // Rank by health score (best first)
    if (results.length > 1) {
      final ranked = _health.rankUrls(results);
      return ranked.map((e) => e.key).toList();
    }

    return results;
  }

  /// How many alternative streams exist for a channel.
  int alternativeCount({
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
  }) {
    if (vanityName != null && vanityName.isNotEmpty) {
      final key = vanityName.toLowerCase().trim();
      final count = (_vanityIndex[key]?.length ?? 1) - 1;
      if (count > 0) return count;
    }
    int count = 0;
    if (tvgId != null && _tvgIdIndex.containsKey(tvgId)) {
      count = _tvgIdIndex[tvgId]!.length - 1;
    }
    if (count > 0) return count;
    if (epgChannelId != null && _epgIndex.containsKey(epgChannelId)) {
      count = _epgIndex[epgChannelId]!.length - 1;
    }
    if (count > 0) return count;
    if (channelName != null) {
      final norm = _normalizeName(channelName);
      if (_nameIndex.containsKey(norm)) {
        count = _nameIndex[norm]!.length - 1;
      }
    }
    return count.clamp(0, 999);
  }

  /// Get detailed alternative channels with match reasons for UI display.
  List<AlternativeDetail> getAlternativeDetails({
    required String channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    required String excludeUrl,
  }) {
    final seen = <String>{excludeUrl};
    final results = <AlternativeDetail>[];

    void addTagged(List<Channel>? channels, String reason) {
      if (channels == null) return;
      for (final ch in channels) {
        if (ch.id != channelId &&
            ch.streamUrl.isNotEmpty &&
            seen.add(ch.streamUrl)) {
          results.add(AlternativeDetail(
            channel: ch,
            matchReason: reason,
            healthScore: _health.getScore(ch.streamUrl),
          ));
        }
      }
    }

    // Priority 1: Same vanity name
    if (vanityName != null && vanityName.isNotEmpty) {
      final key = vanityName.toLowerCase().trim();
      addTagged(_vanityIndex[key], 'vanity name');
    }

    // Priority 2: Same tvgId
    if (tvgId != null && tvgId.isNotEmpty) {
      addTagged(_tvgIdIndex[tvgId], 'tvgId');
    }

    // Priority 3: Same EPG + call sign
    if (epgChannelId != null && epgChannelId.isNotEmpty) {
      final callSign = _extractCallSign(channelName ?? '');
      final epgGroup = _epgIndex[epgChannelId];
      if (epgGroup != null && callSign != null) {
        final sameCall = epgGroup.where((ch) {
          final other = _extractCallSign(ch.name);
          return other != null && other == callSign;
        }).toList();
        addTagged(sameCall, 'EPG+call sign');
      } else if (callSign == null) {
        addTagged(epgGroup, 'EPG');
      }
    }

    // Priority 4: Normalized name
    if (channelName != null && channelName.isNotEmpty) {
      final normName = _normalizeName(channelName);
      addTagged(_nameIndex[normName], 'name');
    }

    // Sort by health score descending
    results.sort((a, b) => b.healthScore.compareTo(a.healthScore));
    return results;
  }

  /// Extract a US broadcast call sign from a channel name.
  /// Returns null for cable/satellite channels (ESPN, CNN, etc.).
  /// Examples: "ABC 7 (WABC) NEW YORK" → "WABC", "CBS 2 WCBS" → "WCBS"
  static String? _extractCallSign(String name) {
    // Match parenthesized call signs: (WABC), (WCBS), etc.
    final parenMatch = RegExp(r'\(([WKOC][A-Z]{2,4})\)', caseSensitive: false)
        .firstMatch(name);
    if (parenMatch != null) return parenMatch.group(1)!.toUpperCase();

    // Match standalone call signs: WABC, WCBS, KABC, etc.
    // US broadcast call signs start with W (east) or K (west), 3-4 letters
    final standaloneMatch = RegExp(r'\b([WK][A-Z]{2,4})\b').firstMatch(name.toUpperCase());
    if (standaloneMatch != null) return standaloneMatch.group(1)!;

    return null;
  }

  static String _normalizeName(String name) {
    return name
        .toLowerCase()
        .replaceAll(
            RegExp(r'\b(hd|fhd|shd|sd|4k|uhd|hevc|h\.?265)\b',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'\b(us|uk|ca|mx|au|nz)-?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Channel _dbToChannel(db.Channel c) => Channel(
        id: c.id,
        providerId: c.providerId,
        name: c.name,
        tvgId: c.tvgId,
        tvgName: c.tvgName,
        tvgLogo: c.tvgLogo,
        groupTitle: c.groupTitle,
        streamUrl: c.streamUrl,
        streamType: c.streamType == 'vod'
            ? StreamType.vod
            : c.streamType == 'series'
                ? StreamType.series
                : StreamType.live,
      );
}

// ---------------------------------------------------------------------------
// Riverpod providers
// ---------------------------------------------------------------------------

final streamHealthTrackerProvider = Provider<StreamHealthTracker>((ref) {
  final tracker = StreamHealthTracker();
  tracker.load();
  return tracker;
});

final streamAlternativesProvider = Provider<StreamAlternativesService>((ref) {
  final db = ref.read(databaseProvider);
  final health = ref.read(streamHealthTrackerProvider);
  final service = StreamAlternativesService(db, health);
  service.rebuild(); // initial build
  return service;
});

/// A single failover alternative with match metadata for UI display.
class AlternativeDetail {
  final Channel channel;
  final String matchReason;
  final double healthScore;

  const AlternativeDetail({
    required this.channel,
    required this.matchReason,
    required this.healthScore,
  });
}
