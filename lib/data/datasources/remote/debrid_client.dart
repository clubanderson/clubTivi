import 'package:dio/dio.dart';
import '../../models/show.dart';

/// Client for Real-Debrid API v1.0
/// Docs: https://api.real-debrid.com/
class DebridClient {
  final Dio _dio;
  final String apiToken;

  static const _baseUrl = 'https://api.real-debrid.com/rest/1.0';

  DebridClient({
    required this.apiToken,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers = {
        'Authorization': 'Bearer $apiToken',
      };
  }

  /// Check if torrent hashes are instantly available (cached)
  /// Returns a map of hash → list of available file variants
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};

    final hashStr = hashes.join('/');
    final response = await _dio.get('/torrents/instantAvailability/$hashStr');
    final data = response.data as Map<String, dynamic>;

    final result = <String, List<DebridFile>>{};
    for (final hash in hashes) {
      final hashLower = hash.toLowerCase();
      if (data.containsKey(hashLower)) {
        final hostData = data[hashLower] as Map<String, dynamic>;
        final files = <DebridFile>[];
        for (final host in hostData.values) {
          if (host is List) {
            for (final variant in host) {
              if (variant is Map<String, dynamic>) {
                for (final entry in variant.entries) {
                  final fileInfo = entry.value as Map<String, dynamic>;
                  files.add(DebridFile(
                    id: int.tryParse(entry.key) ?? 0,
                    filename: fileInfo['filename'] as String? ?? '',
                    filesize: fileInfo['filesize'] as int? ?? 0,
                  ));
                }
              }
            }
          }
        }
        if (files.isNotEmpty) {
          result[hashLower] = files;
        }
      }
    }
    return result;
  }

  /// Add a magnet link and return the torrent ID
  Future<String> addMagnet(String magnetLink) async {
    final response = await _dio.post(
      '/torrents/addMagnet',
      data: FormData.fromMap({'magnet': magnetLink}),
    );
    return response.data['id'] as String;
  }

  /// Select files from a torrent for downloading
  Future<void> selectFiles(String torrentId, {String files = 'all'}) async {
    await _dio.post(
      '/torrents/selectFiles/$torrentId',
      data: FormData.fromMap({'files': files}),
    );
  }

  /// Get torrent info including download links
  Future<DebridTorrentInfo> getTorrentInfo(String torrentId) async {
    final response = await _dio.get('/torrents/info/$torrentId');
    return DebridTorrentInfo.fromJson(response.data as Map<String, dynamic>);
  }

  /// Unrestrict a link to get a direct download/stream URL
  Future<ResolvedStream> unrestrictLink(String link) async {
    final response = await _dio.post(
      '/unrestrict/link',
      data: FormData.fromMap({'link': link}),
    );
    final data = response.data as Map<String, dynamic>;
    return ResolvedStream(
      url: data['download'] as String,
      filename: data['filename'] as String? ?? 'unknown',
      filesize: data['filesize'] as int?,
      source: 'real-debrid',
    );
  }

  /// Full flow: add magnet → select files → wait → get stream URL
  Future<ResolvedStream?> resolveFromMagnet(String magnetLink) async {
    final torrentId = await addMagnet(magnetLink);
    await selectFiles(torrentId);

    // Poll until ready (max 30 seconds)
    for (var i = 0; i < 15; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final info = await getTorrentInfo(torrentId);
      if (info.status == 'downloaded' && info.links.isNotEmpty) {
        return unrestrictLink(info.links.first);
      }
      if (info.status == 'error' || info.status == 'dead') {
        return null;
      }
    }
    return null;
  }

  /// Delete a torrent from the user's list
  Future<void> deleteTorrent(String torrentId) async {
    await _dio.delete('/torrents/delete/$torrentId');
  }

  /// Get user account info (to verify API token)
  Future<bool> verifyToken() async {
    try {
      await _dio.get('/user');
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// A file within a cached torrent
class DebridFile {
  final int id;
  final String filename;
  final int filesize;

  const DebridFile({
    required this.id,
    required this.filename,
    required this.filesize,
  });

  String get quality {
    final lower = filename.toLowerCase();
    if (lower.contains('2160p') || lower.contains('4k')) return '4K';
    if (lower.contains('1080p')) return '1080p';
    if (lower.contains('720p')) return '720p';
    if (lower.contains('480p')) return '480p';
    return 'Unknown';
  }

  String get filesizeDisplay {
    final gb = filesize / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
    final mb = filesize / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }
}

/// Torrent info from Real-Debrid
class DebridTorrentInfo {
  final String id;
  final String filename;
  final String status;
  final int progress;
  final List<String> links;

  const DebridTorrentInfo({
    required this.id,
    required this.filename,
    required this.status,
    required this.progress,
    this.links = const [],
  });

  factory DebridTorrentInfo.fromJson(Map<String, dynamic> json) {
    return DebridTorrentInfo(
      id: json['id'] as String,
      filename: json['filename'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      progress: json['progress'] as int? ?? 0,
      links: (json['links'] as List?)?.cast<String>() ?? [],
    );
  }
}
