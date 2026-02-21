import 'package:dio/dio.dart';

/// Searches for torrent hashes by IMDB ID using the Torrentio addon API
/// Torrentio is a Stremio addon that aggregates torrent sources
/// This only uses the public addon API (no Stremio dependency)
class TorrentSearchClient {
  final Dio _dio;

  static const _torrentioBase = 'https://torrentio.strem.fun';

  TorrentSearchClient({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 15);
  }

  /// Search for streams by IMDB ID (for movies)
  Future<List<TorrentResult>> searchMovie(String imdbId) async {
    return _search('movie', imdbId);
  }

  /// Search for streams by IMDB ID + season + episode (for TV shows)
  Future<List<TorrentResult>> searchEpisode(
    String imdbId, {
    required int season,
    required int episode,
  }) async {
    return _search('series', '$imdbId:$season:$episode');
  }

  Future<List<TorrentResult>> _search(String type, String id) async {
    try {
      final response = await _dio.get('$_torrentioBase/stream/$type/$id.json');
      final data = response.data as Map<String, dynamic>;
      final streams = data['streams'] as List? ?? [];

      return streams.map((s) {
        final stream = s as Map<String, dynamic>;
        final title = stream['title'] as String? ?? '';
        final name = stream['name'] as String? ?? '';

        // Extract info hash from the infoHash field or magnet URL
        String? infoHash = stream['infoHash'] as String?;
        if (infoHash == null) {
          final url = stream['url'] as String? ?? '';
          final hashMatch = RegExp(r'btih:([a-fA-F0-9]{40})').firstMatch(url);
          infoHash = hashMatch?.group(1);
        }

        return TorrentResult(
          title: title,
          name: name,
          infoHash: infoHash ?? '',
          quality: _extractQuality(title),
          filesize: _extractFilesize(title),
          seeds: _extractSeeds(title),
          magnetUrl: _buildMagnet(infoHash ?? '', name),
        );
      }).where((r) => r.infoHash.isNotEmpty).toList();
    } catch (e) {
      // Torrentio may be unavailable; return empty list
      return [];
    }
  }

  String _extractQuality(String title) {
    if (title.contains('2160p') || title.contains('4K')) return '4K';
    if (title.contains('1080p')) return '1080p';
    if (title.contains('720p')) return '720p';
    if (title.contains('480p')) return '480p';
    return '';
  }

  String? _extractFilesize(String title) {
    final match = RegExp(r'(\d+\.?\d*)\s*(GB|MB)', caseSensitive: false).firstMatch(title);
    return match?.group(0);
  }

  int? _extractSeeds(String title) {
    final match = RegExp(r'👤\s*(\d+)').firstMatch(title);
    if (match != null) return int.tryParse(match.group(1)!);
    return null;
  }

  String _buildMagnet(String hash, String name) {
    final encoded = Uri.encodeComponent(name);
    return 'magnet:?xt=urn:btih:$hash&dn=$encoded';
  }
}

/// A torrent search result with hash for debrid lookup
class TorrentResult {
  final String title;
  final String name;
  final String infoHash;
  final String quality;
  final String? filesize;
  final int? seeds;
  final String magnetUrl;

  const TorrentResult({
    required this.title,
    required this.name,
    required this.infoHash,
    this.quality = '',
    this.filesize,
    this.seeds,
    required this.magnetUrl,
  });

  /// Sort quality: 4K > 1080p > 720p > unknown
  int get qualityScore {
    switch (quality) {
      case '4K':
        return 4;
      case '1080p':
        return 3;
      case '720p':
        return 2;
      case '480p':
        return 1;
      default:
        return 0;
    }
  }
}
