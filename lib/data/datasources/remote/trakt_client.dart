import 'package:dio/dio.dart';
import '../../models/vod_title.dart';

/// Client for the Trakt.tv API v2
/// Docs: https://trakt.docs.apiary.io/
class TraktClient {
  final Dio _dio;
  final String clientId;

  static const _baseUrl = 'https://api.trakt.tv';

  TraktClient({
    required this.clientId,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 15)
      ..headers = {
        'Content-Type': 'application/json',
        'trakt-api-version': '2',
        'trakt-api-key': clientId,
      };
  }

  /// Get trending TV series
  Future<List<VodTitle>> getTrendingSeries({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/shows/trending',
      queryParameters: {
        'page': page,
        'limit': limit,
        'extended': 'full',
      },
    );
    return (response.data as List).map((e) {
      final showJson = e['show'] as Map<String, dynamic>;
      return _vodTitleFromTrakt(showJson);
    }).toList();
  }

  /// Get popular TV series
  Future<List<VodTitle>> getPopularSeries({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/shows/popular',
      queryParameters: {
        'page': page,
        'limit': limit,
        'extended': 'full',
      },
    );
    return (response.data as List).map((e) {
      return _vodTitleFromTrakt(e as Map<String, dynamic>);
    }).toList();
  }

  /// Get trending movies
  Future<List<VodTitle>> getTrendingMovies({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/movies/trending',
      queryParameters: {
        'page': page,
        'limit': limit,
        'extended': 'full',
      },
    );
    return (response.data as List).map((e) {
      final movie = e['movie'] as Map<String, dynamic>;
      return _vodTitleFromTrakt(movie, type: VodTitleType.movie);
    }).toList();
  }

  /// Get popular movies
  Future<List<VodTitle>> getPopularMovies({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/movies/popular',
      queryParameters: {
        'page': page,
        'limit': limit,
        'extended': 'full',
      },
    );
    return (response.data as List).map((e) {
      return _vodTitleFromTrakt(e as Map<String, dynamic>, type: VodTitleType.movie);
    }).toList();
  }

  /// Search for shows and movies
  Future<List<VodTitle>> search(String query, {String type = 'show,movie'}) async {
    final response = await _dio.get(
      '/search/$type',
      queryParameters: {
        'query': query,
        'extended': 'full',
        'limit': 20,
      },
    );
    return (response.data as List).map((e) {
      final itemType = e['type'] as String;
      final item = e[itemType] as Map<String, dynamic>;
      return _vodTitleFromTrakt(
        item,
        type: itemType == 'movie' ? VodTitleType.movie : VodTitleType.series,
      );
    }).toList();
  }

  /// Get seasons for a series
  Future<List<Season>> getSeasons(int traktId) async {
    final response = await _dio.get(
      '/shows/$traktId/seasons',
      queryParameters: {'extended': 'full'},
    );
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return Season(
        number: json['number'] as int,
        title: json['title'] as String?,
        overview: json['overview'] as String?,
        episodeCount: json['episode_count'] as int?,
        airedEpisodes: json['aired_episodes'] as int?,
        rating: (json['rating'] as num?)?.toDouble(),
        firstAired: json['first_aired'] != null
            ? DateTime.tryParse(json['first_aired'] as String)
            : null,
        traktId: (json['ids'] as Map<String, dynamic>?)?['trakt'] as int?,
        tmdbId: (json['ids'] as Map<String, dynamic>?)?['tmdb'] as int?,
      );
    }).toList();
  }

  /// Get episodes for a season
  Future<List<Episode>> getEpisodes(int traktId, int seasonNumber) async {
    final response = await _dio.get(
      '/shows/$traktId/seasons/$seasonNumber',
      queryParameters: {'extended': 'full'},
    );
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return Episode(
        season: json['season'] as int,
        number: json['number'] as int,
        title: json['title'] as String?,
        overview: json['overview'] as String?,
        rating: (json['rating'] as num?)?.toDouble(),
        votes: json['votes'] as int?,
        runtime: json['runtime'] as int?,
        firstAired: json['first_aired'] != null
            ? DateTime.tryParse(json['first_aired'] as String)
            : null,
        traktId: (json['ids'] as Map<String, dynamic>?)?['trakt'] as int?,
        tmdbId: (json['ids'] as Map<String, dynamic>?)?['tmdb'] as int?,
      );
    }).toList();
  }

  /// Get series details by Trakt ID
  Future<VodTitle> getSeries(int traktId) async {
    final response = await _dio.get(
      '/shows/$traktId',
      queryParameters: {'extended': 'full'},
    );
    return _vodTitleFromTrakt(response.data as Map<String, dynamic>);
  }

  /// Get movie details by Trakt ID
  Future<VodTitle> getMovie(int traktId) async {
    final response = await _dio.get(
      '/movies/$traktId',
      queryParameters: {'extended': 'full'},
    );
    return _vodTitleFromTrakt(
      response.data as Map<String, dynamic>,
      type: VodTitleType.movie,
    );
  }

  VodTitle _vodTitleFromTrakt(Map<String, dynamic> json, {VodTitleType type = VodTitleType.series}) {
    final ids = json['ids'] as Map<String, dynamic>? ?? {};
    return VodTitle(
      traktId: ids['trakt'] as int? ?? 0,
      imdbId: ids['imdb'] as String?,
      tmdbId: ids['tmdb'] as int?,
      title: json['title'] as String? ?? 'Unknown',
      year: json['year'] as int?,
      overview: json['overview'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      votes: json['votes'] as int?,
      status: json['status'] as String?,
      network: json['network'] as String?,
      genres: (json['genres'] as List?)?.cast<String>() ?? [],
      runtime: json['runtime'] as int?,
      type: type,
      firstAired: json['first_aired'] != null
          ? DateTime.tryParse(json['first_aired'] as String)
          : null,
      trailer: json['trailer'] as String?,
    );
  }
}
