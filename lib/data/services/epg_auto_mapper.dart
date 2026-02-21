import 'package:string_similarity/string_similarity.dart';

import '../models/channel.dart';
import '../models/epg.dart';

/// Automatically maps provider channels to EPG channels using multiple
/// fuzzy matching strategies. Designed for epg.best and other XMLTV sources.
class EpgAutoMapper {
  /// Minimum confidence to auto-apply a mapping.
  static const double autoApplyThreshold = 0.70;

  /// Minimum confidence to suggest a mapping for user review.
  static const double suggestThreshold = 0.40;

  /// Run auto-mapping for a list of channels against available EPG channels.
  MappingStats mapAll({
    required List<Channel> channels,
    required List<EpgChannel> epgChannels,
    required Map<String, EpgMapping> existingMappings,
    required String epgSourceId,
    required Function(EpgMapping) onMapping,
  }) {
    final stopwatch = Stopwatch()..start();
    int mapped = 0, suggested = 0, unmapped = 0;

    // Build lookup indices for EPG channels
    final index = _EpgIndex.build(epgChannels);

    for (final channel in channels) {
      final key = '${channel.id}:${channel.providerId}';
      final existing = existingMappings[key];

      // Skip locked (manual) mappings
      if (existing != null && existing.locked) {
        mapped++;
        continue;
      }

      final candidates = findCandidates(
        channel: channel,
        epgChannels: epgChannels,
        index: index,
        epgSourceId: epgSourceId,
      );

      if (candidates.isEmpty) {
        unmapped++;
        continue;
      }

      final best = candidates.first;

      final source = best.confidence >= autoApplyThreshold
          ? MappingSource.auto
          : MappingSource.suggested;

      if (source == MappingSource.auto) {
        mapped++;
      } else {
        suggested++;
      }

      onMapping(EpgMapping(
        playlistChannelId: channel.id,
        providerId: channel.providerId,
        epgChannelId: best.epgChannelId,
        epgSourceId: best.epgSourceId,
        confidence: best.confidence,
        source: source,
        locked: false,
        updatedAt: DateTime.now(),
      ));
    }

    stopwatch.stop();
    return MappingStats(
      totalChannels: channels.length,
      mapped: mapped,
      suggested: suggested,
      unmapped: unmapped,
      elapsed: stopwatch.elapsed,
    );
  }

