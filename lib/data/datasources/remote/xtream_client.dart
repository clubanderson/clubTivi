import 'package:dio/dio.dart';
import '../../models/channel.dart';
import '../../models/vod_item.dart';

/// Xtream Codes API client.
///
/// Supports both Xtream Codes and XUI APIs which share the same player_api.php
/// endpoint structure. Handles authentication, category/stream listing,
/// EPG retrieval, and VOD/series catalogs.
class XtreamClient {
  final Dio _dio;
  final String baseUrl;
  final String username;
  final String password;

  XtreamClient({
    required this.baseUrl,
    required this.username,
    required this.password,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
  }

  String get _apiBase => '$baseUrl/player_api.php';

  Map<String, String> get _authParams => {
        'username': username,
        'password': password,
      };

  /// Authenticate and get server info + account status.
  Future<XtreamServerInfo> authenticate() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: _authParams,
    );
    return XtreamServerInfo.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get live stream categories.
  Future<List<XtreamCategory>> getLiveCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_live_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get all live streams, optionally filtered by category.
  Future<List<Channel>> getLiveStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final params = {..._authParams, 'action': 'get_live_streams'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return _channelFromXtream(json, providerId);
    }).toList();
  }

  /// Get VOD categories.
  Future<List<XtreamCategory>> getVodCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_vod_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get VOD streams with full metadata, optionally filtered by category.
  ///
  /// Returns [VodItem]s (movie type) with ratings, artwork, and prebuilt
  /// direct-play URLs. Category names are joined from `get_vod_categories`
  /// since stream rows only carry `category_id`.
  Future<List<VodItem>> getVodStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final categories = await getVodCategories();
    final categoryNames = {for (final c in categories) c.id: c.name};

    final params = {..._authParams, 'action': 'get_vod_streams'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      final item = VodItem.fromXtreamVod(
        json: json,
        providerId: providerId,
        baseUrl: baseUrl,
        username: username,
        password: password,
      );
      final catName = categoryNames[item.categoryId];
      return catName != null ? item.copyWith(category: catName) : item;
    }).toList();
  }

  /// Get series categories.
  Future<List<XtreamCategory>> getSeriesCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_series_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get series list with full metadata.
  ///
  /// Returns [VodItem]s (series type). Series rows have no direct-play URL —
  /// use [getSeriesInfo] + [buildSeriesEpisodeUrl] (or [resolveSeriesEpisode])
  /// to resolve a specific season/episode on demand.
  Future<List<VodItem>> getSeriesStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final categories = await getSeriesCategories();
    final categoryNames = {for (final c in categories) c.id: c.name};

    final params = {..._authParams, 'action': 'get_series'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      final item = VodItem.fromXtreamSeries(
        json: json,
        providerId: providerId,
      );
      final catName = categoryNames[item.categoryId];
      return catName != null ? item.copyWith(category: catName) : item;
    }).toList();
  }

  /// Get short EPG for a specific stream (current + next few programs).
  Future<List<XtreamEpgEntry>> getShortEpg(String streamId) async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {
        ..._authParams,
        'action': 'get_short_epg',
        'stream_id': streamId,
      },
    );
    final data = response.data as Map<String, dynamic>;
    final listings = data['epg_listings'] as List? ?? [];
    return listings
        .map((e) => XtreamEpgEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Build a live stream URL.
  String buildLiveUrl(int streamId, {String extension = 'ts'}) {
    return '$baseUrl/live/$username/$password/$streamId.$extension';
  }

  /// Build a VOD stream URL.
  String buildVodUrl(int streamId, {String extension = 'mp4'}) {
    return '$baseUrl/movie/$username/$password/$streamId.$extension';
  }

  Channel _channelFromXtream(Map<String, dynamic> json, String providerId) {
    final streamId = json['stream_id'];
    final num = json['num'] is int ? json['num'] as int : int.tryParse('${json['num']}');

    return Channel(
      id: '${providerId}_$streamId',
      providerId: providerId,
      name: json['name'] as String? ?? 'Unknown',
      tvgId: json['epg_channel_id'] as String?,
      tvgName: json['name'] as String?,
      tvgLogo: json['stream_icon'] as String?,
      groupTitle: json['category_name'] as String?,
      channelNumber: num,
      streamUrl: buildLiveUrl(streamId as int),
      streamType: StreamType.live,
    );
  }

  /// Get full series info (seasons + per-season episodes) for a series.
  ///
  /// This is the only on-demand API call needed for series playback: the
  /// series catalog itself is matched from the local DB, then this single
  /// call resolves the exact episode stream.
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {
        ..._authParams,
        'action': 'get_series_info',
        'series_id': seriesId.toString(),
      },
    );
    return XtreamSeriesInfo.fromJson(response.data as Map<String, dynamic>);
  }

  /// Build a direct-play URL for a series episode.
  String buildSeriesEpisodeUrl(int episodeId, {String extension = 'mp4'}) {
    return '$baseUrl/series/$username/$password/$episodeId.$extension';
  }

  /// Extract a language/country code prefix from a provider catalog name.
  ///
  /// Returns the uppercased code ("EN", "AF-EN", "IT") or null when the
  /// name carries no prefix. Quality prefixes ("4K-") are skipped first.
  /// Uses the same prefix shapes the matcher strips, so the language
  /// removed for matching stays visible to the user when picking a stream.
  static final _qualityPrefixPattern = RegExp(
    r'^\s*(?:4k|8k|uhd|fhd|hd|hdr|hdcam|hdts|hdtv|cam|ts|tc|sd|3d)\s*[-|:]\s*',
    caseSensitive: false,
  );
  static final _languagePrefixPattern = RegExp(
    r'^\s*(?:\[([A-Za-z]{2}(?:-[A-Za-z]{2})?)\]|([A-Za-z]{2}(?:-[A-Za-z]{2})?)\s*[-|:])\s*',
  );

  /// Strip quality + language/country prefixes ("4K-IT - ", "EN - ",
  /// "US | ", "[EN] ") that catalogs prepend to VOD/series names.
  /// A separator is required — a bare 2-letter word ("Up", "It") is kept.
  static String stripCatalogPrefix(String name) {
    var result = name;
    for (var i = 0; i < 4; i++) {
      final next = result
          .replaceFirst(_qualityPrefixPattern, '')
          .replaceFirst(_languagePrefixPattern, '');
      if (next == result) break;
      result = next;
    }
    return result;
  }

  static String? extractLanguage(String rawName) {
    var rest = rawName;
    for (var i = 0; i < 4; i++) {
      final next = rest.replaceFirst(_qualityPrefixPattern, '');
      if (next == rest) break;
      rest = next;
    }
    final match = _languagePrefixPattern.firstMatch(rest);
    if (match == null) return null;
    return (match.group(1) ?? match.group(2)!).toUpperCase();
  }

  /// Resolve a specific season/episode of a series to a direct-play URL.
  ///
  /// Returns null when the season/episode isn't found in [getSeriesInfo].
  Future<XtreamEpisodeStream?> resolveSeriesEpisode({
    required int seriesId,
    required int season,
    required int episode,
  }) async {
    final info = await getSeriesInfo(seriesId);
    final match = info.findEpisode(season, episode);
    if (match == null) return null;
    return XtreamEpisodeStream(
      url: buildSeriesEpisodeUrl(
        match.id,
        extension: match.containerExtension,
      ),
      episode: match,
    );
  }

  void dispose() {
    _dio.close();
  }
}

