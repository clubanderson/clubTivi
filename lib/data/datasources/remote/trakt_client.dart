import 'package:dio/dio.dart';
import '../../models/show.dart';

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

  /// Get trending TV shows
  Future<List<Show>> getTrendingShows({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/shows/trending',
      queryParameters: {
        'page': page,
        'limit': limit,
        'extended': 'full',
      },
    );
    return (response.data as List).map((e) {
      final show = e['show'] as Map<String, dynamic>;
      return _showFromTrakt(show);
    }).toList();
  }

  /// Get popular TV shows
  Future<List<Show>> getPopularShows({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/shows/popular',
      queryParameters: {
        'page': page,
        'limit': limit,
        'extended': 'full',
      },
    );
    return (response.data as List).map((e) {
      return _showFromTrakt(e as Map<String, dynamic>);
    }).toList();
  }

  /// Get trending movies
  Future<List<Show>> getTrendingMovies({int page = 1, int limit = 20}) async {
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
      return _showFromTrakt(movie, type: ShowType.movie);
    }).toList();
  }

  /// Get popular movies
  Future<List<Show>> getPopularMovies({int page = 1, int limit = 20}) async {
    final response = await _dio.get(
      '/movies/popular',
      queryParameters: {
        'page': page,
        'limit': limit,
        'extended': 'full',
      },
    );
    return (response.data as List).map((e) {
      return _showFromTrakt(e as Map<String, dynamic>, type: ShowType.movie);
    }).toList();
  }

  /// Search for shows and movies
  Future<List<Show>> search(String query, {String type = 'show,movie'}) async {
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
      return _showFromTrakt(
        item,
        type: itemType == 'movie' ? ShowType.movie : ShowType.show,
      );
    }).toList();
  }

  /// Get seasons for a show
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

  /// Get show details by Trakt ID
  Future<Show> getShow(int traktId) async {
    final response = await _dio.get(
      '/shows/$traktId',
      queryParameters: {'extended': 'full'},
    );
    return _showFromTrakt(response.data as Map<String, dynamic>);
  }

  /// Get movie details by Trakt ID
  Future<Show> getMovie(int traktId) async {
    final response = await _dio.get(
      '/movies/$traktId',
      queryParameters: {'extended': 'full'},
    );
    return _showFromTrakt(
      response.data as Map<String, dynamic>,
      type: ShowType.movie,
    );
  }

  Show _showFromTrakt(Map<String, dynamic> json, {ShowType type = ShowType.show}) {
    final ids = json['ids'] as Map<String, dynamic>? ?? {};
    return Show(
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
