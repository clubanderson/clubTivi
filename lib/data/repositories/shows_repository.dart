import 'package:logger/logger.dart';
import '../datasources/remote/trakt_client.dart';
import '../datasources/remote/tmdb_client.dart';
import '../datasources/remote/debrid_client.dart';
import '../datasources/remote/torrent_search_client.dart';
import '../models/show.dart';

/// Combines Trakt, TMDB, debrid, and torrent search into a unified shows data source
class ShowsRepository {
  final TraktClient? _trakt;
  final TmdbClient? _tmdb;
  final DebridClient? _debrid;
  final TorrentSearchClient _torrentSearch;
  final _log = Logger(printer: SimplePrinter());

  ShowsRepository({
    TraktClient? trakt,
    TmdbClient? tmdb,
    DebridClient? debrid,
    TorrentSearchClient? torrentSearch,
  })  : _trakt = trakt,
        _tmdb = tmdb,
        _debrid = debrid,
        _torrentSearch = torrentSearch ?? TorrentSearchClient();

  bool get hasTrakt => _trakt != null;
  bool get hasTmdb => _tmdb != null;
  bool get hasDebrid => _debrid != null;

  /// Get trending shows, enriched with TMDB posters
  Future<List<Show>> getTrendingShows({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getTrendingShows(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(await _tmdb.getTrendingTv(page: page), ShowType.show);
    }
    return [];
  }

  /// Get popular shows, enriched with TMDB posters
  Future<List<Show>> getPopularShows({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getPopularShows(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(await _tmdb.getPopularTv(page: page), ShowType.show);
    }
    return [];
  }

  /// Get trending movies, enriched with TMDB posters
  Future<List<Show>> getTrendingMovies({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getTrendingMovies(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(await _tmdb.getTrendingMovie(page: page), ShowType.movie);
    }
    return [];
  }

  /// Get popular movies, enriched with TMDB posters
  Future<List<Show>> getPopularMovies({int page = 1, int limit = 20}) async {
    if (_trakt != null) {
      final shows = await _trakt.getPopularMovies(page: page, limit: limit);
      return _enrichWithTmdb(shows);
    }
    if (_tmdb != null) {
      return _tmdbResultsToShows(await _tmdb.getPopularMovie(page: page), ShowType.movie);
    }
    return [];
  }

  /// Search shows and movies
  Future<List<Show>> search(String query) async {
    if (_trakt != null) {
      final results = await _trakt.search(query);
      return _enrichWithTmdb(results);
    }
    if (_tmdb != null) {
      final tvResults = await _tmdb.searchTv(query);
      final movieResults = await _tmdb.searchMovie(query);
      return [
        ..._tmdbResultsToShows(tvResults, ShowType.show),
        ..._tmdbResultsToShows(movieResults, ShowType.movie),
      ];
    }
    return [];
  }

  /// Get full show detail with seasons
  Future<ShowDetail?> getShowDetail(int traktId, {ShowType type = ShowType.show}) async {
    // Trakt-based detail
    if (_trakt != null) {
      final show = type == ShowType.movie
          ? await _trakt.getMovie(traktId)
          : await _trakt.getShow(traktId);
      final enriched = await _enrichSingle(show);

      List<Season> seasons = [];
      if (type == ShowType.show) {
        seasons = await _trakt.getSeasons(traktId);
        seasons = seasons.where((s) => s.number > 0).toList();
        if (_tmdb != null && enriched.tmdbId != null) {
          seasons = await _enrichSeasons(enriched.tmdbId!, seasons);
        }
      }
      return ShowDetail(show: enriched, seasons: seasons);
    }

    // TMDB-only fallback — traktId is actually tmdbId in this case
    if (_tmdb != null) {
      return _getShowDetailFromTmdb(traktId, type: type);
    }

    return null;
  }

  /// TMDB-only show detail
  Future<ShowDetail?> _getShowDetailFromTmdb(int tmdbId, {ShowType type = ShowType.show}) async {
    if (_tmdb == null) return null;
    try {
      final detail = type == ShowType.movie
          ? await _tmdb.getMovie(tmdbId)
          : await _tmdb.getTvShow(tmdbId);

      _log.i('TMDB detail for $tmdbId: title=${detail.title}, imdb=${detail.imdbId}, seasons=${detail.numberOfSeasons}');

      final show = Show(
        traktId: tmdbId,
        tmdbId: tmdbId,
        imdbId: detail.imdbId,
        title: detail.title,
        posterUrl: detail.posterUrl.isNotEmpty ? detail.posterUrl : null,
        backdropUrl: detail.backdropUrl.isNotEmpty ? detail.backdropUrl : null,
        overview: detail.overview,
        rating: detail.voteAverage,
        votes: detail.voteCount,
        year: detail.year,
        genres: detail.genres,
        type: type,
      );

      // For TV shows, build seasons list from TMDB
      List<Season> seasons = [];
      if (type == ShowType.show) {
        final numSeasons = detail.numberOfSeasons ?? 0;
        _log.i('Fetching $numSeasons seasons for ${detail.title}');
        for (int i = 1; i <= numSeasons; i++) {
          try {
            final tmdbSeason = await _tmdb.getTvSeason(tmdbId, i);
            seasons.add(Season(
              number: i,
              overview: tmdbSeason.overview,
              episodeCount: tmdbSeason.episodes.length,
              airedEpisodes: tmdbSeason.episodes.length,
              posterUrl: tmdbSeason.posterPath != null
                  ? TmdbClient.posterUrl(tmdbSeason.posterPath)
                  : null,
            ));
          } catch (e) {
            _log.w('Failed to fetch season $i for $tmdbId: $e');
            seasons.add(Season(number: i));
          }
        }
      }

      return ShowDetail(show: show, seasons: seasons);
    } catch (e) {
      _log.e('TMDB detail failed for $tmdbId: $e');
      return null;
    }
  }

  /// Get episodes for a season
  Future<List<Episode>> getEpisodes(int traktId, int seasonNumber) async {
    // Trakt-based
    if (_trakt != null) {
      final episodes = await _trakt.getEpisodes(traktId, seasonNumber);
      if (_tmdb != null) {
        try {
          final show = await _trakt.getShow(traktId);
          if (show.tmdbId != null) {
            return _enrichEpisodesWithTmdb(episodes, show.tmdbId!, seasonNumber);
          }
        } catch (_) {}
      }
      return episodes;
    }

    // TMDB-only fallback — traktId is actually tmdbId
    if (_tmdb != null) {
      return _getEpisodesFromTmdb(traktId, seasonNumber);
    }

    return [];
  }

  /// Get episodes directly from TMDB
  Future<List<Episode>> _getEpisodesFromTmdb(int tmdbId, int seasonNumber) async {
    if (_tmdb == null) return [];
    try {
      final tmdbSeason = await _tmdb.getTvSeason(tmdbId, seasonNumber);
      return tmdbSeason.episodes.map((e) => Episode(
        season: seasonNumber,
        number: e.episodeNumber,
        title: e.name,
        overview: e.overview,
        rating: e.voteAverage,
        stillUrl: e.stillUrl.isNotEmpty ? e.stillUrl : null,
        tmdbId: e.episodeNumber,
      )).toList();
    } catch (e) {
      _log.e('TMDB episodes failed for $tmdbId S$seasonNumber: $e');
      return [];
    }
  }

  /// Resolve a stream URL for a show/movie via debrid
  /// Returns sorted list of available streams (best quality first)
  Future<List<ResolvedStream>> resolveStreams({
    required String imdbId,
    int? season,
    int? episode,
  }) async {
    // Step 1: Search for torrent hashes
    List<TorrentResult> torrents;
    if (season != null && episode != null) {
      torrents = await _torrentSearch.searchEpisode(
        imdbId,
        season: season,
        episode: episode,
      );
    } else {
      torrents = await _torrentSearch.searchMovie(imdbId);
    }

    if (torrents.isEmpty) {
      _log.w('No torrents found for $imdbId');
      return [];
    }

    // Sort by quality (best first)
    torrents.sort((a, b) => b.qualityScore.compareTo(a.qualityScore));

    // Step 2: Check instant availability via debrid
    if (_debrid == null) {
      _log.w('No debrid client configured');
      return [];
    }

    final hashes = torrents.map((t) => t.infoHash).toList();
    final available = await _debrid.checkInstantAvailability(hashes);

    if (available.isEmpty) {
      _log.w('No cached torrents found on debrid for $imdbId');
      return [];
    }

    // Step 3: Resolve the best available cached torrent
    final resolved = <ResolvedStream>[];
    for (final torrent in torrents) {
      final hashLower = torrent.infoHash.toLowerCase();
      if (available.containsKey(hashLower)) {
        try {
          final stream = await _debrid.resolveFromMagnet(torrent.magnetUrl);
          if (stream != null) {
            resolved.add(ResolvedStream(
              url: stream.url,
              filename: stream.filename,
              quality: torrent.quality,
              filesize: stream.filesize,
              source: 'real-debrid',
            ));
          }
        } catch (e) {
          _log.e('Failed to resolve torrent ${torrent.infoHash}: $e');
        }
        // Return first 3 best quality options
        if (resolved.length >= 3) break;
      }
    }

    return resolved;
  }

  /// Enrich a list of shows with TMDB poster/backdrop URLs
  Future<List<Show>> _enrichWithTmdb(List<Show> shows) async {
    if (_tmdb == null) return shows;

    final enriched = <Show>[];
    for (final show in shows) {
      enriched.add(await _enrichSingle(show));
    }
    return enriched;
  }

  /// Enrich seasons with TMDB posters/overviews
  Future<List<Season>> _enrichSeasons(int tmdbId, List<Season> seasons) async {
    if (_tmdb == null) return seasons;
    final result = <Season>[];
    for (final season in seasons) {
      try {
        final tmdbSeason = await _tmdb.getTvSeason(tmdbId, season.number);
        result.add(Season(
          number: season.number,
          title: season.title,
          overview: tmdbSeason.overview ?? season.overview,
          episodeCount: season.episodeCount,
          airedEpisodes: season.airedEpisodes,
          rating: season.rating,
          posterUrl: tmdbSeason.posterPath != null
              ? TmdbClient.posterUrl(tmdbSeason.posterPath)
              : null,
          firstAired: season.firstAired,
          traktId: season.traktId,
          tmdbId: season.tmdbId,
        ));
      } catch (_) {
        result.add(season);
      }
    }
    return result;
  }

  /// Enrich Trakt episodes with TMDB stills
  Future<List<Episode>> _enrichEpisodesWithTmdb(
      List<Episode> episodes, int tmdbId, int seasonNumber) async {
    if (_tmdb == null) return episodes;
    try {
      final tmdbSeason = await _tmdb.getTvSeason(tmdbId, seasonNumber);
      final tmdbEpMap = {for (final e in tmdbSeason.episodes) e.episodeNumber: e};
      return episodes.map((ep) {
        final tmdbEp = tmdbEpMap[ep.number];
        if (tmdbEp == null) return ep;
        return Episode(
          season: ep.season,
          number: ep.number,
          title: ep.title ?? tmdbEp.name,
          overview: ep.overview ?? tmdbEp.overview,
          rating: ep.rating,
          votes: ep.votes,
          runtime: ep.runtime,
          firstAired: ep.firstAired,
          stillUrl: tmdbEp.stillUrl.isNotEmpty ? tmdbEp.stillUrl : null,
          traktId: ep.traktId,
          tmdbId: ep.tmdbId,
        );
      }).toList();
    } catch (_) {
      return episodes;
    }
  }

  /// Enrich a single show with TMDB images and IMDB ID
  Future<Show> _enrichSingle(Show show) async {
    if (_tmdb == null || show.tmdbId == null) return show;
    try {
      final detail = show.type == ShowType.movie
          ? await _tmdb.getMovie(show.tmdbId!)
          : await _tmdb.getTvShow(show.tmdbId!);
      return show.copyWith(
        imdbId: detail.imdbId,
        posterUrl: detail.posterUrl.isNotEmpty ? detail.posterUrl : null,
        backdropUrl: detail.backdropUrl.isNotEmpty ? detail.backdropUrl : null,
        overview: show.overview ?? detail.overview,
      );
    } catch (e) {
      _log.w('TMDB enrichment failed for ${show.title}: $e');
      return show;
    }
  }

  /// Convert TMDB search results to Show objects (fallback when Trakt unavailable)
  List<Show> _tmdbResultsToShows(List<TmdbSearchResult> results, ShowType type) {
    return results.map((r) => Show(
      traktId: r.id,
      tmdbId: r.id,
      title: r.displayName,
      year: r.year,
      overview: r.overview,
      rating: r.voteAverage,
      posterUrl: r.posterUrl.isNotEmpty ? r.posterUrl : null,
      backdropUrl: r.backdropUrl.isNotEmpty ? r.backdropUrl : null,
      type: type,
    )).toList();
  }
}
