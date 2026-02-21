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
    if (_trakt == null) return null;

    final show = type == ShowType.movie
        ? await _trakt.getMovie(traktId)
        : await _trakt.getShow(traktId);

    // Enrich with TMDB images
    final enriched = await _enrichSingle(show);

    // Get seasons (only for shows)
    List<Season> seasons = [];
    if (type == ShowType.show) {
      seasons = await _trakt.getSeasons(traktId);
      // Filter out specials (season 0) by default
      seasons = seasons.where((s) => s.number > 0).toList();

      // Enrich seasons with TMDB posters
      if (_tmdb != null && enriched.tmdbId != null) {
        for (var i = 0; i < seasons.length; i++) {
          try {
            final tmdbSeason = await _tmdb.getTvSeason(enriched.tmdbId!, seasons[i].number);
            seasons[i] = Season(
              number: seasons[i].number,
              title: seasons[i].title,
              overview: tmdbSeason.overview ?? seasons[i].overview,
              episodeCount: seasons[i].episodeCount,
              airedEpisodes: seasons[i].airedEpisodes,
              rating: seasons[i].rating,
              posterUrl: tmdbSeason.posterPath != null
                  ? TmdbClient.posterUrl(tmdbSeason.posterPath)
                  : null,
              firstAired: seasons[i].firstAired,
              traktId: seasons[i].traktId,
              tmdbId: seasons[i].tmdbId,
            );
          } catch (_) {
            // TMDB enrichment failed; keep Trakt data
          }
        }
      }
    }

    return ShowDetail(show: enriched, seasons: seasons);
  }

  /// Get episodes for a season
  Future<List<Episode>> getEpisodes(int traktId, int seasonNumber) async {
    if (_trakt == null) return [];
    final episodes = await _trakt.getEpisodes(traktId, seasonNumber);

    // Enrich with TMDB stills
    if (_tmdb != null) {
      // We need the TMDB ID — look it up from the show
      try {
        final show = await _trakt.getShow(traktId);
        if (show.tmdbId != null) {
          final tmdbSeason = await _tmdb.getTvSeason(show.tmdbId!, seasonNumber);
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
        }
      } catch (_) {
        // TMDB enrichment failed; return Trakt data
      }
    }

    return episodes;
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

  /// Enrich a single show with TMDB images
  Future<Show> _enrichSingle(Show show) async {
    if (_tmdb == null || show.tmdbId == null) return show;
    try {
      final detail = show.type == ShowType.movie
          ? await _tmdb.getMovie(show.tmdbId!)
          : await _tmdb.getTvShow(show.tmdbId!);
      return show.copyWith(
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
