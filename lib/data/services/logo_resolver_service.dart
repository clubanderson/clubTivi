import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves missing channel logos using tv-logo/tv-logos GitHub repository
/// and EPG channel icons as fallback sources.
class LogoResolverService {
  static const _baseUrl =
      'https://raw.githubusercontent.com/tv-logo/tv-logos/main/countries';
  static const _apiBase =
      'https://api.github.com/repos/tv-logo/tv-logos/contents/countries';
  static const _cacheKey = 'logo_resolver_index';
  static const _cacheTimestampKey = 'logo_resolver_timestamp';
  static const _cacheDuration = Duration(hours: 24);

  // Directories to scan for logos
  static const _directories = ['united-states', 'international', 'canada', 'united-kingdom'];

  /// Cached map: normalized-name → raw GitHub URL
  static Map<String, String>? _index;

  /// Build or load the logo index.
  static Future<Map<String, String>> _getIndex() async {
    if (_index != null) return _index!;

    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    final ts = prefs.getInt(_cacheTimestampKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - ts;

    if (cached != null && age < _cacheDuration.inMilliseconds) {
      _index = Map<String, String>.from(jsonDecode(cached));
      return _index!;
    }

    // Fetch fresh index from GitHub API
    _index = await _fetchIndex();

    // Cache it
    try {
      await prefs.setString(_cacheKey, jsonEncode(_index));
      await prefs.setInt(
          _cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}

    return _index!;
  }

  static Future<Map<String, String>> _fetchIndex() async {
    final dio = Dio();
    final index = <String, String>{};

    for (final dir in _directories) {
      try {
        final resp = await dio.get<List<dynamic>>(
          '$_apiBase/$dir',
          options: Options(
            headers: {'Accept': 'application/vnd.github.v3+json'},
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        if (resp.data == null) continue;

        for (final item in resp.data!) {
          final name = item['name'] as String?;
          if (name == null || !name.endsWith('.png')) continue;
          // Skip mosaic/readme files
          if (name.startsWith('0_')) continue;

          final key = _normalizeFilename(name);
          final url = '$_baseUrl/$dir/$name';
          // Don't overwrite — first match wins (US priority)
          index.putIfAbsent(key, () => url);
        }
      } catch (e) {
        // Silently skip on network error
        continue;
      }
    }

    return index;
  }

  /// Normalize a filename like "abc-us.png" → "abc"
  static String _normalizeFilename(String filename) {
    var name = filename.replaceAll('.png', '');
    // Remove country suffixes
    for (final suffix in ['-us', '-uk', '-ca', '-int']) {
      if (name.endsWith(suffix)) {
        name = name.substring(0, name.length - suffix.length);
        break;
      }
    }
    return name.toLowerCase().trim();
  }

  /// Normalize a channel name for matching.
  static String _normalizeChannelName(String name) {
    var n = name.toLowerCase().trim();

    // Strip IPTV prefixes:
    // "US-P| CBS" → "CBS", "UK| BBC" → "BBC", "CA: CBC" → "CBC"
    n = n.replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '');
    n = n.replaceAll(RegExp(r'^[a-z]{2}:\s+'), '');
    // "CA HGTV" → "HGTV", "US ESPN" → "ESPN" (2-letter country code + space)
    n = n.replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
    // "[US] HGTV" → "HGTV", "CA-P| HGTV" already handled above
    n = n.replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '');
    if (n.isEmpty) n = name.toLowerCase().trim();

    // Remove quality tags
    n = n.replaceAll(RegExp(r'\s*(hd|fhd|uhd|4k|sd|hevc|h\.?265)\s*$', caseSensitive: false), '');
    // Remove parenthesized suffixes like "(East)", "(West)"
    n = n.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '');
    // Replace spaces/special chars with hyphens
    n = n.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    // Clean up multiple hyphens
    n = n.replaceAll(RegExp(r'-+'), '-');
    n = n.replaceAll(RegExp(r'^-|-$'), '');

    return n;
  }

  /// Resolve a logo URL for a channel name.
  /// Returns a URL string or null if no match found.
  static Future<String?> resolveLogoUrl(String channelName) async {
    final index = await _getIndex();
    if (index.isEmpty) return null;

    final normalized = _normalizeChannelName(channelName);
    if (normalized.isEmpty) return null;

    // Strategy 1: Exact match
    if (index.containsKey(normalized)) return index[normalized];

    // Strategy 2: Try common aliases
    final aliases = _getAliases(normalized);
    for (final alias in aliases) {
      if (index.containsKey(alias)) return index[alias];
    }

    // Strategy 3: Find keys that start with our normalized name
    final prefixMatches = index.keys
        .where((k) => k.startsWith(normalized))
        .toList();
    if (prefixMatches.isNotEmpty) {
      // Prefer: exact+"-logo" variants > shortest non-variant match
      final logoVariant = prefixMatches
          .where((k) => k.startsWith('$normalized-logo'))
          .toList()
        ..sort((a, b) => a.length.compareTo(b.length));
      if (logoVariant.isNotEmpty) return index[logoVariant.first];
      // Otherwise prefer the plain network logo (skip sport/news variants)
      final plain = prefixMatches
          .where((k) => !k.contains('-news') && !k.contains('-sport') &&
                        !k.contains('-nfl') && !k.contains('-nba'))
          .toList()
        ..sort((a, b) => a.length.compareTo(b.length));
      if (plain.isNotEmpty) return index[plain.first];
      prefixMatches.sort((a, b) => a.length.compareTo(b.length));
      return index[prefixMatches.first];
    }

    // Strategy 4: Check if any key contains our name or vice versa
    final containsMatches = index.keys
        .where((k) => k.contains(normalized) || normalized.contains(k))
        .where((k) => k.length > 2)
        .toList()
      ..sort((a, b) {
        final diffA = (a.length - normalized.length).abs();
        final diffB = (b.length - normalized.length).abs();
        return diffA.compareTo(diffB);
      });
    if (containsMatches.isNotEmpty) return index[containsMatches.first];

    return null;
  }

  /// Generate common aliases for channel name matching.
  static List<String> _getAliases(String normalized) {
    final aliases = <String>[];

    // "food-network" → "food"
    if (normalized.contains('-network')) {
      aliases.add(normalized.replaceAll('-network', ''));
    }
    if (normalized.contains('-channel')) {
      aliases.add(normalized.replaceAll('-channel', ''));
    }
    // "the-weather-channel" → "weather-channel"
    if (normalized.startsWith('the-')) {
      aliases.add(normalized.substring(4));
    }
    // "usa-food-network" → "food-network" (strip country prefix)
    if (normalized.startsWith('usa-')) {
      aliases.add(normalized.substring(4));
    }
    if (normalized.startsWith('us-')) {
      aliases.add(normalized.substring(3));
    }
    if (normalized.startsWith('ca-')) {
      aliases.add(normalized.substring(3));
    }
    if (normalized.startsWith('uk-')) {
      aliases.add(normalized.substring(3));
    }
    // Try adding common suffixes
    aliases.add('$normalized-network');
    aliases.add('$normalized-channel');
    // "hbo" → "hbo" (already exact), but also "hbo-hz"
    aliases.add('$normalized-hz');
    // "cbs" → "cbs-logo-white" (common variant)
    aliases.add('$normalized-logo-white');
    aliases.add('$normalized-logo-2013-default');

    return aliases;
  }

  /// Resolve logos for a batch of channels.
  /// Returns a map of channelId → logoUrl for channels that got resolved.
  static Future<Map<String, String>> resolveLogosForChannels(
    List<({String id, String name, String? tvgLogo})> channels,
  ) async {
    final results = <String, String>{};
    final needsResolution = channels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .toList();

    if (needsResolution.isEmpty) return results;

    // Pre-load the index
    await _getIndex();

    for (final channel in needsResolution) {
      final url = await resolveLogoUrl(channel.name);
      if (url != null) {
        results[channel.id] = url;
      }
    }

    return results;
  }

  /// Clear the cached index (useful for manual refresh).
  static Future<void> clearCache() async {
    _index = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimestampKey);
  }
}