/// Server info returned by authentication.
class XtreamServerInfo {
  final String? url;
  final String? port;
  final String? httpsPort;
  final String? serverProtocol;
  final String? status;
  final DateTime? expDate;
  final int? maxConnections;
  final int? activeCons;
  final bool isTrial;

  const XtreamServerInfo({
    this.url,
    this.port,
    this.httpsPort,
    this.serverProtocol,
    this.status,
    this.expDate,
    this.maxConnections,
    this.activeCons,
    this.isTrial = false,
  });

  bool get isActive => status == 'Active';

  factory XtreamServerInfo.fromJson(Map<String, dynamic> json) {
    final userInfo = json['user_info'] as Map<String, dynamic>? ?? {};
    final serverInfo = json['server_info'] as Map<String, dynamic>? ?? {};

    DateTime? expDate;
    final exp = userInfo['exp_date'];
    if (exp != null && exp != '' && exp != 'null') {
      expDate = DateTime.fromMillisecondsSinceEpoch(
        int.parse(exp.toString()) * 1000,
      );
    }

    return XtreamServerInfo(
      url: serverInfo['url'] as String?,
      port: serverInfo['port']?.toString(),
      httpsPort: serverInfo['https_port']?.toString(),
      serverProtocol: serverInfo['server_protocol'] as String?,
      status: userInfo['status'] as String?,
      expDate: expDate,
      maxConnections: int.tryParse('${userInfo['max_connections']}'),
      activeCons: int.tryParse('${userInfo['active_cons']}'),
      isTrial: userInfo['is_trial'] == '1',
    );
  }
}

