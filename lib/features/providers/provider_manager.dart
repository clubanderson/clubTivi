import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/parsers/m3u_parser.dart';
import '../../data/datasources/remote/xtream_client.dart';
import '../../data/models/channel.dart' hide Provider;
import '../../data/services/logo_resolver_service.dart';
import '../../core/feature_gate.dart';
import 'package:dio/dio.dart';

/// Manages IPTV providers: adding, refreshing, channel loading.
class ProviderManager {
  final db.AppDatabase _db;
  final M3uParser _m3uParser = M3uParser();

  ProviderManager(this._db);

  /// Check provider count against tier limit.
  Future<void> _checkProviderLimit() async {
    final existing = await _db.getAllProviders();
    if (existing.length >= FeatureGate.maxProviders) {
      throw ProviderLimitException(FeatureGate.maxProviders);
    }
  }

  /// Add an M3U provider.
  Future<void> addM3uProvider({
    required String id,
    required String name,
    required String url,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(db.ProvidersCompanion.insert(
      id: id,
      name: name,
      type: 'm3u',
      url: Value(url),
    ));
    await refreshProvider(id);
  }

  /// Add an Xtream Codes provider.
  Future<void> addXtreamProvider({
    required String id,
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(db.ProvidersCompanion.insert(
      id: id,
      name: name,
      type: 'xtream',
      url: Value(url),
      username: Value(username),
      password: Value(password),
    ));
    await refreshProvider(id);
  }

  /// Refresh a provider's channels from its source.
  Future<int> refreshProvider(String providerId) async {
    final providers = await _db.getAllProviders();
    final provider = providers.firstWhere((p) => p.id == providerId);

    List<Channel> channels;
    if (provider.type == 'm3u') {
      channels = await _refreshM3u(provider);
    } else if (provider.type == 'xtream') {
      channels = await _refreshXtream(provider);
    } else {
      return 0;
    }

    // Save channels to database
    await _db.upsertChannels(channels.map((c) => db.ChannelsCompanion.insert(
      id: c.id,
      providerId: c.providerId,
      name: c.name,
      tvgId: Value(c.tvgId),
      tvgName: Value(c.tvgName),
      tvgLogo: Value(c.tvgLogo),
      groupTitle: Value(c.groupTitle),
      channelNumber: Value(c.channelNumber),
      streamUrl: c.streamUrl,
      streamType: Value(c.streamType.name),
    )).toList());

    // Resolve missing logos in background
    _resolveChannelLogos(channels).catchError((_) {});

    return channels.length;
  }

  Future<List<Channel>> _refreshM3u(db.Provider provider) async {
    final dio = Dio();
    try {
      final response = await dio.get<String>(provider.url!);
      final result = _m3uParser.parse(response.data!, providerId: provider.id);
      return result.channels;
    } finally {
      dio.close();
    }
  }

  Future<List<Channel>> _refreshXtream(db.Provider provider) async {
    final client = XtreamClient(
      baseUrl: provider.url!,
      username: provider.username!,
      password: provider.password!,
    );
    try {
      return await client.getLiveStreams(providerId: provider.id);
    } finally {
      client.dispose();
    }
  }

  Future<void> deleteProvider(String id) async {
    await _db.deleteProvider(id);
  }

  /// Resolve missing logos in background after provider refresh.
  Future<void> _resolveChannelLogos(List<Channel> channels) async {
    await resolveLogosForChannels(channels);
  }

  /// Resolve missing logos for a set of channels.
  /// Public so it can be called at startup for existing DB channels.
  Future<void> resolveLogosForChannels(List<Channel> channels) async {
    final needsLogo = channels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) return;
    debugPrint('[Logo] ${needsLogo.length} channels need logos');

    final resolved = <String, String>{};

    // First try EPG icons for channels that have EPG mappings
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      final epgIconMap = <String, String>{};
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          epgIconMap[ec.displayName.toLowerCase()] = ec.iconUrl!;
          epgIconMap[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
      for (final ch in needsLogo.toList()) {
        final stripped = ch.name.toLowerCase()
            .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
            .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
            .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
            .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
        final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
        if (icon != null) {
          resolved[ch.id] = icon;
          needsLogo.removeWhere((c) => c.id == ch.id);
        }
      }
      debugPrint('[Logo] EPG icons resolved ${resolved.length} channels');
    } catch (_) {}

    // Then resolve remaining from tv-logo/tv-logos GitHub repo
    if (needsLogo.isNotEmpty) {
      debugPrint('[Logo] Resolving ${needsLogo.length} via GitHub tv-logos...');
      final ghResolved = await LogoResolverService.resolveLogosForChannels(needsLogo);
      debugPrint('[Logo] GitHub resolved ${ghResolved.length} logos');
      resolved.addAll(ghResolved);
    }

    // Batch-write all resolved logos in a single transaction
    if (resolved.isNotEmpty) {
      await _db.updateChannelLogos(resolved);
    }
  }

  static const _logoResolvedKey = 'logo_last_resolved';
  static const _logoChannelCountKey = 'logo_channel_count';
  static const _logoCooldown = Duration(hours: 6);
  static const _logoBatchSize = 200;

  /// Resolve missing logos progressively: favorites first, then the rest
  /// in small batches so the UI stays responsive.
  /// Skips entirely if resolved recently and channel count hasn't changed.
  Future<void> resolveAllMissingLogos() async {
    final prefs = await SharedPreferences.getInstance();
    final lastResolved = prefs.getInt(_logoResolvedKey) ?? 0;
    final lastCount = prefs.getInt(_logoChannelCountKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - lastResolved;

    final allChannels = await _db.getAllChannels();

    // Skip if resolved recently AND no new channels were added
    if (age < _logoCooldown.inMilliseconds && allChannels.length == lastCount) {
      return;
    }

    final needsLogo = allChannels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) {
      await prefs.setInt(_logoResolvedKey, DateTime.now().millisecondsSinceEpoch);
      await prefs.setInt(_logoChannelCountKey, allChannels.length);
      return;
    }

    // Build lookup maps once
    final epgIconMap = await _buildEpgIconMap();
    await LogoResolverService.ensureIndex(); // pre-load GitHub index

    // Partition: favorites first, then the rest
    final favIds = await _db.getAllFavoritedChannelIds();
    final favorites = needsLogo.where((c) => favIds.contains(c.id)).toList();
    final rest = needsLogo.where((c) => !favIds.contains(c.id)).toList();

    debugPrint('[Logo] ${needsLogo.length} missing (${favorites.length} favorites, ${rest.length} other)');

    // Resolve favorites immediately
    if (favorites.isNotEmpty) {
      final resolved = await _resolveLogoBatch(favorites, epgIconMap);
      if (resolved.isNotEmpty) {
        await _db.updateChannelLogos(resolved);
        debugPrint('[Logo] Favorites: resolved ${resolved.length} logos');
      }
    }

    // Resolve rest in small batches with yields between
    for (var i = 0; i < rest.length; i += _logoBatchSize) {
      final batch = rest.sublist(i, (i + _logoBatchSize).clamp(0, rest.length));
      final resolved = await _resolveLogoBatch(batch, epgIconMap);
      if (resolved.isNotEmpty) {
        await _db.updateChannelLogos(resolved);
      }
      // Yield to UI between batches
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    debugPrint('[Logo] Resolution complete');
    await prefs.setInt(_logoResolvedKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_logoChannelCountKey, allChannels.length);
  }

  /// Build EPG icon lookup map (display name / channel ID → icon URL).
  Future<Map<String, String>> _buildEpgIconMap() async {
    final map = <String, String>{};
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          map[ec.displayName.toLowerCase()] = ec.iconUrl!;
          map[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
    } catch (_) {}
    return map;
  }

  /// Resolve logos for a batch of channels using EPG icons + GitHub tv-logos.
  Future<Map<String, String>> _resolveLogoBatch(
    List<({String id, String name, String? tvgLogo})> channels,
    Map<String, String> epgIconMap,
  ) async {
    final resolved = <String, String>{};
    final remaining = <({String id, String name, String? tvgLogo})>[];

    for (final ch in channels) {
      final stripped = ch.name.toLowerCase()
          .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
          .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
          .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
          .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
      final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
      if (icon != null) {
        resolved[ch.id] = icon;
      } else {
        remaining.add(ch);
      }
    }

    if (remaining.isNotEmpty) {
      final ghResolved = await LogoResolverService.resolveLogosForChannels(remaining);
      resolved.addAll(ghResolved);
    }

    return resolved;
  }
}

class ProviderLimitException implements Exception {
  final int limit;
  const ProviderLimitException(this.limit);

  @override
  String toString() =>
      'Provider limit reached ($limit). Upgrade to Pro for unlimited providers.';
}

/// Riverpod provider for the database.
final databaseProvider = Provider<db.AppDatabase>((ref) {
  final database = db.AppDatabase();
  ref.onDispose(() => database.close());
  return database;
});

/// Riverpod provider for the provider manager.
final providerManagerProvider = Provider<ProviderManager>((ref) {
  return ProviderManager(ref.watch(databaseProvider));
});
