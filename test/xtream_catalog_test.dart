import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/datasources/remote/xtream_client.dart';
import 'package:clubtivi/data/models/vod_title.dart';
import 'package:clubtivi/data/models/vod_item.dart';
import 'package:clubtivi/data/repositories/vod_repository.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';

void main() {
  group('VodItem Xtream factories', () {
    test('fromXtreamVod builds movie URL and parses metadata', () {
      final item = VodItem.fromXtreamVod(
        json: {
          'stream_id': 123,
          'name': 'Dune (2021)',
          'container_extension': 'mkv',
          'stream_icon': 'http://img/poster.jpg',
          'category_id': '7',
          'category_name': 'Movies',
          'rating': '8.5',
          'rating_5based': 4.2,
          'tmdb': '438631',
          'plot': 'Desert epic',
        },
        providerId: 'p1',
        baseUrl: 'http://line.tv:8080',
        username: 'u',
        password: 'p',
      );

      expect(item.id, 'p1_vod_123');
      expect(item.type, VodType.movie);
      expect(item.streamUrl, 'http://line.tv:8080/movie/u/p/123.mkv');
      expect(item.categoryId, '7');
      expect(item.rating, 8.5);
      expect(item.rating5based, 4.2);
      expect(item.tmdb, '438631');
      expect(item.plot, 'Desert epic');
    });

    test('fromXtreamSeries parses cover and has no stream URL', () {
      final item = VodItem.fromXtreamSeries(
        json: {
          'series_id': 42,
          'name': 'Breaking Bad',
          'cover': 'http://img/cover.jpg',
          'category_id': '3',
          'youtube_trailer': 'abc123',
          'rating_5based': '9.50',
        },
        providerId: 'p1',
      );

      expect(item.id, 'p1_series_42');
      expect(item.type, VodType.series);
      expect(item.isSeries, isTrue);
      expect(item.streamUrl, isNull);
      expect(item.posterUrl, 'http://img/cover.jpg');
      expect(item.trailer, 'abc123');
    });
  });

  group('extractLanguage', () {
    test('parses provider language prefixes', () {
      expect(XtreamClient.extractLanguage('AF-EN - Deathly Obsession'), 'AF-EN');
      expect(XtreamClient.extractLanguage('EN - Obsession (2026)'), 'EN');
      expect(XtreamClient.extractLanguage('US | Breaking Bad'), 'US');
      expect(XtreamClient.extractLanguage('[FR] Amélie'), 'FR');
      expect(XtreamClient.extractLanguage('UK: Top Gear'), 'UK');
      expect(XtreamClient.extractLanguage('  EN - Padded'), 'EN');
    });

    test('returns null without a prefix and keeps bare words', () {
      expect(XtreamClient.extractLanguage('Moana (2016)'), isNull);
      expect(XtreamClient.extractLanguage('Hope'), isNull);
      expect(XtreamClient.extractLanguage('Up 2009'), isNull);
      expect(XtreamClient.extractLanguage('It (2017)'), isNull);
    });

    test('skips quality prefixes to find the language', () {
      expect(XtreamClient.extractLanguage('4K-IT - Obsession (2026)'), 'IT');
      expect(XtreamClient.extractLanguage('4K-FR-HDR - Title'), 'FR');
      expect(XtreamClient.extractLanguage('CAM - Title'), isNull);
    });
  });

  group('stripCatalogPrefix', () {
    test('strips language, country, and quality prefixes', () {
      expect(
        XtreamClient.stripCatalogPrefix('EN - Obsession (2026)'),
        'Obsession (2026)',
      );
      expect(
        XtreamClient.stripCatalogPrefix('AF-EN - Deathly Obsession'),
        'Deathly Obsession',
      );
      expect(
        XtreamClient.stripCatalogPrefix('4K-IT - Obsession (2026)'),
        'Obsession (2026)',
      );
      expect(
        XtreamClient.stripCatalogPrefix('US | Breaking Bad'),
        'Breaking Bad',
      );
      expect(XtreamClient.stripCatalogPrefix('[FR] Amélie'), 'Amélie');
    });

    test('keeps bare words that look like codes', () {
      expect(XtreamClient.stripCatalogPrefix('Up 2009'), 'Up 2009');
      expect(XtreamClient.stripCatalogPrefix('It (2017)'), 'It (2017)');
      expect(XtreamClient.stripCatalogPrefix('Tsunami'), 'Tsunami');
    });
  });

  group('XtreamSeriesInfo', () {
    Map<String, dynamic> sampleJson() => {
          'info': {'name': 'Breaking Bad'},
          'seasons': [
            {'name': 'Season 1', 'season_number': 1, 'episode_count': 2},
          ],
          'episodes': {
            '1': [
              {
                'id': 1001,
                'episode_num': 1,
                'season': 1,
                'title': 'Pilot',
                'container_extension': 'mp4',
              },
              {
                'id': 1002,
                'episode_num': 2,
                'season': 1,
                'title': "Cat's in the Bag",
                'container_extension': 'mkv',
              },
            ],
          },
        };

    test('parses seasons and episodes keyed by season number', () {
      final info = XtreamSeriesInfo.fromJson(sampleJson());
      expect(info.name, 'Breaking Bad');
      expect(info.seasons, hasLength(1));
      expect(info.seasons.first.seasonNumber, 1);
      expect(info.episodesBySeason[1], hasLength(2));
    });

    test('findEpisode locates the right episode id and extension', () {
      final info = XtreamSeriesInfo.fromJson(sampleJson());
      final ep = info.findEpisode(1, 2);
      expect(ep, isNotNull);
      expect(ep!.id, 1002);
      expect(ep.containerExtension, 'mkv');
      expect(info.findEpisode(1, 99), isNull);
      expect(info.findEpisode(9, 1), isNull);
    });
  });

  group('Xtream VOD/Series tables', () {
    late db.AppDatabase database;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p1',
              name: 'Test Provider',
              type: 'xtream',
            ),
          );
    });

    tearDownAll(() async {
      await database.close();
    });

    test('upsert + case-insensitive VOD search', () async {
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'Dune Part Two (2024)',
          streamUrl: 'http://line.tv/movie/u/p/1.mp4',
          rating: const Value(8.6),
        ),
      ]);

      final hits = await database.searchXtreamVod('dune part');
      expect(hits, hasLength(1));
      expect(hits.first.streamId, 1);
      expect(hits.first.rating, 8.6);

      expect(await database.searchXtreamVod('nonexistent'), isEmpty);
    });

    test('upsert on conflict updates existing VOD row', () async {
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'Dune Part Two (2024) Remastered',
          streamUrl: 'http://line.tv/movie/u/p/1.mp4',
        ),
      ]);

      final hits = await database.searchXtreamVod('dune part');
      expect(hits, hasLength(1));
      expect(hits.first.name, contains('Remastered'));
    });

    test('upsert + search + delete series rows', () async {
      await database.upsertXtreamSeries([
        db.XtreamSeriesCompanion.insert(
          id: 'p1_series_42',
          providerId: 'p1',
          seriesId: 42,
          name: 'Breaking Bad',
          cover: const Value('http://img/cover.jpg'),
        ),
      ]);

      final hits = await database.searchXtreamSeries('breaking');
      expect(hits, hasLength(1));
      expect(hits.first.seriesId, 42);

      await database.deleteXtreamSeriesForProvider('p1');
      expect(await database.getAllXtreamSeries(), isEmpty);

      // VOD rows for other providers are untouched by series delete
      expect(await database.getAllXtreamVod(), hasLength(1));
      await database.deleteXtreamVodForProvider('p1');
      expect(await database.getAllXtreamVod(), isEmpty);
    });
  });

  group('Xtream title matching', () {
    late db.AppDatabase database;
    late VodRepository repo;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p2',
              name: 'Sports + Movies',
              type: 'xtream',
            ),
          );
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p2_vod_10',
          providerId: 'p2',
          streamId: 10,
          name: 'Moana (2016)',
          streamUrl: 'http://line.tv/movie/u/p/10.mp4',
          tmdb: const Value('277834'),
        ),
        db.XtreamVodCompanion.insert(
          id: 'p2_vod_11',
          providerId: 'p2',
          streamId: 11,
          name: 'SOC - Highlanders vs Moana Pasifika',
          streamUrl: 'http://line.tv/movie/u/p/11.mp4',
        ),
        db.XtreamVodCompanion.insert(
          id: 'p2_vod_12',
          providerId: 'p2',
          streamId: 12,
          name: 'Moana 2 (2024)',
          streamUrl: 'http://line.tv/movie/u/p/12.mp4',
          tmdb: const Value('1241982'),
        ),
      ]);
      repo = VodRepository(database: database);
    });

    tearDownAll(() async {
      await database.close();
    });

    test('partial-word sports hit is excluded without TMDB id', () async {
      final results = await repo.findXtreamStreams(
        title: 'Moana',
        year: 2016,
        mediaType: VodTitleType.movie,
      );
      final names = results.map((r) => r.filename).toList();
      expect(names, contains('Moana (2016)'));
      expect(
        names.where((n) => n.contains('Highlanders')),
        isEmpty,
        reason: 'Rugby match merely mentions Moana: $names',
      );
    });

    test('exact title ranks above sequel for the same query', () async {
      final results = await repo.findXtreamStreams(
        title: 'Moana',
        year: 2016,
        mediaType: VodTitleType.movie,
      );
      expect(results.first.filename, 'Moana (2016)');
    });

    test('provider TMDB id match wins outright', () async {
      final results = await repo.findXtreamStreams(
        title: 'Moana',
        year: 2016,
        tmdbId: 277834,
        mediaType: VodTitleType.movie,
      );
      expect(results.first.filename, 'Moana (2016)');
      expect(
        results.map((r) => r.filename),
        isNot(contains('SOC - Highlanders vs Moana Pasifika')),
      );
    });
  });

  group('Xtream year handling', () {
    late db.AppDatabase database;
    late VodRepository repo;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p3',
              name: 'Movies Only',
              type: 'xtream',
            ),
          );
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p3_vod_20',
          providerId: 'p3',
          streamId: 20,
          name: 'Hope (2026)',
          streamUrl: 'http://line.tv/movie/u/p/20.mp4',
          tmdb: const Value('999001'),
        ),
        db.XtreamVodCompanion.insert(
          id: 'p3_vod_21',
          providerId: 'p3',
          streamId: 21,
          name: 'Not Without Hope (2025)',
          streamUrl: 'http://line.tv/movie/u/p/21.mp4',
        ),
        db.XtreamVodCompanion.insert(
          id: 'p3_vod_22',
          providerId: 'p3',
          streamId: 22,
          name: 'Hope (2025)',
          streamUrl: 'http://line.tv/movie/u/p/22.mp4',
        ),
        db.XtreamVodCompanion.insert(
          id: 'p3_vod_23',
          providerId: 'p3',
          streamId: 23,
          name: 'Hope',
          streamUrl: 'http://line.tv/movie/u/p/23.mp4',
        ),
      ]);
      repo = VodRepository(database: database);
    });

    tearDownAll(() async {
      await database.close();
    });

    test('single-word tail match is excluded', () async {
      final results = await repo.findXtreamStreams(
        title: 'Hope',
        year: 2026,
        mediaType: VodTitleType.movie,
      );
      final names = results.map((r) => r.filename).toList();
      expect(names, contains('Hope (2026)'));
      expect(
        names.where((n) => n.contains('Without Hope')),
        isEmpty,
        reason: 'Shares only the word "hope": $names',
      );
    });

    test('same title with a different year is demoted, not dropped', () async {
      final results = await repo.findXtreamStreams(
        title: 'Hope',
        year: 2026,
        mediaType: VodTitleType.movie,
      );
      expect(results.first.filename, 'Hope (2026)');
      final names = results.map((r) => r.filename).toList();
      expect(names.indexOf('Hope (2026)'), lessThan(names.indexOf('Hope (2025)')));
    });

    test('matching year outranks missing year outranks wrong year', () async {
      final results = await repo.findXtreamStreams(
        title: 'Hope',
        year: 2026,
        mediaType: VodTitleType.movie,
      );
      expect(
        results.map((r) => r.filename).toList(),
        ['Hope (2026)', 'Hope', 'Hope (2025)'],
      );
    });
  });

  group('Xtream provider prefixes', () {
    late db.AppDatabase database;
    late VodRepository repo;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p4',
              name: 'Prefixed Catalog',
              type: 'xtream',
            ),
          );
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p4_vod_30',
          providerId: 'p4',
          streamId: 30,
          name: 'AF-EN - Deathly Obsession',
          streamUrl: 'http://line.tv/movie/u/p/30.mp4',
        ),
        db.XtreamVodCompanion.insert(
          id: 'p4_vod_31',
          providerId: 'p4',
          streamId: 31,
          name: 'EN - Obsession (2026)',
          streamUrl: 'http://line.tv/movie/u/p/31.mp4',
          tmdb: const Value('999002'),
        ),
        db.XtreamVodCompanion.insert(
          id: 'p4_vod_32',
          providerId: 'p4',
          streamId: 32,
          name: 'NF - Secret Obsession',
          streamUrl: 'http://line.tv/movie/u/p/32.mp4',
        ),
      ]);
      repo = VodRepository(database: database);
    });

    tearDownAll(() async {
      await database.close();
    });

    test('prefixed exact title with matching year ranks first', () async {
      final results = await repo.findXtreamStreams(
        title: 'Obsession',
        year: 2026,
        mediaType: VodTitleType.movie,
      );
      expect(
        results.map((r) => r.filename).toList(),
        [
          'EN - Obsession (2026)',
          'AF-EN - Deathly Obsession',
          'NF - Secret Obsession',
        ],
      );
    });

    test('prefixed exact title wins even without a query year', () async {
      // Without a year both score the fuzzy base only — insertion order
      // would surface the wrong film first.
      final results = await repo.findXtreamStreams(
        title: 'Obsession',
        mediaType: VodTitleType.movie,
      );
      expect(results.first.filename, 'EN - Obsession (2026)');
      expect(results.first.language, 'EN');
      // The two partial matches tie — both trail, in any order.
      expect(
        results.skip(1).map((r) => r.filename).toSet(),
        {'AF-EN - Deathly Obsession', 'NF - Secret Obsession'},
      );
    });
  });

  group('Xtream locale preference', () {
    late db.AppDatabase database;
    late VodRepository repo;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p5',
              name: 'Multi-language',
              type: 'xtream',
            ),
          );
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p5_vod_50',
          providerId: 'p5',
          streamId: 50,
          name: 'FR - Obsession (2026)',
          streamUrl: 'http://line.tv/movie/u/p/50.mp4',
          tmdb: const Value('888001'),
        ),
        db.XtreamVodCompanion.insert(
          id: 'p5_vod_51',
          providerId: 'p5',
          streamId: 51,
          name: 'EN - Obsession (2026)',
          streamUrl: 'http://line.tv/movie/u/p/51.mp4',
          tmdb: const Value('888001'),
        ),
      ]);
      repo = VodRepository(database: database);
    });

    tearDownAll(() async {
      await database.close();
    });

    test('preferred locale breaks TMDB-match ties', () async {
      final results = await repo.findXtreamStreams(
        title: 'Obsession',
        year: 2026,
        tmdbId: 888001,
        mediaType: VodTitleType.movie,
        preferredLanguage: 'en',
      );
      expect(
        results.map((r) => r.filename).toList(),
        ['EN - Obsession (2026)', 'FR - Obsession (2026)'],
      );
    });

    test('ties keep insertion order without a preference', () async {
      final results = await repo.findXtreamStreams(
        title: 'Obsession',
        year: 2026,
        tmdbId: 888001,
        mediaType: VodTitleType.movie,
      );
      expect(
        results.map((r) => r.filename).toList(),
        ['FR - Obsession (2026)', 'EN - Obsession (2026)'],
      );
    });
  });

  group('Xtream quality prefixes', () {
    late db.AppDatabase database;
    late VodRepository repo;

    setUpAll(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.createMigrator().createAll();
      await database.into(database.providers).insert(
            db.ProvidersCompanion.insert(
              id: 'p6',
              name: 'Quality Tags',
              type: 'xtream',
            ),
          );
      // Inserted worst-first: without quality-prefix stripping both score
      // identically and insertion order would win.
      await database.upsertXtreamVod([
        db.XtreamVodCompanion.insert(
          id: 'p6_vod_60',
          providerId: 'p6',
          streamId: 60,
          name: 'IT - Mass Obsession (2026)',
          streamUrl: 'http://line.tv/movie/u/p/60.mp4',
        ),
        db.XtreamVodCompanion.insert(
          id: 'p6_vod_61',
          providerId: 'p6',
          streamId: 61,
          name: '4K-IT - Obsession (2026)',
          streamUrl: 'http://line.tv/movie/u/p/61.mp4',
        ),
      ]);
      repo = VodRepository(database: database);
    });

    tearDownAll(() async {
      await database.close();
    });

    test('quality-prefixed exact title ranks first', () async {
      final results = await repo.findXtreamStreams(
        title: 'Obsession',
        year: 2026,
        mediaType: VodTitleType.movie,
      );
      expect(
        results.map((r) => r.filename).toList(),
        ['4K-IT - Obsession (2026)', 'IT - Mass Obsession (2026)'],
      );
      expect(results.first.language, 'IT');
    });
  });

  group('dedupeVodItems', () {
    const movie = VodType.movie;

    test('same providerId+streamId collapses to the last occurrence', () {
      final result = dedupeVodItems([
        const VodItem(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'Secret Obsession (stale)',
          type: movie,
        ),
        const VodItem(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'Secret Obsession (2026)',
          type: movie,
        ),
      ]);
      expect(result, hasLength(1));
      expect(result.single.name, 'Secret Obsession (2026)');
    });

    test('same streamId on different providers is kept', () {
      final result = dedupeVodItems([
        const VodItem(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'Secret Obsession',
          type: movie,
        ),
        const VodItem(
          id: 'p2_vod_1',
          providerId: 'p2',
          streamId: 1,
          name: 'Secret Obsession',
          type: movie,
        ),
      ]);
      expect(result, hasLength(2));
    });

    test('same name with different streamIds is kept', () {
      final result = dedupeVodItems([
        const VodItem(
          id: 'p1_vod_1',
          providerId: 'p1',
          streamId: 1,
          name: 'PT - Secret Obsession (2019)',
          type: movie,
        ),
        const VodItem(
          id: 'p1_vod_2',
          providerId: 'p1',
          streamId: 2,
          name: 'PT - Secret Obsession (2019)',
          type: movie,
        ),
      ]);
      expect(result, hasLength(2));
    });

    test('items without a stream id are preserved, never merged', () {
      final result = dedupeVodItems([
        const VodItem(
          id: 'p1_series_x',
          providerId: 'p1',
          name: 'Mystery Series',
          type: VodType.series,
        ),
        const VodItem(
          id: 'p1_series_y',
          providerId: 'p1',
          name: 'Other Series',
          type: VodType.series,
        ),
      ]);
      expect(result, hasLength(2));
    });
  });

  group('mergeRankedStreams', () {
    ResolvedStream mkXtream(String name) => ResolvedStream(
          url: 'http://line.tv/$name',
          filename: name,
          source: 'Xtream 📺 p',
          isCached: true,
        );

    ResolvedStream mkTorrent(String name, {bool cached = false}) =>
        ResolvedStream(
          url: '',
          filename: name,
          source: cached ? 'real-debrid ⚡' : 'torrent',
          isCached: cached,
          magnetUrl: 'magnet:$name',
        );

    test('preserves ranked order on lists longer than sort stability', () {
      // 40 tied Xtream rows: List.sort would scramble these (proven
      // separately: a 50-item all-ties sort came back [16, 1, 2, 3, 4]).
      final xtream = List.generate(40, (i) => mkXtream('X$i'));
      final merged = VodRepository.mergeRankedStreams(
        xtreamStreams: xtream,
        torrentStreams: [
          mkTorrent('plain'),
          mkTorrent('cached', cached: true),
        ],
        limit: 60,
      );
      expect(
        merged.map((s) => s.filename).toList(),
        [...List.generate(40, (i) => 'X$i'), 'cached', 'plain'],
      );
    });

    test('Xtream block first, cached torrents before the rest, capped', () {
      final merged = VodRepository.mergeRankedStreams(
        xtreamStreams: [mkXtream('X')],
        torrentStreams: [mkTorrent('plain'), mkTorrent('cached', cached: true)],
      );
      expect(
        merged.map((s) => s.filename).toList(),
        ['X', 'cached', 'plain'],
      );

      final capped = VodRepository.mergeRankedStreams(
        xtreamStreams: List.generate(20, (i) => mkXtream('X$i')),
        torrentStreams: [mkTorrent('t')],
      );
      expect(capped.length, 15);
      expect(capped.last.filename, 'X14');
    });
  });
}
