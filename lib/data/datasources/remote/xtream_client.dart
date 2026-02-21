import 'package:dio/dio.dart';
import '../../models/channel.dart';

/// Xtream Codes API client.
///
/// Supports both Xtream Codes and XUI APIs which share the same player_api.php
/// endpoint structure. Handles authentication, category/stream listing,
/// EPG retrieval, and VOD/series catalogs.
class XtreamClient {
  final Dio _dio;
  final String baseUrl;
  final String username;
  final String password;

  XtreamClient({
    required this.baseUrl,
    required this.username,
    required this.password,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30);
  }

  String get _apiBase => '$baseUrl/player_api.php';

  Map<String, String> get _authParams => {
        'username': username,
        'password': password,
      };

  /// Authenticate and get server info + account status.
  Future<XtreamServerInfo> authenticate() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: _authParams,
    );
    return XtreamServerInfo.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get live stream categories.
  Future<List<XtreamCategory>> getLiveCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_live_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get all live streams, optionally filtered by category.
  Future<List<Channel>> getLiveStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final params = {..._authParams, 'action': 'get_live_streams'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return _channelFromXtream(json, providerId);
    }).toList();
  }

  /// Get VOD categories.
  Future<List<XtreamCategory>> getVodCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_vod_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get VOD streams, optionally filtered by category.
  Future<List<Channel>> getVodStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final params = {..._authParams, 'action': 'get_vod_streams'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return _vodFromXtream(json, providerId);
    }).toList();
  }

  /// Get series categories.
  Future<List<XtreamCategory>> getSeriesCategories() async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {..._authParams, 'action': 'get_series_categories'},
    );
    return (response.data as List)
        .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get series list.
  Future<List<Channel>> getSeriesStreams({
    String? categoryId,
    required String providerId,
  }) async {
    final params = {..._authParams, 'action': 'get_series'};
    if (categoryId != null) params['category_id'] = categoryId;

    final response = await _dio.get(_apiBase, queryParameters: params);
    return (response.data as List).map((e) {
      final json = e as Map<String, dynamic>;
      return _seriesFromXtream(json, providerId);
    }).toList();
  }

  /// Get short EPG for a specific stream (current + next few programs).
  Future<List<XtreamEpgEntry>> getShortEpg(String streamId) async {
    final response = await _dio.get(
      _apiBase,
      queryParameters: {
        ..._authParams,
        'action': 'get_short_epg',
        'stream_id': streamId,
      },
    );
    final data = response.data as Map<String, dynamic>;
    final listings = data['epg_listings'] as List? ?? [];
    return listings
        .map((e) => XtreamEpgEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Build a live stream URL.
  String buildLiveUrl(int streamId, {String extension = 'ts'}) {
    return '$baseUrl/live/$username/$password/$streamId.$extension';
  }

  /// Build a VOD stream URL.
  String buildVodUrl(int streamId, {String extension = 'mp4'}) {
    return '$baseUrl/movie/$username/$password/$streamId.$extension';
  }

  Channel _channelFromXtream(Map<String, dynamic> json, String providerId) {
    final streamId = json['stream_id'];
    final num = json['num'] is int ? json['num'] as int : int.tryParse('${json['num']}');

    return Channel(
      id: '${providerId}_$streamId',
      providerId: providerId,
      name: json['name'] as String? ?? 'Unknown',
      tvgId: json['epg_channel_id'] as String?,
      tvgName: json['name'] as String?,
      tvgLogo: json['stream_icon'] as String?,
      groupTitle: json['category_name'] as String?,
      channelNumber: num,
      streamUrl: buildLiveUrl(streamId as int),
      streamType: StreamType.live,
    );
  }

  Channel _vodFromXtream(Map<String, dynamic> json, String providerId) {
    final streamId = json['stream_id'];
    final ext = json['container_extension'] as String? ?? 'mp4';

    return Channel(
      id: '${providerId}_vod_$streamId',
      providerId: providerId,
      name: json['name'] as String? ?? 'Unknown',
      tvgLogo: json['stream_icon'] as String?,
      groupTitle: json['category_name'] as String?,
      streamUrl: buildVodUrl(streamId as int, extension: ext),
      streamType: StreamType.vod,
    );
  }

  Channel _seriesFromXtream(Map<String, dynamic> json, String providerId) {
    final seriesId = json['series_id'];

    return Channel(
      id: '${providerId}_series_$seriesId',
      providerId: providerId,
      name: json['name'] as String? ?? 'Unknown',
      tvgLogo: json['cover'] as String?,
      groupTitle: json['category_name'] as String?,
      streamUrl: '', // Series need episode lookup
      streamType: StreamType.series,
    );
  }

  void dispose() {
    _dio.close();
  }
}

/// Server info returned by authentication.
class XtreamServerInfo {
  final String? url;
  final String? port;
  final String? httpsPort;
  final String? serverProtocol;
  final String? status;
  final DateTime? expDate;
  final int? maxConnections;
  final int? activeCons;
  final bool isTrial;

  const XtreamServerInfo({
    this.url,
    this.port,
    this.httpsPort,
    this.serverProtocol,
    this.status,
    this.expDate,
    this.maxConnections,
    this.activeCons,
    this.isTrial = false,
  });

  bool get isActive => status == 'Active';

  factory XtreamServerInfo.fromJson(Map<String, dynamic> json) {
    final userInfo = json['user_info'] as Map<String, dynamic>? ?? {};
    final serverInfo = json['server_info'] as Map<String, dynamic>? ?? {};

    DateTime? expDate;
    final exp = userInfo['exp_date'];
    if (exp != null && exp != '' && exp != 'null') {
      expDate = DateTime.fromMillisecondsSinceEpoch(
        int.parse(exp.toString()) * 1000,
      );
    }

    return XtreamServerInfo(
      url: serverInfo['url'] as String?,
      port: serverInfo['port']?.toString(),
      httpsPort: serverInfo['https_port']?.toString(),
      serverProtocol: serverInfo['server_protocol'] as String?,
      status: userInfo['status'] as String?,
      expDate: expDate,
      maxConnections: int.tryParse('${userInfo['max_connections']}'),
      activeCons: int.tryParse('${userInfo['active_cons']}'),
      isTrial: userInfo['is_trial'] == '1',
    );
  }
}

/// Xtream category (live, VOD, or series).
class XtreamCategory {
  final String id;
  final String name;
  final int? parentId;

  const XtreamCategory({
    required this.id,
    required this.name,
    this.parentId,
  });

  factory XtreamCategory.fromJson(Map<String, dynamic> json) {
    return XtreamCategory(
      id: json['category_id']?.toString() ?? '',
      name: json['category_name'] as String? ?? '',
      parentId: int.tryParse('${json['parent_id']}'),
    );
  }
}

/// Single EPG entry from Xtream short EPG.
class XtreamEpgEntry {
  final String title;
  final String description;
  final DateTime? start;
  final DateTime? end;

  const XtreamEpgEntry({
    required this.title,
    this.description = '',
    this.start,
    this.end,
  });

  factory XtreamEpgEntry.fromJson(Map<String, dynamic> json) {
    return XtreamEpgEntry(
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      start: DateTime.tryParse(json['start'] as String? ?? ''),
      end: DateTime.tryParse(json['end'] as String? ?? ''),
    );
  }
}
