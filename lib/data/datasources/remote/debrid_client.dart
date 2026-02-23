import 'package:dio/dio.dart';
import '../../models/show.dart';
import 'debrid_service.dart';

/// Client for Real-Debrid API v1.0
/// Docs: https://api.real-debrid.com/
class DebridClient implements DebridService {
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

  @override
  String get serviceName => 'Real-Debrid';

  /// Check if torrent hashes are instantly available (cached)
  /// Returns a map of hash → list of available file variants
  @override
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
  @override
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

  /// Full flow: add magnet → select files → wait → get stream URL.
  /// [onProgress] is called with status text during polling.
  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final torrentId = await addMagnet(magnetLink);
    await selectFiles(torrentId);

    // Poll until ready (max 90 seconds — 45 polls × 2s)
    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final info = await getTorrentInfo(torrentId);
      onProgress?.call(info.status, info.progress);
      if (info.status == 'downloaded' && info.links.isNotEmpty) {
        return unrestrictLink(info.links.first);
      }
      if (info.status == 'error' || info.status == 'dead' ||
          info.status == 'magnet_error') {
        throw Exception('Debrid status: ${info.status}');
      }
    }
    throw Exception('Timed out waiting for debrid (90s)');
  }

  /// Get a direct download URL for a magnet without playing it.
  Future<String?> getDownloadUrl(String magnetLink) async {
    final resolved = await resolveFromMagnet(magnetLink);
    return resolved?.url;
  }

  /// Delete a torrent from the user's list
  Future<void> deleteTorrent(String torrentId) async {
    await _dio.delete('/torrents/delete/$torrentId');
  }

  /// Get user account info (to verify API token)
  @override
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

/// Alias so the factory in debrid_service.dart can reference it
typedef RealDebridService = DebridClient;

// ---------------------------------------------------------------------------
// AllDebrid — https://docs.alldebrid.com/
// ---------------------------------------------------------------------------