  /// Find EPG channel candidates for a single provider channel.
  /// Returns candidates sorted by confidence (highest first).
  List<MappingCandidate> findCandidates({
    required Channel channel,
    required List<EpgChannel> epgChannels,
    Object? index,
    required String epgSourceId,
  }) {
    final idx = index is _EpgIndex ? index : _EpgIndex.build(epgChannels);
    final results = <String, _CandidateScore>{};

    // Strategy 1: Exact tvg-id match
    if (channel.tvgId != null && channel.tvgId!.isNotEmpty) {
      final exact = idx.byId[channel.tvgId!];
      if (exact != null) {
        _addScore(results, exact, 1.0, 'exact_tvg_id');
      }
    }

    // Strategy 2: Normalized ID match
    if (channel.tvgId != null && channel.tvgId!.isNotEmpty) {
      final normalized = _normalizeId(channel.tvgId!);
      final match = idx.byNormalizedId[normalized];
      if (match != null && !results.containsKey(match.id)) {
        _addScore(results, match, 0.95, 'normalized_id');
      }
    }

    // Strategy 3: Fuzzy name matching
    final channelName = _cleanChannelName(channel.displayName);
    if (channelName.isNotEmpty) {
      final nameResults = _fuzzyNameMatch(channelName, epgChannels);
      for (final (epgCh, score) in nameResults) {
        _addScore(results, epgCh, score, 'fuzzy_name');
      }
    }

    // Strategy 4: Channel number match
    if (channel.channelNumber != null) {
      final numStr = channel.channelNumber.toString();
      final match = idx.byNumber[numStr];
      if (match != null) {
        _addScore(results, match, 0.50, 'channel_number');
      }
    }

    // Strategy 5: Logo URL match
    if (channel.tvgLogo != null && channel.tvgLogo!.isNotEmpty) {
      final match = idx.byIconUrl[channel.tvgLogo!];
      if (match != null) {
        _addScore(results, match, 0.40, 'logo_url');
      }
    }

    // Compute final confidence with corroboration boost
    final candidates = results.entries.map((entry) {
      final score = entry.value;
      final baseConfidence = score.maxScore;
      final corroboration = score.scores
          .where((s) => s > 0.3)
          .fold(0.0, (sum, s) => sum + s * 0.1);
      final finalConfidence = (baseConfidence + corroboration).clamp(0.0, 1.0);

      return MappingCandidate(
        epgChannelId: entry.key,
        epgSourceId: epgSourceId,
        epgDisplayName: score.epgChannel.primaryName,
        confidence: finalConfidence,
        matchReasons: score.reasons,
      );
    }).toList();

    // Sort by confidence descending
    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));

    // Return top 10 candidates
    return candidates.take(10).toList();
  }

  void _addScore(
    Map<String, _CandidateScore> results,
    EpgChannel epgChannel,
    double score,
    String reason,
  ) {
    final existing = results[epgChannel.id];
    if (existing != null) {
      existing.scores.add(score);
      existing.reasons.add(reason);
    } else {
      results[epgChannel.id] = _CandidateScore(
        epgChannel: epgChannel,
        scores: [score],
        reasons: [reason],
      );
    }
  }

  /// Clean channel name for matching.
  /// Strips provider prefixes like "US: ", "UK: ", "USA |", etc.
  String _cleanChannelName(String name) {
    // Remove common prefixes: "US: ", "UK |", "USA - ", country codes
    var cleaned = name.replaceAll(
      RegExp(r'^[A-Z]{2,3}\s*[:|/\-]\s*', caseSensitive: false),
      '',
    );
    // Remove quality suffixes
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*(HD|FHD|UHD|4K|SD|HEVC|H\.?265|H\.?264)\s*',
          caseSensitive: false),
      ' ',
    );
    // Remove parenthesized content like "(USA)", "(FHD)"
    cleaned = cleaned.replaceAll(RegExp(r'\([^)]*\)'), '');
    // Collapse whitespace
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned;
  }

  /// Normalize an ID for comparison.
  /// "ESPN_US_HD" → "espnus", "ESPN.us" → "espnus"
  String _normalizeId(String id) {
    var normalized = id.toLowerCase();
    // Remove separators
    normalized = normalized.replaceAll(RegExp(r'[._\-\s]'), '');
    // Remove quality suffixes
    normalized = normalized.replaceAll(
      RegExp(r'(hd|fhd|uhd|4k|sd|hevc|h265|h264)'),
      '',
    );
    return normalized;
  }

  /// Fuzzy match a channel name against EPG channels.
  /// Returns (EpgChannel, score) pairs for matches above threshold.
  List<(EpgChannel, double)> _fuzzyNameMatch(
    String channelName,
    List<EpgChannel> epgChannels,
  ) {
    final results = <(EpgChannel, double)>[];
    final normalizedInput = channelName.toLowerCase();

    for (final epgCh in epgChannels) {
      double bestScore = 0;

      for (final epgName in epgCh.displayNames) {
        final normalizedEpg = epgName.toLowerCase();

        // Exact (case-insensitive)
        if (normalizedInput == normalizedEpg) {
          bestScore = 0.90;
          break;
        }

        // Jaro-Winkler similarity
        final jw = normalizedInput.similarityTo(normalizedEpg);
        if (jw > bestScore) bestScore = jw;

        // Token overlap (word set comparison)
        final inputTokens = normalizedInput.split(RegExp(r'\s+')).toSet();
        final epgTokens = normalizedEpg.split(RegExp(r'\s+')).toSet();
        if (inputTokens.isNotEmpty && epgTokens.isNotEmpty) {
          final intersection = inputTokens.intersection(epgTokens).length;
          final union = inputTokens.union(epgTokens).length;
          final jaccard = intersection / union;
          // Weight Jaccard higher for multi-word names
          final tokenScore = jaccard * 0.85;
          if (tokenScore > bestScore) bestScore = tokenScore;
        }
      }

      // Scale score to the fuzzy range (0.6–0.9)
      final scaledScore = 0.6 + (bestScore * 0.3);

      if (scaledScore >= suggestThreshold) {
        results.add((epgCh, scaledScore.clamp(0.0, 0.90)));
      }
    }

    results.sort((a, b) => b.$2.compareTo(a.$2));
    return results.take(20).toList();
  }
}

/// Internal score accumulator for a candidate.
class _CandidateScore {
  final EpgChannel epgChannel;
  final List<double> scores;
  final List<String> reasons;

  _CandidateScore({
    required this.epgChannel,
    required this.scores,
    required this.reasons,
  });

  double get maxScore => scores.reduce((a, b) => a > b ? a : b);
}

/// Pre-built lookup indices for efficient EPG channel matching.
class _EpgIndex {
  final Map<String, EpgChannel> byId;
  final Map<String, EpgChannel> byNormalizedId;
  final Map<String, EpgChannel> byNumber;
  final Map<String, EpgChannel> byIconUrl;

  _EpgIndex._({
    required this.byId,
    required this.byNormalizedId,
    required this.byNumber,
    required this.byIconUrl,
  });

  factory _EpgIndex.build(List<EpgChannel> channels) {
    final byId = <String, EpgChannel>{};
    final byNormalizedId = <String, EpgChannel>{};
    final byNumber = <String, EpgChannel>{};
    final byIconUrl = <String, EpgChannel>{};

    for (final ch in channels) {
      byId[ch.id] = ch;

      // Normalized ID
      var normalized = ch.id.toLowerCase().replaceAll(RegExp(r'[._\-\s]'), '');
      normalized = normalized.replaceAll(
        RegExp(r'(hd|fhd|uhd|4k|sd|hevc|h265|h264)'),
        '',
      );
      byNormalizedId[normalized] = ch;

      if (ch.number != null) byNumber[ch.number!] = ch;
      if (ch.iconUrl != null) byIconUrl[ch.iconUrl!] = ch;
    }

    return _EpgIndex._(
      byId: byId,
      byNormalizedId: byNormalizedId,
      byNumber: byNumber,
      byIconUrl: byIconUrl,
    );
  }
}
