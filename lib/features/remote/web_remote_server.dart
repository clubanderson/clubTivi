import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/feature_gate.dart';
import '../remote/input_manager.dart';

/// Web-based companion remote control server.
///
/// Pro feature. Serves a lightweight HTML/JS remote control UI that any
/// phone browser can open (zero install). Connected via WebSocket.
///
/// Discovery: mDNS (_clubtivi._tcp) on the local network.
/// Security: 4-digit PIN pairing displayed on TV.
class WebRemoteServer {
  static const int defaultPort = 8090;

  final void Function(AppAction action) onAction;
  final int port;

  dynamic _server; // HttpServer
  String? _pin;
  final Set<WebSocketChannel> _clients = {};
  final StreamController<int> _clientCountController =
      StreamController<int>.broadcast();

  WebRemoteServer({
    required this.onAction,
    this.port = defaultPort,
  });

  String? get pin => _pin;
  int get clientCount => _clients.length;
  Stream<int> get clientCountStream => _clientCountController.stream;

  /// Start the remote server.
  Future<void> start() async {
    if (!FeatureGate.webRemote) {
      throw WebRemoteProException();
    }

    _pin = _generatePin();

    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addHandler(_router);

    _server = await shelf_io.serve(handler, '0.0.0.0', port);
  }

  /// Stop the server.
  Future<void> stop() async {
    for (final client in _clients) {
      await client.sink.close();
    }
    _clients.clear();
    await (_server as dynamic)?.close();
    _server = null;
    _pin = null;
    _clientCountController.add(0);
  }

  FutureOr<shelf.Response> _router(shelf.Request request) {
    if (request.url.path == '' || request.url.path == '/') {
      return shelf.Response.ok(_remoteHtml, headers: {
        'content-type': 'text/html',
      });
    }

    if (request.url.path == 'ws') {
      final wsHandler = webSocketHandler((WebSocketChannel channel) {
        _handleWebSocket(channel);
      });
      return wsHandler(request);
    }

    return shelf.Response.notFound('Not found');
  }

  void _handleWebSocket(WebSocketChannel channel) {
    bool authenticated = false;

    channel.stream.listen(
      (message) {
        final data = jsonDecode(message as String) as Map<String, dynamic>;
        final type = data['type'] as String?;

        if (type == 'auth') {
          if (data['pin'] == _pin) {
            authenticated = true;
            _clients.add(channel);
            _clientCountController.add(_clients.length);
            channel.sink.add(jsonEncode({'type': 'auth_ok'}));
          } else {
            channel.sink.add(jsonEncode({'type': 'auth_fail'}));
          }
          return;
        }

        if (!authenticated) {
          channel.sink.add(jsonEncode({'type': 'auth_required'}));
          return;
        }

        if (type == 'action') {
          final actionName = data['action'] as String?;
          final action = _parseAction(actionName);
          if (action != null) onAction(action);
        }
      },
      onDone: () {
        _clients.remove(channel);
        _clientCountController.add(_clients.length);
      },
    );
  }

  AppAction? _parseAction(String? name) {
    if (name == null) return null;
    try {
      return AppAction.values.byName(name);
    } catch (_) {
      return null;
    }
  }

  String _generatePin() {
    final rng = Random.secure();
    return List.generate(4, (_) => rng.nextInt(10)).join();
  }

  /// Send a state update to all connected clients.
  void broadcast(Map<String, dynamic> data) {
    final msg = jsonEncode(data);
    for (final client in _clients) {
      client.sink.add(msg);
    }
  }

  bool get isRunning => _server != null;

  void dispose() {
    stop();
    _clientCountController.close();
  }

