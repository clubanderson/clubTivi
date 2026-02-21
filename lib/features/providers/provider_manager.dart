import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/parsers/m3u_parser.dart';
import '../../data/datasources/remote/xtream_client.dart';
import '../../data/models/channel.dart' hide Provider;
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