class AllDebridService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://api.alldebrid.com/v4';
  static const _agent = 'clubTivi';

  AllDebridService({required this.apiToken, Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
  }

  Map<String, String> get _params => {'agent': _agent, 'apikey': apiToken};

  @override
  String get serviceName => 'AllDebrid';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};
    final response = await _dio.get('/magnet/instant', queryParameters: {
      ..._params,
      'magnets[]': hashes,
    });
    final data = response.data['data'] as Map<String, dynamic>? ?? {};
    final magnets = data['magnets'] as List? ?? [];
    final result = <String, List<DebridFile>>{};
    for (final m in magnets) {
      if (m is Map<String, dynamic> && m['instant'] == true) {
        final hash = (m['hash'] as String?)?.toLowerCase() ?? '';
        final files = <DebridFile>[];
        final fileList = m['files'] as List? ?? [];
        for (var i = 0; i < fileList.length; i++) {
          final f = fileList[i];
          if (f is Map<String, dynamic>) {
            files.add(DebridFile(
              id: i,
              filename: f['n'] as String? ?? '',
              filesize: f['s'] as int? ?? 0,
            ));
          }
        }
        if (files.isNotEmpty) result[hash] = files;
      }
    }
    return result;
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    final response = await _dio.get('/link/unlock', queryParameters: {
      ..._params,
      'link': link,
    });
    final data = response.data['data'] as Map<String, dynamic>? ?? {};
    return ResolvedStream(
      url: data['link'] as String? ?? '',
      filename: data['filename'] as String? ?? 'unknown',
      filesize: data['filesize'] as int?,
      source: 'alldebrid',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    // Upload magnet
    final uploadResp = await _dio.get('/magnet/upload', queryParameters: {
      ..._params,
      'magnets[]': [magnetLink],
    });
    final magnets = (uploadResp.data['data']?['magnets'] as List?) ?? [];
    if (magnets.isEmpty) throw Exception('AllDebrid: no magnet created');
    final magnetId = magnets[0]['id'] as int;

    // Poll status
    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final statusResp = await _dio.get('/magnet/status', queryParameters: {
        ..._params,
        'id': magnetId,
      });
      final data = statusResp.data['data']?['magnets'] as Map<String, dynamic>? ?? {};
      final status = data['status'] as String? ?? '';
      final statusCode = data['statusCode'] as int? ?? 0;
      onProgress?.call(status, statusCode == 4 ? 100 : 50);
      if (statusCode == 4) {
        final links = data['links'] as List? ?? [];
        if (links.isNotEmpty) {
          final link = links[0]['link'] as String? ?? '';
          return unrestrictLink(link);
        }
      }
      if (statusCode >= 5) {
        throw Exception('AllDebrid error: $status');
      }
    }
    throw Exception('Timed out waiting for AllDebrid (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      final resp = await _dio.get('/user', queryParameters: _params);
      return resp.data['status'] == 'success';
    } catch (_) {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Premiumize — https://www.premiumize.me/api
// ---------------------------------------------------------------------------

class PremiumizeService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://www.premiumize.me';

  PremiumizeService({required this.apiToken, Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
  }

  Map<String, String> get _params => {'apikey': apiToken};

  @override
  String get serviceName => 'Premiumize';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};
    final response = await _dio.get('/api/cache/check', queryParameters: {
      ..._params,
      'items[]': hashes,
    });
    final data = response.data as Map<String, dynamic>? ?? {};
    final statuses = data['response'] as List? ?? [];
    final result = <String, List<DebridFile>>{};
    for (var i = 0; i < hashes.length && i < statuses.length; i++) {
      if (statuses[i] == true) {
        result[hashes[i].toLowerCase()] = [
          DebridFile(id: 0, filename: 'cached', filesize: 0),
        ];
      }
    }
    return result;
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    // Premiumize uses directdl for magnet/torrent links
    final response = await _dio.post('/api/transfer/directdl',
      data: FormData.fromMap({..._params, 'src': link}),
    );
    final data = response.data as Map<String, dynamic>? ?? {};
    final content = data['content'] as List? ?? [];
    if (content.isEmpty) throw Exception('Premiumize: no content returned');
    final first = content[0] as Map<String, dynamic>;
    return ResolvedStream(
      url: first['link'] as String? ?? '',
      filename: first['path'] as String? ?? 'unknown',
      filesize: (first['size'] as num?)?.toInt(),
      source: 'premiumize',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    // Try direct download first (instant if cached)
    try {
      return await unrestrictLink(magnetLink);
    } catch (_) {}

    // Fall back to transfer creation + polling
    final createResp = await _dio.post('/api/transfer/create',
      data: FormData.fromMap({..._params, 'src': magnetLink}),
    );
    final data = createResp.data as Map<String, dynamic>? ?? {};
    final transferId = data['id'] as String? ?? '';

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final listResp = await _dio.get('/api/transfer/list',
        queryParameters: _params,
      );
      final transfers = (listResp.data['transfers'] as List?) ?? [];
      final transfer = transfers.firstWhere(
        (t) => t['id'] == transferId,
        orElse: () => null,
      );
      if (transfer == null) throw Exception('Premiumize: transfer not found');
      final status = transfer['status'] as String? ?? '';
      final progress = ((transfer['progress'] as num?) ?? 0) * 100;
      onProgress?.call(status, progress.toInt());
      if (status == 'finished') {
        final folderId = transfer['folder_id'] as String?;
        if (folderId != null) {
          final browseResp = await _dio.get('/api/folder/list',
            queryParameters: {..._params, 'id': folderId},
          );
          final content = (browseResp.data['content'] as List?) ?? [];
          if (content.isNotEmpty) {
            final first = content[0] as Map<String, dynamic>;
            return ResolvedStream(
              url: first['link'] as String? ?? '',
              filename: first['name'] as String? ?? 'unknown',
              filesize: (first['size'] as num?)?.toInt(),
              source: 'premiumize',
            );
          }
        }
      }
      if (status == 'error' || status == 'deleted') {
        throw Exception('Premiumize status: $status');
      }
    }
    throw Exception('Timed out waiting for Premiumize (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      final resp = await _dio.get('/api/account/info',
        queryParameters: _params,
      );
      return resp.data['status'] == 'success';
    } catch (_) {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Debrid-Link — https://debrid-link.com/api/v2
// ---------------------------------------------------------------------------

class DebridLinkService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://debrid-link.com/api/v2';

  DebridLinkService({required this.apiToken, Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers = {'Authorization': 'Bearer $apiToken'};
  }

  @override
  String get serviceName => 'Debrid-Link';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};
    final response = await _dio.get('/seedbox/cached',
      queryParameters: {'url': hashes.join(',')},
    );
    final data = response.data as Map<String, dynamic>? ?? {};
    final value = data['value'] as Map<String, dynamic>? ?? {};
    final result = <String, List<DebridFile>>{};
    for (final hash in hashes) {
      final lower = hash.toLowerCase();
      if (value.containsKey(lower) && value[lower] != null) {
        result[lower] = [DebridFile(id: 0, filename: 'cached', filesize: 0)];
      }
    }
    return result;
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    final response = await _dio.post('/downloader/add',
      data: FormData.fromMap({'url': link}),
    );
    final data = response.data as Map<String, dynamic>? ?? {};
    final value = data['value'] as Map<String, dynamic>? ?? {};
    return ResolvedStream(
      url: value['downloadUrl'] as String? ?? '',
      filename: value['filename'] as String? ?? 'unknown',
      filesize: (value['filesize'] as num?)?.toInt(),
      source: 'debrid-link',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final addResp = await _dio.post('/seedbox/add',
      data: FormData.fromMap({'url': magnetLink, 'async': true}),
    );
    final data = addResp.data as Map<String, dynamic>? ?? {};
    final value = data['value'] as Map<String, dynamic>? ?? {};
    final torrentId = value['id'] as String? ?? '';

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final infoResp = await _dio.get('/seedbox/list');
      final list = (infoResp.data['value'] as List?) ?? [];
      final torrent = list.firstWhere(
        (t) => t['id'] == torrentId,
        orElse: () => null,
      );
      if (torrent == null) throw Exception('Debrid-Link: torrent not found');
      final status = torrent['status'] as int? ?? 0;
      onProgress?.call('status:$status', status == 100 ? 100 : 50);
      // status 100 = ready
      if (status == 100) {
        final files = torrent['files'] as List? ?? [];
        if (files.isNotEmpty) {
          final first = files[0] as Map<String, dynamic>;
          final dlUrl = first['downloadUrl'] as String? ?? '';
          if (dlUrl.isNotEmpty) {
            return ResolvedStream(
              url: dlUrl,
              filename: first['name'] as String? ?? 'unknown',
              filesize: (first['size'] as num?)?.toInt(),
              source: 'debrid-link',
            );
          }
        }
      }
      if (status < 0) {
        throw Exception('Debrid-Link error status: $status');
      }
    }
    throw Exception('Timed out waiting for Debrid-Link (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      await _dio.get('/account/infos');
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Offcloud — https://offcloud.com/api
// ---------------------------------------------------------------------------

class OffcloudService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://offcloud.com/api';

  OffcloudService({required this.apiToken, Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers = {'Authorization': apiToken};
  }

  @override
  String get serviceName => 'Offcloud';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    if (hashes.isEmpty) return {};
    final response = await _dio.post('/cache', data: {'hashes': hashes});
    final data = response.data as Map<String, dynamic>? ?? {};
    final cachedItems = data['cachedItems'] as List? ?? [];
    final result = <String, List<DebridFile>>{};
    for (final hash in cachedItems) {
      if (hash is String) {
        result[hash.toLowerCase()] = [
          DebridFile(id: 0, filename: 'cached', filesize: 0),
        ];
      }
    }
    return result;
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    final response = await _dio.post('/cloud', data: {'url': link});
    final data = response.data as Map<String, dynamic>? ?? {};
    return ResolvedStream(
      url: data['url'] as String? ?? '',
      filename: data['fileName'] as String? ?? 'unknown',
      source: 'offcloud',
    );
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final addResp = await _dio.post('/cloud', data: {'url': magnetLink});
    final data = addResp.data as Map<String, dynamic>? ?? {};
    final requestId = data['requestId'] as String? ?? '';
    final directUrl = data['url'] as String?;
    if (directUrl != null && directUrl.isNotEmpty) {
      return ResolvedStream(
        url: directUrl,
        filename: data['fileName'] as String? ?? 'unknown',
        source: 'offcloud',
      );
    }

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final statusResp = await _dio.get('/cloud/status',
        queryParameters: {'requestId': requestId},
      );
      final sData = statusResp.data as Map<String, dynamic>? ?? {};
      final status = sData['status'] as String? ?? '';
      onProgress?.call(status, 50);
      if (status == 'downloaded') {
        final url = sData['url'] as String? ?? '';
        return ResolvedStream(
          url: url,
          filename: sData['fileName'] as String? ?? 'unknown',
          source: 'offcloud',
        );
      }
      if (status == 'error') {
        throw Exception('Offcloud error');
      }
    }
    throw Exception('Timed out waiting for Offcloud (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      await _dio.get('/account/stats');
      return true;
    } catch (_) {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// put.io — https://api.put.io/v2/docs
// ---------------------------------------------------------------------------

class PutioService implements DebridService {
  final Dio _dio;
  final String apiToken;
  static const _baseUrl = 'https://api.put.io/v2';

  PutioService({required this.apiToken, Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers = {'Authorization': 'Bearer $apiToken'};
  }

  @override
  String get serviceName => 'put.io';

  @override
  Future<Map<String, List<DebridFile>>> checkInstantAvailability(
    List<String> hashes,
  ) async {
    // put.io doesn't have a direct cache check — return empty
    return {};
  }

  @override
  Future<ResolvedStream> unrestrictLink(String link) async {
    // put.io uses transfers, not link unrestriction
    final result = await resolveFromMagnet(link);
    if (result == null) throw Exception('put.io: could not resolve link');
    return result;
  }

  @override
  Future<ResolvedStream?> resolveFromMagnet(
    String magnetLink, {
    void Function(String status, int progress)? onProgress,
  }) async {
    final addResp = await _dio.post('/transfers/add',
      data: FormData.fromMap({'url': magnetLink}),
    );
    final transfer = addResp.data['transfer'] as Map<String, dynamic>? ?? {};
    final transferId = transfer['id'] as int? ?? 0;

    for (var i = 0; i < 45; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final infoResp = await _dio.get('/transfers/$transferId');
      final data = infoResp.data['transfer'] as Map<String, dynamic>? ?? {};
      final status = data['status'] as String? ?? '';
      final pct = data['percent_done'] as int? ?? 0;
      onProgress?.call(status, pct);
      if (status == 'COMPLETED' || status == 'SEEDING') {
        final fileId = data['file_id'] as int? ?? 0;
        final url = '$_baseUrl/files/$fileId/download?oauth_token=$apiToken';
        return ResolvedStream(
          url: url,
          filename: data['name'] as String? ?? 'unknown',
          source: 'put.io',
        );
      }
      if (status == 'ERROR') {
        throw Exception('put.io error: ${data['error_message']}');
      }
    }
    throw Exception('Timed out waiting for put.io (90s)');
  }

  @override
  Future<bool> verifyToken() async {
    try {
      await _dio.get('/account/info');
      return true;
    } catch (_) {
      return false;
    }
  }
}
