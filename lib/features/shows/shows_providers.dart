import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/datasources/remote/trakt_client.dart';
import '../../data/datasources/remote/tmdb_client.dart';
import '../../data/datasources/remote/debrid_client.dart';
import '../../data/datasources/remote/torrent_search_client.dart';
import '../../data/repositories/shows_repository.dart';
import '../../data/models/show.dart';

// SharedPreferences keys for API credentials
const _kTraktClientId = 'shows_trakt_client_id';
const _kTmdbApiKey = 'shows_tmdb_api_key';
const _kDebridApiToken = 'shows_debrid_api_token';

/// Provider for the shows repository (initialized from saved API keys)
final showsRepositoryProvider = FutureProvider<ShowsRepository>((ref) async {
  final prefs = await SharedPreferences.getInstance();

  final traktId = prefs.getString(_kTraktClientId);
  final tmdbKey = prefs.getString(_kTmdbApiKey);
  final debridToken = prefs.getString(_kDebridApiToken);

  return ShowsRepository(
    trakt: traktId != null && traktId.isNotEmpty
        ? TraktClient(clientId: traktId)
        : null,
    tmdb: tmdbKey != null && tmdbKey.isNotEmpty
        ? TmdbClient(apiKey: tmdbKey)
        : null,
    debrid: debridToken != null && debridToken.isNotEmpty
        ? DebridClient(apiToken: debridToken)
        : null,
    torrentSearch: TorrentSearchClient(),
  );
});

/// Trending shows
final trendingShowsProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getTrendingShows();
});

/// Popular shows
final popularShowsProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getPopularShows();
});

/// Trending movies
final trendingMoviesProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getTrendingMovies();
});

/// Popular movies
final popularMoviesProvider = FutureProvider<List<Show>>((ref) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getPopularMovies();
});

/// Search results
final showSearchQueryProvider = StateProvider<String>((ref) => '');

final showSearchResultsProvider = FutureProvider<List<Show>>((ref) async {
  final query = ref.watch(showSearchQueryProvider);
  if (query.isEmpty) return [];
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.search(query);
});

/// Show detail provider (family — parameterized by trakt ID + type)
final showDetailProvider =
    FutureProvider.family<ShowDetail?, ShowDetailParams>((ref, params) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getShowDetail(params.traktId, type: params.type);
});

class ShowDetailParams {
  final int traktId;
  final ShowType type;
  const ShowDetailParams(this.traktId, {this.type = ShowType.show});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShowDetailParams && traktId == other.traktId && type == other.type;

  @override
  int get hashCode => traktId.hashCode ^ type.hashCode;
}

/// Episodes for a season
final episodesProvider =
    FutureProvider.family<List<Episode>, EpisodeParams>((ref, params) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.getEpisodes(params.traktId, params.season);
});

class EpisodeParams {
  final int traktId;
  final int season;
  const EpisodeParams(this.traktId, this.season);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpisodeParams && traktId == other.traktId && season == other.season;

  @override
  int get hashCode => traktId.hashCode ^ season.hashCode;
}

/// Stream resolution for playback
final resolveStreamProvider =
    FutureProvider.family<List<ResolvedStream>, StreamResolveParams>((ref, params) async {
  final repo = await ref.watch(showsRepositoryProvider.future);
  return repo.resolveStreams(
    imdbId: params.imdbId,
    season: params.season,
    episode: params.episode,
  );
});

class StreamResolveParams {
  final String imdbId;
  final int? season;
  final int? episode;
  const StreamResolveParams(this.imdbId, {this.season, this.episode});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamResolveParams &&
          imdbId == other.imdbId &&
          season == other.season &&
          episode == other.episode;

  @override
  int get hashCode => imdbId.hashCode ^ (season ?? 0).hashCode ^ (episode ?? 0).hashCode;
}

/// API keys configuration state
class ShowsApiKeysNotifier extends StateNotifier<ShowsApiKeys> {
  ShowsApiKeysNotifier() : super(const ShowsApiKeys());

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ShowsApiKeys(
      traktClientId: prefs.getString(_kTraktClientId) ?? '',
      tmdbApiKey: prefs.getString(_kTmdbApiKey) ?? '',
      debridApiToken: prefs.getString(_kDebridApiToken) ?? '',
    );
  }

  Future<void> save({
    required String traktClientId,
    required String tmdbApiKey,
    required String debridApiToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTraktClientId, traktClientId);
    await prefs.setString(_kTmdbApiKey, tmdbApiKey);
    await prefs.setString(_kDebridApiToken, debridApiToken);
    state = ShowsApiKeys(
      traktClientId: traktClientId,
      tmdbApiKey: tmdbApiKey,
      debridApiToken: debridApiToken,
    );
  }
}

class ShowsApiKeys {
  final String traktClientId;
  final String tmdbApiKey;
  final String debridApiToken;

  const ShowsApiKeys({
    this.traktClientId = '',
    this.tmdbApiKey = '',
    this.debridApiToken = '',
  });

  bool get isConfigured =>
      traktClientId.isNotEmpty && tmdbApiKey.isNotEmpty && debridApiToken.isNotEmpty;
  bool get hasTraktKey => traktClientId.isNotEmpty;
  bool get hasTmdbKey => tmdbApiKey.isNotEmpty;
  bool get hasDebridKey => debridApiToken.isNotEmpty;
}

final showsApiKeysProvider =
    StateNotifierProvider<ShowsApiKeysNotifier, ShowsApiKeys>((ref) {
  final notifier = ShowsApiKeysNotifier();
  notifier.load();
  return notifier;
});
