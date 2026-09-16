import 'package:equatable/equatable.dart';
import 'channel.dart';

enum VodType { movie, series }

/// Represents a VOD movie or series from an IPTV provider (e.g. Xtream Codes or M3U).
///
/// Distinct from live TV channels, VOD items represent on-demand media with
/// stream URLs, container extensions, ratings, and series metadata.
class VodItem extends Equatable {
  final String id;
  final String providerId;
  final int? streamId;
  final String name;
  final VodType type;
  final String? streamUrl;
  final String? containerExtension;
  final String? posterUrl;
  final String? categoryId;
  final String? category;
  final double? rating;
  final double? rating5based;
  final String? tmdb;
  final String? trailer;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;

  const VodItem({
    required this.id,
    required this.providerId,
    this.streamId,
    required this.name,
    required this.type,
    this.streamUrl,
    this.containerExtension,
    this.posterUrl,
    this.categoryId,
    this.category,
    this.rating,
    this.rating5based,
    this.tmdb,
    this.trailer,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
  });

  bool get isMovie => type == VodType.movie;
  bool get isSeries => type == VodType.series;

  /// Build a VodItem from an Xtream Codes VOD (movie) stream JSON object.
  factory VodItem.fromXtreamVod({
    required Map<String, dynamic> json,
    required String providerId,
    required String baseUrl,
    required String username,
    required String password,
  }) {
    final rawStreamId = json['stream_id'];
    final streamId = rawStreamId is int ? rawStreamId : int.tryParse('$rawStreamId');
    final ext = json['container_extension'] as String? ?? 'mp4';
    final streamUrl = streamId != null
        ? '$baseUrl/movie/$username/$password/$streamId.$ext'
        : null;

    final rawRating = json['rating'];
    final rating = rawRating is num
        ? rawRating.toDouble()
        : double.tryParse('${rawRating ?? ''}');

    final rawRating5 = json['rating_5based'];
    final rating5based = rawRating5 is num
        ? rawRating5.toDouble()
        : double.tryParse('${rawRating5 ?? ''}');

    return VodItem(
      id: '${providerId}_vod_$streamId',
      providerId: providerId,
      streamId: streamId,
      name: json['name'] as String? ?? 'Unknown',
      type: VodType.movie,
      streamUrl: streamUrl,
      containerExtension: ext,
      posterUrl: json['stream_icon'] as String?,
      categoryId: json['category_id']?.toString(),
      category: json['category_name'] as String?,
      rating: rating,
      rating5based: rating5based,
      tmdb: json['tmdb']?.toString(),
      trailer: json['trailer'] as String?,
      plot: json['plot'] as String?,
      cast: json['cast'] as String?,
      director: json['director'] as String?,
      genre: json['genre'] as String?,
      releaseDate: json['releaseDate']?.toString(),
    );
  }

  /// Build a VodItem from an Xtream Codes Series stream JSON object.
  factory VodItem.fromXtreamSeries({
    required Map<String, dynamic> json,
    required String providerId,
  }) {
    final rawSeriesId = json['series_id'];
    final seriesId = rawSeriesId is int ? rawSeriesId : int.tryParse('$rawSeriesId');

    final rawRating = json['rating'];
    final rating = rawRating is num
        ? rawRating.toDouble()
        : double.tryParse('${rawRating ?? ''}');

    final rawRating5 = json['rating_5based'];
    final rating5based = rawRating5 is num
        ? rawRating5.toDouble()
        : double.tryParse('${rawRating5 ?? ''}');

    return VodItem(
      id: '${providerId}_series_$seriesId',
      providerId: providerId,
      streamId: seriesId,
      name: json['name'] as String? ?? 'Unknown',
      type: VodType.series,
      streamUrl: null, // Series streams are looked up by season and episode
      containerExtension: null,
      posterUrl: json['cover'] as String?,
      categoryId: json['category_id']?.toString(),
      category: json['category_name'] as String?,
      rating: rating,
      rating5based: rating5based,
      tmdb: json['tmdb']?.toString(),
      trailer: (json['youtube_trailer'] ?? json['trailer']) as String?,
      plot: json['plot'] as String?,
      cast: json['cast'] as String?,
      director: json['director'] as String?,
      genre: json['genre'] as String?,
      releaseDate: json['releaseDate']?.toString(),
    );
  }

  /// Build a VodItem from an M3U Channel entry that was detected as VOD or series.
  factory VodItem.fromM3u(Channel channel) {
    return VodItem(
      id: channel.id,
      providerId: channel.providerId,
      name: channel.name,
      type: channel.streamType == StreamType.series ? VodType.series : VodType.movie,
      streamUrl: channel.streamUrl,
      posterUrl: channel.tvgLogo,
      category: channel.groupTitle,
    );
  }

  VodItem copyWith({
    String? name,
    String? streamUrl,
    String? posterUrl,
    String? categoryId,
    String? category,
    double? rating,
    String? plot,
  }) {
    return VodItem(
      id: id,
      providerId: providerId,
      streamId: streamId,
      name: name ?? this.name,
      type: type,
      streamUrl: streamUrl ?? this.streamUrl,
      containerExtension: containerExtension,
      posterUrl: posterUrl ?? this.posterUrl,
      categoryId: categoryId ?? this.categoryId,
      category: category ?? this.category,
      rating: rating ?? this.rating,
      rating5based: rating5based,
      tmdb: tmdb,
      trailer: trailer,
      plot: plot ?? this.plot,
      cast: cast,
      director: director,
      genre: genre,
      releaseDate: releaseDate,
    );
  }

  @override
  List<Object?> get props => [id, providerId, type];
}
