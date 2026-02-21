import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger(printer: SimplePrinter());

/// Client for LG WebOS TV SSAP protocol over WebSocket (port 3000).
/// Handles pairing, media playback, and basic controls.
class LgWebOsClient {
  final String host;
  final int port;
  WebSocket? _ws;
  String? _clientKey;
  int _msgId = 0;
  final _responses = <String, Completer<Map<String, dynamic>>>{};
  bool _paired = false;
  StreamSubscription? _listenSub;

  static const _prefKeyPrefix = 'lg_webos_key_';

  LgWebOsClient({required this.host, this.port = 3000});

  bool get isConnected => _ws != null && _paired;

  /// Connect to the TV and perform pairing handshake.
  /// Returns true if successfully paired.
  /// The TV will show a pairing prompt on first connection.
  Future<bool> connect({Duration timeout = const Duration(seconds: 15)}) async {
    try {
      // Load saved client key for this TV
      final prefs = await SharedPreferences.getInstance();
      _clientKey = prefs.getString('$_prefKeyPrefix$host');

      _ws = await WebSocket.connect(
        'ws://$host:$port',
      ).timeout(timeout);

      _listenSub = _ws!.listen(
        _onMessage,
        onError: (e) => _log.e('WebOS WS error: $e'),
        onDone: () {
          _paired = false;
          _ws = null;
        },
      );

      // Send registration/pairing request
      final paired = await _register().timeout(
        const Duration(seconds: 12),
        onTimeout: () => false,
      );
      _paired = paired;
      return paired;
    } catch (e) {
      _log.e('WebOS connect failed: $e');
      return false;
    }
  }

  Future<bool> _register() async {
    final completer = Completer<bool>();
    final regId = 'register_0';

    final payload = {
      'type': 'register',
      'id': regId,
      'payload': {
        'pairingType': 'PROMPT',
        if (_clientKey != null) 'client-key': _clientKey,
        'manifest': {
          'appVersion': '1.0',
          'signed': {},
          'permissions': [
            'LAUNCH',
            'LAUNCH_WEBAPP',
            'CONTROL_AUDIO',
            'CONTROL_INPUT_MEDIA_PLAYBACK',
            'READ_RUNNING_APPS',
            'READ_INSTALLED_APPS',
          ],
        },
      },
    };

    // Listen for the registration response
    late StreamSubscription sub;
    sub = _ws!.asBroadcastStream().listen(null); // Won't work — use _responses
    sub.cancel();

    // Use the message handler via _responses
    _responses[regId] = Completer<Map<String, dynamic>>();

    _ws!.add(jsonEncode(payload));

    try {
      final response = await _responses[regId]!.future.timeout(
        const Duration(seconds: 12),
      );
      final key = response['client-key'] as String?;
      if (key != null && key.isNotEmpty) {
        _clientKey = key;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('$_prefKeyPrefix$host', key);
        _log.i('WebOS paired with $host (key saved)');
      }
      completer.complete(true);
    } catch (e) {
      _log.e('WebOS registration timeout or error: $e');
      completer.complete(false);
    }

    return completer.future;
  }

  void _onMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final id = msg['id'] as String?;
      final type = msg['type'] as String?;

      // Handle registration responses
      if (type == 'registered' || type == 'response') {
        final payload = msg['payload'] as Map<String, dynamic>? ?? {};
        if (id != null && _responses.containsKey(id)) {
          _responses[id]!.complete(payload);
          _responses.remove(id);
        }
      } else if (type == 'error') {
        if (id != null && _responses.containsKey(id)) {
          _responses[id]!.completeError(
            Exception(msg['error'] ?? 'Unknown WebOS error'),
          );
          _responses.remove(id);
        }
      }
    } catch (e) {
      _log.e('WebOS parse error: $e');
    }
  }

  /// Send an SSAP request and return the response payload.
  Future<Map<String, dynamic>> _request(
    String uri, [
    Map<String, dynamic>? payload,
  ]) async {
    if (_ws == null) throw Exception('Not connected to WebOS TV');

    final id = 'msg_${++_msgId}';
    final msg = {
      'type': 'request',
      'id': id,
      'uri': uri,
      if (payload != null) 'payload': payload,
    };

    final completer = Completer<Map<String, dynamic>>();
    _responses[id] = completer;
    _ws!.add(jsonEncode(msg));

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _responses.remove(id);
        throw TimeoutException('WebOS request timed out: $uri');
      },
    );
  }

  /// Open a video URL in the TV's browser (most reliable method).
  Future<void> openInBrowser(String url) async {
    await _request('ssap://system.launcher/open', {
      'target': url,
    });
  }

  /// Play a video URL using the TV's media viewer (better for direct streams).
  Future<void> playMedia(String url, {String title = '', String mediaType = 'video/mp4'}) async {
    try {
      await _request('ssap://media.viewer/open', {
        'url': url,
        'title': title,
        'description': '',
        'mimeType': mediaType,
        'loop': false,
      });
    } catch (_) {
      // Fallback to browser if media.viewer not supported
      await openInBrowser(url);
    }
  }

  /// Pause playback.
  Future<void> pause() async {
    await _request('ssap://media.controls/pause');
  }

  /// Resume playback.
  Future<void> play() async {
    await _request('ssap://media.controls/play');
  }

  /// Stop playback.
  Future<void> stop() async {
    await _request('ssap://media.controls/stop');
  }

  /// Set volume (0-100).
  Future<void> setVolume(int vol) async {
    await _request('ssap://audio/setVolume', {'volume': vol.clamp(0, 100)});
  }

  /// Get current volume.
  Future<int> getVolume() async {
    final res = await _request('ssap://audio/getVolume');
    return res['volume'] as int? ?? 0;
  }

  /// Mute/unmute.
  Future<void> setMute(bool mute) async {
    await _request('ssap://audio/setMute', {'mute': mute});
  }

  /// Get TV info (model, name).
  Future<Map<String, dynamic>> getSystemInfo() async {
    return _request('ssap://system/getSystemInfo');
  }

  /// Disconnect from the TV.
  Future<void> disconnect() async {
    _listenSub?.cancel();
    _listenSub = null;
    await _ws?.close();
    _ws = null;
    _paired = false;
    _responses.clear();
  }

  /// Probe a host to check if it's an LG WebOS TV (tries WS on port 3000).
  static Future<bool> probe(String host, {Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final ws = await WebSocket.connect('ws://$host:3000').timeout(timeout);
      await ws.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
