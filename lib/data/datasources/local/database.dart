import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'tables.dart';

part 'database.g.dart';

const _uuid = Uuid();

@DriftDatabase(tables: [
  Providers,
  Channels,
  EpgSources,
  EpgChannels,
  EpgProgrammes,
  EpgMappings,
  ChannelGroups,
  FavoriteLists,
  FavoriteListChannels,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(favoriteLists);
            await m.createTable(favoriteListChannels);
          }
        },
      );

  // --- Provider queries ---

  Future<List<Provider>> getAllProviders() => select(providers).get();

  Future<void> upsertProvider(ProvidersCompanion entry) =>
      into(providers).insertOnConflictUpdate(entry);

  Future<void> deleteProvider(String id) =>
      (delete(providers)..where((t) => t.id.equals(id))).go();

  // --- Channel queries ---

  Future<List<Channel>> getChannelsForProvider(String providerId) =>
      (select(channels)..where((t) => t.providerId.equals(providerId))).get();

  Future<List<Channel>> getFavoriteChannels() =>
      (select(channels)..where((t) => t.favorite.equals(true))).get();

  Future<void> upsertChannels(List<ChannelsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(channels, entries);
    });
  }

  Future<void> toggleFavorite(String channelId) async {
    final channel =
        await (select(channels)..where((t) => t.id.equals(channelId)))
            .getSingle();
    await (update(channels)..where((t) => t.id.equals(channelId)))
        .write(ChannelsCompanion(favorite: Value(!channel.favorite)));
  }

  // --- EPG Source queries ---

  Future<List<EpgSource>> getAllEpgSources() => select(epgSources).get();

  Future<void> upsertEpgSource(EpgSourcesCompanion entry) =>
      into(epgSources).insertOnConflictUpdate(entry);

  // --- EPG Channel queries ---

  Future<List<EpgChannel>> getEpgChannelsForSource(String sourceId) =>
      (select(epgChannels)..where((t) => t.sourceId.equals(sourceId))).get();

  Future<void> upsertEpgChannels(List<EpgChannelsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgChannels, entries);
    });
  }

  // --- EPG Programme queries ---

  Future<List<EpgProgramme>> getProgrammes({
    required String epgChannelId,
    required DateTime start,
    required DateTime end,
  }) =>
      (select(epgProgrammes)
            ..where((t) =>
                t.epgChannelId.equals(epgChannelId) &
                t.start.isBiggerOrEqualValue(start) &
                t.stop.isSmallerOrEqualValue(end))
            ..orderBy([(t) => OrderingTerm.asc(t.start)]))
          .get();

  /// Get what's on now for a list of EPG channel IDs.
  Future<List<EpgProgramme>> getNowPlaying(List<String> epgChannelIds) {
    final now = DateTime.now();
    return (select(epgProgrammes)
          ..where((t) =>
              t.epgChannelId.isIn(epgChannelIds) &
              t.start.isSmallerOrEqualValue(now) &
              t.stop.isBiggerOrEqualValue(now)))
        .get();
  }

  Future<void> insertProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries, mode: InsertMode.insertOrReplace);
    });
  }

  Future<void> deleteEpgProgrammesForSource(String sourceId) =>
      (delete(epgProgrammes)..where((t) => t.sourceId.equals(sourceId))).go();

  Future<void> insertEpgProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries);
    });
  }

  Future<void> updateEpgSourceRefreshTime(String id) =>
      (update(epgSources)..where((t) => t.id.equals(id)))
          .write(EpgSourcesCompanion(lastRefresh: Value(DateTime.now())));

  Future<void> deleteEpgSource(String id) async {
    await deleteEpgProgrammesForSource(id);
    await (delete(epgChannels)..where((t) => t.sourceId.equals(id))).go();
    await (delete(epgSources)..where((t) => t.id.equals(id))).go();
  }

  Future<List<Channel>> getAllChannels() => select(channels).get();

  /// Delete old programmes to keep DB size manageable.
  Future<void> pruneOldProgrammes({Duration maxAge = const Duration(days: 7)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    return (delete(epgProgrammes)
          ..where((t) => t.stop.isSmallerThanValue(cutoff)))
        .go();
  }

  // --- EPG Mapping queries ---

  Future<List<EpgMapping>> getAllMappings() => select(epgMappings).get();

  Future<void> upsertMapping(EpgMappingsCompanion entry) =>
      into(epgMappings).insertOnConflictUpdate(entry);

  Future<void> upsertMappings(List<EpgMappingsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgMappings, entries);
    });
  }

  Future<void> deleteMapping(String channelId, String providerId) =>
      (delete(epgMappings)
            ..where((t) =>
                t.channelId.equals(channelId) &
                t.providerId.equals(providerId)))
          .go();

  Future<void> deleteAllMappings() => delete(epgMappings).go();

  /// Get mapping stats.
  Future<Map<String, int>> getMappingStats() async {
    final all = await select(epgMappings).get();
    int mapped = 0, suggested = 0;
    for (final m in all) {
      if (m.source == 'auto' || m.source == 'manual') {
        mapped++;
      } else {
        suggested++;
      }
    }
    return {'mapped': mapped, 'suggested': suggested};
  }

  // --- Favorite List queries ---

  Future<List<FavoriteList>> getAllFavoriteLists() =>
      (select(favoriteLists)..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  Future<List<Channel>> getChannelsInList(String listId) async {
    final query = select(channels).join([
      innerJoin(favoriteListChannels,
          favoriteListChannels.channelId.equalsExp(channels.id)),
    ])
      ..where(favoriteListChannels.listId.equals(listId))
      ..orderBy([OrderingTerm.asc(favoriteListChannels.sortOrder)]);
    final rows = await query.get();
    return rows.map((row) => row.readTable(channels)).toList();
  }

  Future<void> addChannelToList(String listId, String channelId) =>
      into(favoriteListChannels).insertOnConflictUpdate(
        FavoriteListChannelsCompanion.insert(
          listId: listId,
          channelId: channelId,
        ),
      );

  Future<void> removeChannelFromList(String listId, String channelId) =>
      (delete(favoriteListChannels)
            ..where(
                (t) => t.listId.equals(listId) & t.channelId.equals(channelId)))
          .go();

  Future<FavoriteList> createFavoriteList(String name) async {
    final id = _uuid.v4();
    final count = await (select(favoriteLists)..limit(1000)).get();
    final entry = FavoriteListsCompanion.insert(
      id: id,
      name: name,
      sortOrder: Value(count.length),
    );
    await into(favoriteLists).insert(entry);
    return (select(favoriteLists)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameFavoriteList(String id, String name) =>
      (update(favoriteLists)..where((t) => t.id.equals(id)))
          .write(FavoriteListsCompanion(name: Value(name)));

  Future<void> deleteFavoriteList(String id) async {
    await (delete(favoriteListChannels)..where((t) => t.listId.equals(id)))
        .go();
    await (delete(favoriteLists)..where((t) => t.id.equals(id))).go();
  }

  Future<bool> isChannelInList(String listId, String channelId) async {
    final row = await (select(favoriteListChannels)
          ..where(
              (t) => t.listId.equals(listId) & t.channelId.equals(channelId)))
        .getSingleOrNull();
    return row != null;
  }

  Future<List<FavoriteList>> getListsForChannel(String channelId) async {
    final query = select(favoriteLists).join([
      innerJoin(favoriteListChannels,
          favoriteListChannels.listId.equalsExp(favoriteLists.id)),
    ])
      ..where(favoriteListChannels.channelId.equals(channelId));
    final rows = await query.get();
    return rows.map((row) => row.readTable(favoriteLists)).toList();
  }

  /// Get all channel IDs that belong to any favorite list.
  Future<Set<String>> getAllFavoritedChannelIds() async {
    final rows = await select(favoriteListChannels).get();
    return rows.map((r) => r.channelId).toSet();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'clubtivi', 'clubtivi.db'));
    await file.parent.create(recursive: true);
    return NativeDatabase.createInBackground(file);
  });
}