/// Xtream category (live, VOD, or series).
class XtreamCategory {
  final String id;
  final String name;
  final int? parentId;

  const XtreamCategory({
    required this.id,
    required this.name,
    this.parentId,
  });

  factory XtreamCategory.fromJson(Map<String, dynamic> json) {
    return XtreamCategory(
      id: json['category_id']?.toString() ?? '',
      name: json['category_name'] as String? ?? '',
      parentId: int.tryParse('${json['parent_id']}'),
    );
  }
}

/// Single EPG entry from Xtream short EPG.
class XtreamEpgEntry {
  final String title;
  final String description;
  final DateTime? start;
  final DateTime? end;

  const XtreamEpgEntry({
    required this.title,
    this.description = '',
    this.start,
    this.end,
  });

  factory XtreamEpgEntry.fromJson(Map<String, dynamic> json) {
    return XtreamEpgEntry(
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      start: DateTime.tryParse(json['start'] as String? ?? ''),
      end: DateTime.tryParse(json['end'] as String? ?? ''),
    );
  }
}

/// Full series detail from `get_series_info`.
///
/// Mirrors the reference `SeriesInfo` type: series-level metadata (`info`),
/// a season list (`seasons`), and episodes keyed by season number
/// (`episodes` maps season-number strings to episode lists).
class XtreamSeriesInfo {
  final String? name;
  final String? cover;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;
  final double? rating;
  final double? rating5based;
  final String? tmdbId;
  final String? youtubeTrailer;
  final int? episodeRunTime;
  final List<XtreamSeriesSeason> seasons;
  final Map<int, List<XtreamSeriesEpisode>> episodesBySeason;

  const XtreamSeriesInfo({
    this.name,
    this.cover,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
    this.rating,
    this.rating5based,
    this.tmdbId,
    this.youtubeTrailer,
    this.episodeRunTime,
    this.seasons = const [],
    this.episodesBySeason = const {},
  });

