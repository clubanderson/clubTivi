import 'package:equatable/equatable.dart';

/// Represents a TV show or movie from Trakt/TMDB
class VodTitle extends Equatable {
  final int traktId;
  final String? imdbId;
  final int? tmdbId;
  final String title;
  final int? year;
  final String? overview;
  final double? rating;
  final int? votes;
  final String? status; // "returning series", "ended", etc.
  final String? network;
  final List<String> genres;
  final String? posterUrl;
  final String? backdropUrl;
  final String? trailer;
  final int? runtime; // minutes
  final VodTitleType type;
  final DateTime? firstAired;

  const VodTitle({
    required this.traktId,
    this.imdbId,
    this.tmdbId,
    required this.title,
    this.year,
    this.overview,
    this.rating,
    this.votes,
    this.status,
    this.network,
    this.genres = const [],
    this.posterUrl,
    this.backdropUrl,
    this.trailer,
    this.runtime,
    this.type = VodTitleType.series,
    this.firstAired,
  });

  VodTitle copyWith({
    String? imdbId,
    String? posterUrl,
    String? backdropUrl,
    String? overview,
    double? rating,
    int? votes,
    List<String>? genres,
    String? status,
    String? trailer,
  }) {
    return VodTitle(
      traktId: traktId,
      imdbId: imdbId ?? this.imdbId,
      tmdbId: tmdbId,
      title: title,
      year: year,
      overview: overview ?? this.overview,
      rating: rating ?? this.rating,
      votes: votes ?? this.votes,
      status: status ?? this.status,
      network: network,
      genres: genres ?? this.genres,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      trailer: trailer ?? this.trailer,
      runtime: runtime,
      type: type,
      firstAired: firstAired,
    );
  }

  @override
  List<Object?> get props => [traktId, imdbId];
}

enum VodTitleType { series, movie }

/// Represents a season of a TV show
class Season extends Equatable {
  final int number;
  final String? title;
  final String? overview;
  final int? episodeCount;
  final int? airedEpisodes;
  final double? rating;
  final String? posterUrl;
  final DateTime? firstAired;
  final int? traktId;
  final int? tmdbId;

  const Season({
    required this.number,
    this.title,
    this.overview,
    this.episodeCount,
    this.airedEpisodes,
    this.rating,
    this.posterUrl,
    this.firstAired,
    this.traktId,
    this.tmdbId,
  });

  String get displayTitle => title ?? 'Season $number';

  @override
  List<Object?> get props => [number, traktId];
}

/// Represents an episode of a TV show
class Episode extends Equatable {
  final int season;
  final int number;
  final String? title;
  final String? overview;
  final double? rating;
  final int? votes;
  final int? runtime; // minutes
  final DateTime? firstAired;
  final String? stillUrl; // episode screenshot
  final int? traktId;
  final int? tmdbId;

  const Episode({
    required this.season,
    required this.number,
    this.title,
    this.overview,
    this.rating,
    this.votes,
    this.runtime,
    this.firstAired,
    this.stillUrl,
    this.traktId,
    this.tmdbId,
  });

  String get displayTitle => title ?? 'Episode $number';
  String get code => 'S${season.toString().padLeft(2, '0')}E${number.toString().padLeft(2, '0')}';

  @override
  List<Object?> get props => [season, number, traktId];
}

/// Full detail for a VOD title including seasons list
class VodTitleDetail {
  final VodTitle vodTitle;
  final List<Season> seasons;

  const VodTitleDetail({required this.vodTitle, this.seasons = const []});
}

/// A resolved stream link ready for playback
class ResolvedStream extends Equatable {
  final String url;
  final String filename;
  final String? quality; // "1080p", "720p", "4K", etc.
  final int? filesize; // bytes
  final String source; // "real-debrid", "torrent", "Xtream 📺", etc.
  final bool isCached; // instant availability on debrid
  final String? magnetUrl; // for non-cached torrents that need resolving
  final int? seeds;
  final String? providerId; // Xtream provider that owns this stream
  final int? xtreamSeriesId; // Xtream series ID for series-level matches
  final String? language; // Xtream language/country prefix ("EN", "AF-EN")

  const ResolvedStream({
    required this.url,
    required this.filename,
    this.quality,
    this.filesize,
    this.source = 'real-debrid',
    this.isCached = true,
    this.magnetUrl,
    this.seeds,
    this.providerId,
    this.xtreamSeriesId,
    this.language,
  });

  /// Direct-play Xtream source: playable URL, no magnet resolution needed.
  bool get isDirectPlay => magnetUrl == null && url.isNotEmpty;

  /// Xtream source (direct-play or series-level) — shown distinctly in UI.
  bool get isXtream => source.startsWith('Xtream');

  String get filesizeDisplay {
    if (filesize == null) return '';
    final gb = filesize! / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = filesize! / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }

  @override
  List<Object?> get props => [url];
}