  /// Embedded HTML/JS for the remote control UI — served to phone browsers.
  static const _remoteHtml = '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<title>clubTivi Remote</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, system-ui, sans-serif; background: #0a0a0f; color: white; height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; }
  .pin-screen { display: flex; flex-direction: column; align-items: center; gap: 16px; }
  .pin-screen input { font-size: 32px; text-align: center; width: 160px; background: #1a1a2e; border: 2px solid #6c5ce7; border-radius: 12px; color: white; padding: 12px; letter-spacing: 8px; }
  .pin-screen button { padding: 12px 32px; font-size: 16px; background: #6c5ce7; border: none; border-radius: 8px; color: white; cursor: pointer; }
  .remote { display: none; flex-direction: column; align-items: center; gap: 12px; padding: 20px; width: 100%; max-width: 320px; }
  .remote.active { display: flex; }
  .dpad { display: grid; grid-template: 60px 60px 60px / 60px 60px 60px; gap: 4px; }
  .dpad button { background: #1a1a2e; border: 1px solid #333; border-radius: 8px; color: white; font-size: 20px; cursor: pointer; display: flex; align-items: center; justify-content: center; }
  .dpad button:active { background: #6c5ce7; }
  .dpad .center { background: #6c5ce7; border-color: #6c5ce7; }
  .controls { display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
  .controls button { padding: 10px 16px; background: #1a1a2e; border: 1px solid #333; border-radius: 8px; color: white; font-size: 14px; cursor: pointer; }
  .controls button:active { background: #6c5ce7; }
  h2 { font-size: 18px; color: #6c5ce7; }
  .status { font-size: 11px; color: #666; }
</style>
</head>
<body>
<div class="pin-screen" id="pinScreen">
  <h2>clubTivi Remote</h2>
  <p style="color:#888;font-size:14px">Enter PIN shown on TV</p>
  <input id="pinInput" type="tel" maxlength="4" placeholder="----" autofocus>
  <button onclick="auth()">Connect</button>
  <p class="status" id="pinStatus"></p>
</div>
<div class="remote" id="remote">
  <h2>clubTivi</h2>
  <div class="dpad">
    <div></div>
    <button onclick="send('navigateUp')">▲</button>
    <div></div>
    <button onclick="send('navigateLeft')">◀</button>
    <button class="center" onclick="send('select')">OK</button>
    <button onclick="send('navigateRight')">▶</button>
    <div></div>
    <button onclick="send('navigateDown')">▼</button>
    <div></div>
  </div>
  <div class="controls">
    <button onclick="send('back')">← Back</button>
    <button onclick="send('channelUp')">CH+</button>
    <button onclick="send('channelDown')">CH-</button>
    <button onclick="send('volumeUp')">Vol+</button>
    <button onclick="send('volumeDown')">Vol-</button>
    <button onclick="send('mute')">🔇</button>
    <button onclick="send('playPause')">⏯</button>
    <button onclick="send('openGuide')">📺 Guide</button>
    <button onclick="send('toggleFavorite')">⭐</button>
    <button onclick="send('showInfo')">ℹ Info</button>
  </div>
  <p class="status" id="status">Connected</p>
</div>
<script>
let ws;
function auth() {
  const pin = document.getElementById('pinInput').value;
  ws = new WebSocket('ws://' + location.host + '/ws');
  ws.onopen = () => ws.send(JSON.stringify({type:'auth', pin}));
  ws.onmessage = (e) => {
    const d = JSON.parse(e.data);
    if (d.type === 'auth_ok') {
      document.getElementById('pinScreen').style.display = 'none';
      document.getElementById('remote').classList.add('active');
    } else if (d.type === 'auth_fail') {
      document.getElementById('pinStatus').textContent = 'Wrong PIN';
    }
  };
  ws.onclose = () => document.getElementById('status').textContent = 'Disconnected';
}
function send(action) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify({type:'action', action}));
}
</script>
</body>
</html>
''';
}

class WebRemoteProException implements Exception {
  @override
  String toString() => 'Web Remote requires clubTivi Pro.';
}

/// Riverpod provider.
final webRemoteServerProvider = Provider<WebRemoteServer>((ref) {
  final server = WebRemoteServer(
    onAction: (action) {
      // Will be wired to InputManager in the app shell
    },
  );
  ref.onDispose(() => server.dispose());
  return server;
});
