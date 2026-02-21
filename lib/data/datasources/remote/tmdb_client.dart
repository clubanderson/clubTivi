import 'package:dio/dio.dart';

/// Client for The Movie Database (TMDB) API v3
/// Docs: https://developer.themoviedb.org/docs
class TmdbClient {
  final Dio _dio;
  final String apiKey;

  static const _baseUrl = 'https://api.themoviedb.org/3';
  static const _imageBase = 'https://image.tmdb.org/t/p';

  TmdbClient({
    required this.apiKey,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 15);
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.queryParameters['api_key'] = apiKey;
        handler.next(options);
      },
    ));
  }

  /// Build a full image URL from a TMDB file path
  static String imageUrl(String? path, {String size = 'w500'}) {
    if (path == null || path.isEmpty) return '';
    return '$_imageBase/$size$path';
  }

  /// Get poster URL (w500)
  static String posterUrl(String? path) => imageUrl(path, size: 'w500');

  /// Get backdrop URL (w1280)
  static String backdropUrl(String? path) => imageUrl(path, size: 'w1280');

  /// Get still/screenshot URL (w300)
  static String stillUrl(String? path) => imageUrl(path, size: 'w300');

  /// Get TV show details including images
  Future<TmdbShowDetail> getTvShow(int tmdbId) async {
    final response = await _dio.get('/tv/$tmdbId');
    return TmdbShowDetail.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get movie details including images
  Future<TmdbShowDetail> getMovie(int tmdbId) async {
    final response = await _dio.get('/movie/$tmdbId');
    return TmdbShowDetail.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get TV season details with episode list
  Future<TmdbSeasonDetail> getTvSeason(int tmdbId, int seasonNumber) async {
    final response = await _dio.get('/tv/$tmdbId/season/$seasonNumber');
    return TmdbSeasonDetail.fromJson(response.data as Map<String, dynamic>);
  }

  /// Search for TV shows
  Future<List<TmdbSearchResult>> searchTv(String query) async {
    final response = await _dio.get(
      '/search/tv',
      queryParameters: {'query': query},
    );
    final results = response.data['results'] as List;
    return results
        .map((e) => TmdbSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Search for movies
  Future<List<TmdbSearchResult>> searchMovie(String query) async {
    final response = await _dio.get(
      '/search/movie',
      queryParameters: {'query': query},
    );
    final results = response.data['results'] as List;
    return results
        .map((e) => TmdbSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get trending TV shows (day or week)
  Future<List<TmdbSearchResult>> getTrendingTv({String window = 'day', int page = 1}) async {
    final response = await _dio.get(
      '/trending/tv/$window',
      queryParameters: {'page': page},
    );
    final results = response.data['results'] as List;
    return results
        .map((e) => TmdbSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get trending movies (day or week)
  Future<List<TmdbSearchResult>> getTrendingMovie({String window = 'day', int page = 1}) async {
    final response = await _dio.get(
      '/trending/movie/$window',
      queryParameters: {'page': page},
    );
    final results = response.data['results'] as List;
    return results
        .map((e) => TmdbSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get popular TV shows
  Future<List<TmdbSearchResult>> getPopularTv({int page = 1}) async {
    final response = await _dio.get(
      '/tv/popular',
      queryParameters: {'page': page},
    );
    final results = response.data['results'] as List;
    return results
        .map((e) => TmdbSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get popular movies
  Future<List<TmdbSearchResult>> getPopularMovie({int page = 1}) async {
    final response = await _dio.get(
      '/movie/popular',
      queryParameters: {'page': page},
    );
    final results = response.data['results'] as List;
    return results
        .map((e) => TmdbSearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Find by external ID (e.g., IMDB ID)
  Future<TmdbShowDetail?> findByImdbId(String imdbId, {bool isMovie = false}) async {
    final response = await _dio.get(
      '/find/$imdbId',
      queryParameters: {'external_source': 'imdb_id'},
    );
    final key = isMovie ? 'movie_results' : 'tv_results';
    final results = response.data[key] as List;
    if (results.isEmpty) return null;
    return TmdbShowDetail.fromJson(results.first as Map<String, dynamic>);
  }
}

/// TMDB show/movie detail with image paths
class TmdbShowDetail {
  final int id;
  final String? posterPath;
  final String? backdropPath;
  final String? overview;
  final double? voteAverage;
  final int? voteCount;
  final List<String> genres;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;

  const TmdbShowDetail({
    required this.id,
    this.posterPath,
    this.backdropPath,
    this.overview,
    this.voteAverage,
    this.voteCount,
    this.genres = const [],
    this.numberOfSeasons,
    this.numberOfEpisodes,
  });

  String get posterUrl => TmdbClient.posterUrl(posterPath);
  String get backdropUrl => TmdbClient.backdropUrl(backdropPath);

  factory TmdbShowDetail.fromJson(Map<String, dynamic> json) {
    return TmdbShowDetail(
      id: json['id'] as int,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: json['overview'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble(),
      voteCount: json['vote_count'] as int?,
      genres: (json['genres'] as List?)
              ?.map((g) => (g as Map<String, dynamic>)['name'] as String)
              .toList() ??
          [],
      numberOfSeasons: json['number_of_seasons'] as int?,
      numberOfEpisodes: json['number_of_episodes'] as int?,
    );
  }
}

/// TMDB season detail with episodes
class TmdbSeasonDetail {
  final int seasonNumber;
  final String? posterPath;
  final String? overview;
  final List<TmdbEpisode> episodes;

  const TmdbSeasonDetail({
    required this.seasonNumber,
    this.posterPath,
    this.overview,
    this.episodes = const [],
  });

  factory TmdbSeasonDetail.fromJson(Map<String, dynamic> json) {
    return TmdbSeasonDetail(
      seasonNumber: json['season_number'] as int,
      posterPath: json['poster_path'] as String?,
      overview: json['overview'] as String?,
      episodes: (json['episodes'] as List?)
              ?.map((e) => TmdbEpisode.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// A single TMDB episode
class TmdbEpisode {
  final int episodeNumber;
  final int seasonNumber;
  final String? name;
  final String? overview;
  final String? stillPath;
  final double? voteAverage;
  final String? airDate;

  const TmdbEpisode({
    required this.episodeNumber,
    required this.seasonNumber,
    this.name,
    this.overview,
    this.stillPath,
    this.voteAverage,
    this.airDate,
  });

  String get stillUrl => TmdbClient.stillUrl(stillPath);

  factory TmdbEpisode.fromJson(Map<String, dynamic> json) {
    return TmdbEpisode(
      episodeNumber: json['episode_number'] as int,
      seasonNumber: json['season_number'] as int,
      name: json['name'] as String?,
      overview: json['overview'] as String?,
      stillPath: json['still_path'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble(),
      airDate: json['air_date'] as String?,
    );
  }
}

/// TMDB search result
class TmdbSearchResult {
  final int id;
  final String? name;
  final String? title;
  final String? posterPath;
  final String? backdropPath;
  final String? overview;
  final double? voteAverage;
  final String? firstAirDate;
  final String? releaseDate;

  const TmdbSearchResult({
    required this.id,
    this.name,
    this.title,
    this.posterPath,
    this.backdropPath,
    this.overview,
    this.voteAverage,
    this.firstAirDate,
    this.releaseDate,
  });

  String get displayName => name ?? title ?? 'Unknown';
  String get posterUrl => TmdbClient.posterUrl(posterPath);
  String get backdropUrl => TmdbClient.backdropUrl(backdropPath);

  int? get year {
    final date = firstAirDate ?? releaseDate;
    if (date == null || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }

  factory TmdbSearchResult.fromJson(Map<String, dynamic> json) {
    return TmdbSearchResult(
      id: json['id'] as int,
      name: json['name'] as String?,
      title: json['title'] as String?,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: json['overview'] as String?,
      voteAverage: (json['vote_average'] as num?)?.toDouble(),
      firstAirDate: json['first_air_date'] as String?,
      releaseDate: json['release_date'] as String?,
    );
  }
}
