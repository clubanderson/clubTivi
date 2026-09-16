import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/parsers/m3u_parser.dart';
import '../../data/datasources/remote/xtream_client.dart';
import '../../data/models/channel.dart' hide Provider;
import '../../data/models/vod_item.dart';
import '../../data/services/logo_resolver_service.dart';
import '../../core/feature_gate.dart';
import 'package:dio/dio.dart';

/// Deduplicate catalog items by (providerId, streamId), keeping the last
/// occurrence — the same "last wins" semantics as the DB upsert.
/// Only an exact key match counts: rows sharing just a name (different
/// encodes or entries) or just a stream id (different providers) are kept.
List<VodItem> dedupeVodItems(List<VodItem> items) {
  final keyed = <String, VodItem>{};
  final unkeyed = <VodItem>[];
  for (final item in items) {
    final streamId = item.streamId;
    if (streamId == null) {
      unkeyed.add(item);
    } else {
      keyed['${item.providerId}_$streamId'] = item;
    }
  }
  return [...keyed.values, ...unkeyed];
}

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
    await _db.upsertProvider(
      db.ProvidersCompanion.insert(
        id: id,
        name: name,
        type: 'm3u',
        url: Value(url),
      ),
    );
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
    await _db.upsertProvider(
      db.ProvidersCompanion.insert(
        id: id,
        name: name,
        type: 'xtream',
        url: Value(url),
        username: Value(username),
        password: Value(password),
      ),
    );
    await refreshProvider(id);
  }

  /// Refresh a provider's channels from its source.
  ///
  /// For Xtream providers this fetches all three catalogs (live + VOD +
  /// series) and stores them locally: live rows go to `channels`, VOD rows
  /// to `xtream_vod`, series rows to `xtream_series`. Playback lookups then
  /// hit the DB with no live API calls until the next manual refresh.
  Future<int> refreshProvider(String providerId) async {
    final providers = await _db.getAllProviders();
    final provider = providers.firstWhere((p) => p.id == providerId);

    int count;
    if (provider.type == 'm3u') {
      final channels = await _refreshM3u(provider);
      await _saveLiveChannels(channels);
      count = channels.length;
    } else if (provider.type == 'xtream') {
      count = await _refreshXtream(provider);
    } else {
      return 0;
    }

    await _db.updateProviderRefreshTime(providerId);
    return count;
  }

  /// Save live channels to the database and kick off logo resolution.
  Future<void> _saveLiveChannels(List<Channel> channels) async {
    // Save channels to database
    await _db.upsertChannels(
      channels
          .map(
            (c) => db.ChannelsCompanion.insert(
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
            ),
          )
          .toList(),
    );

    // Resolve missing logos in background
    _resolveChannelLogos(channels).catchError((_) {});
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

  /// Refresh an Xtream provider: fetch live + VOD + series catalogs and
  /// store each in its own table. Returns the total stored row count.
  ///
  /// Live is required; VOD/series are best-effort so a large or failing
  /// catalog can't wipe out the live channels.
  Future<int> _refreshXtream(db.Provider provider) async {
    final client = XtreamClient(
      baseUrl: provider.url!,
      username: provider.username!,
      password: provider.password!,
    );
    try {
      final live = await client.getLiveStreams(providerId: provider.id);
      await _saveLiveChannels(live);
      final total = live.length;

      try {
        final vod = await client.getVodStreams(providerId: provider.id);
        await _saveVodItems(provider.id, vod);
      } catch (e) {
        debugPrint('[Provider] VOD refresh failed for ${provider.name}: $e');
      }

      try {
        final series = await client.getSeriesStreams(providerId: provider.id);
        await _saveSeriesItems(provider.id, series);
      } catch (e) {
        debugPrint('[Provider] Series refresh failed for ${provider.name}: $e');
      }

      return total;
    } finally {
      client.dispose();
    }
  }

  /// Upsert VOD items into `xtream_vod` in chunks. Returns rows stored.
  Future<int> _saveVodItems(String providerId, List<VodItem> items) async {
    final entries = <db.XtreamVodCompanion>[];
    for (final item in dedupeVodItems(items)) {
      final streamId = item.streamId;
      final streamUrl = item.streamUrl;
      if (streamId == null || streamUrl == null) continue;
      entries.add(
        db.XtreamVodCompanion.insert(
          id: item.id,
          providerId: providerId,
          streamId: streamId,
          name: item.name,
          categoryId: Value(item.categoryId),
          categoryName: Value(item.category),
          icon: Value(item.posterUrl),
          containerExtension: Value(item.containerExtension ?? 'mp4'),
          streamUrl: streamUrl,
          rating: Value(item.rating),
          rating5based: Value(item.rating5based),
          tmdb: Value(item.tmdb),
          trailer: Value(item.trailer),
          plot: Value(item.plot),
          cast: Value(item.cast),
          director: Value(item.director),
          genre: Value(item.genre),
          releaseDate: Value(item.releaseDate),
        ),
      );
    }
    await _upsertInChunks(entries, (chunk) => _db.upsertXtreamVod(chunk));
    return entries.length;
  }

  /// Upsert series items into `xtream_series` in chunks. Returns rows stored.
  Future<int> _saveSeriesItems(String providerId, List<VodItem> items) async {
    final entries = <db.XtreamSeriesCompanion>[];
    for (final item in dedupeVodItems(items)) {
      final seriesId = item.streamId;
      if (seriesId == null) continue;
      entries.add(
        db.XtreamSeriesCompanion.insert(
          id: item.id,
          providerId: providerId,
          seriesId: seriesId,
          name: item.name,
          categoryId: Value(item.categoryId),
          categoryName: Value(item.category),
          cover: Value(item.posterUrl),
          plot: Value(item.plot),
          cast: Value(item.cast),
          director: Value(item.director),
          genre: Value(item.genre),
          releaseDate: Value(item.releaseDate),
          rating: Value(item.rating),
          rating5based: Value(item.rating5based),
          tmdb: Value(item.tmdb),
          youtubeTrailer: Value(item.trailer),
        ),
      );
    }
    await _upsertInChunks(entries, (chunk) => _db.upsertXtreamSeries(chunk));
    return entries.length;
  }

  /// Insert entries in bounded chunks to stay under SQLite variable limits.
  static const _upsertChunkSize = 500;

  Future<void> _upsertInChunks<T>(
    List<T> entries,
    Future<void> Function(List<T> chunk) upsert,
  ) async {
    for (var i = 0; i < entries.length; i += _upsertChunkSize) {
      final end = (i + _upsertChunkSize).clamp(0, entries.length);
      await upsert(entries.sublist(i, end));
    }
  }

  Future<void> deleteProvider(String id) async {
    await _db.deleteXtreamVodForProvider(id);
    await _db.deleteXtreamSeriesForProvider(id);
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
        final stripped = ch.name
            .toLowerCase()
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
      final ghResolved = await LogoResolverService.resolveLogosForChannels(
        needsLogo,
      );
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
      await prefs.setInt(
        _logoResolvedKey,
        DateTime.now().millisecondsSinceEpoch,
      );
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

    debugPrint(
      '[Logo] ${needsLogo.length} missing (${favorites.length} favorites, ${rest.length} other)',
    );

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
      final stripped = ch.name
          .toLowerCase()
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
      final ghResolved = await LogoResolverService.resolveLogosForChannels(
        remaining,
      );
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