  /// Find a specific episode by season/episode number.
  XtreamSeriesEpisode? findEpisode(int season, int episode) {
    final list = episodesBySeason[season];
    if (list == null) return null;
    for (final ep in list) {
      if (ep.episodeNum == episode) return ep;
    }
    return null;
  }

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse('$value');
  }

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse('$value');
  }

  factory XtreamSeriesInfo.fromJson(Map<String, dynamic> json) {
    final info = json['info'] as Map<String, dynamic>? ?? {};

    final seasons = <XtreamSeriesSeason>[];
    final rawSeasons = json['seasons'];
    if (rawSeasons is List) {
      for (final s in rawSeasons) {
        if (s is Map<String, dynamic>) {
          seasons.add(XtreamSeriesSeason.fromJson(s));
        }
      }
    }

    final episodesBySeason = <int, List<XtreamSeriesEpisode>>{};
    final rawEpisodes = json['episodes'];
    if (rawEpisodes is Map) {
      for (final entry in rawEpisodes.entries) {
        final seasonNum = int.tryParse('${entry.key}');
        if (seasonNum == null) continue;
        final list = <XtreamSeriesEpisode>[];
        if (entry.value is List) {
          for (final e in (entry.value as List)) {
            if (e is Map<String, dynamic>) {
              list.add(
                XtreamSeriesEpisode.fromJson(e, fallbackSeason: seasonNum),
              );
            }
          }
        }
        episodesBySeason[seasonNum] = list;
      }
    }

    return XtreamSeriesInfo(
      name: info['name'] as String?,
      cover: info['cover'] as String?,
      plot: info['plot'] as String?,
      cast: info['cast'] as String?,
      director: info['director'] as String?,
      genre: info['genre'] as String?,
      releaseDate: info['releaseDate'] as String?,
      rating: _parseDouble(info['rating']),
      rating5based: _parseDouble(info['rating_5based']),
      tmdbId: info['tmdb']?.toString(),
      youtubeTrailer: info['youtube_trailer'] as String?,
      episodeRunTime: _parseInt(info['episode_run_time']),
      seasons: seasons,
      episodesBySeason: episodesBySeason,
    );
  }
}

/// A single season of a series from `get_series_info`.
class XtreamSeriesSeason {
  final String? name;
  final int? seasonNumber;
  final int? episodeCount;
  final String? overview;
  final String? airDate;
  final String? cover;

  const XtreamSeriesSeason({
    this.name,
    this.seasonNumber,
    this.episodeCount,
    this.overview,
    this.airDate,
    this.cover,
  });

  factory XtreamSeriesSeason.fromJson(Map<String, dynamic> json) {
    int? parseInt(dynamic v) =>
        v is int ? v : int.tryParse('${v ?? ''}');
    return XtreamSeriesSeason(
      name: json['name'] as String?,
      seasonNumber: parseInt(json['season_number']),
      episodeCount: parseInt(json['episode_count']),
      overview: json['overview'] as String?,
      airDate: json['air_date'] as String?,
      cover: (json['cover'] ?? json['cover_big'] ?? json['cover_tmdb'])
          as String?,
    );
  }
}

/// A single episode of a series from `get_series_info`.
///
/// Mirrors the reference `SeriesEpisode` type. The provider-global episode
/// `id` plus [containerExtension] is all that's needed to build a
/// direct-play URL via `XtreamClient.buildSeriesEpisodeUrl`.
class XtreamSeriesEpisode {
  final int id;
  final int? episodeNum;
  final int? season;
  final String? title;
  final String containerExtension;

  const XtreamSeriesEpisode({
    required this.id,
    this.episodeNum,
    this.season,
    this.title,
    this.containerExtension = 'mp4',
  });

  factory XtreamSeriesEpisode.fromJson(
    Map<String, dynamic> json, {
    int? fallbackSeason,
  }) {
    int? parseInt(dynamic v) =>
        v is int ? v : int.tryParse('${v ?? ''}');
    final rawId = json['id'];
    return XtreamSeriesEpisode(
      id: rawId is int ? rawId : int.tryParse('$rawId') ?? 0,
      episodeNum: parseInt(json['episode_num']),
      season: parseInt(json['season']) ?? fallbackSeason,
      title: json['title'] as String?,
      containerExtension:
          json['container_extension'] as String? ?? 'mp4',
    );
  }
}

/// A resolved series episode with its direct-play URL.
class XtreamEpisodeStream {
  final String url;
  final XtreamSeriesEpisode episode;

  const XtreamEpisodeStream({required this.url, required this.episode});
}
