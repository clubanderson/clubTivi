import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Proxies an MPEG-TS stream through system ffmpeg to fix codec detection.
///
/// media_kit's bundled FFmpeg cannot detect EAC-3 audio with non-standard
/// MPEG-TS codec tag 0x0087. System ffmpeg (7.x) handles this correctly.
/// This proxy pipes the stream through system ffmpeg with `-c copy` (no
/// transcoding) and serves it on a local HTTP port for mpv to play.
class StreamProxy {
  HttpServer? _server;
  Process? _ffmpeg;
  String? _activeUrl;
  int? _port;
  final List<HttpResponse> _clients = [];

  /// Whether the proxy is currently running.
  bool get isRunning => _server != null;

  /// The local URL to play from, or null if not running.
  String? get localUrl => _port != null ? 'http://127.0.0.1:$_port/' : null;

  /// Start proxying a remote stream URL.
  /// Returns the local URL that mpv should play from.
  Future<String?> start(String remoteUrl) async {
    // Stop any existing proxy
    await stop();

    // Check if ffmpeg is available
    final ffmpegPath = await _findFfmpeg();
    if (ffmpegPath == null) {
      debugPrint('[StreamProxy] ffmpeg not found on system');
      return null;
    }

    try {
      // Start local HTTP server on a random port
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _activeUrl = remoteUrl;

      // Start ffmpeg: read remote stream, copy codecs, output mpegts to stdout
      _ffmpeg = await Process.start(ffmpegPath, [
        '-hide_banner',
        '-loglevel', 'warning',
        '-reconnect', '1',
        '-reconnect_streamed', '1',
        '-reconnect_delay_max', '5',
        '-i', remoteUrl,
        '-c', 'copy',
        '-f', 'mpegts',
        'pipe:1',
      ]);

      // Log ffmpeg stderr for debugging
      _ffmpeg!.stderr.transform(const SystemEncoding().decoder).listen((line) {
        if (line.trim().isNotEmpty) {
          debugPrint('[StreamProxy] ffmpeg: ${line.trim()}');
        }
      });

      // Handle ffmpeg exit
      _ffmpeg!.exitCode.then((code) {
        if (code != 0 && _activeUrl != null) {
          debugPrint('[StreamProxy] ffmpeg exited with code $code');
        }
      });

      // Serve ffmpeg stdout to HTTP clients.
      // Buffer data so late-connecting clients get stream headers.
      final dataBuffer = <List<int>>[];
      const maxBufferChunks = 64; // ~12MB of buffered MPEG-TS data
      final broadcast = _ffmpeg!.stdout.asBroadcastStream();

      // Collect initial data into buffer
      broadcast.listen((data) {
        dataBuffer.add(data);
        if (dataBuffer.length > maxBufferChunks) {
          dataBuffer.removeAt(0);
        }
      });

      _server!.listen((request) {
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.headers.set('Connection', 'close');
        request.response.bufferOutput = false;
        _clients.add(request.response);

        // Send buffered data first so client gets stream headers
        for (final chunk in dataBuffer) {
          try {
            request.response.add(chunk);
          } catch (_) {}
        }

        final sub = broadcast.listen(
          (data) {
            try {
              request.response.add(data);
            } catch (_) {}
          },
          onDone: () {
            try {
              request.response.close();
            } catch (_) {}
            _clients.remove(request.response);
          },
          onError: (_) {
            try {
              request.response.close();
            } catch (_) {}
            _clients.remove(request.response);
          },
          cancelOnError: true,
        );

        request.response.done.then((_) {
          sub.cancel();
          _clients.remove(request.response);
        }).catchError((_) {
          sub.cancel();
          _clients.remove(request.response);
        });
      });

      // Wait briefly for ffmpeg to start producing data
      await Future<void>.delayed(const Duration(seconds: 1));

      debugPrint('[StreamProxy] Started on port $_port for $remoteUrl');
      return localUrl;
    } catch (e) {
      debugPrint('[StreamProxy] Failed to start: $e');
      await stop();
      return null;
    }
  }

  /// Stop the proxy and clean up.
  Future<void> stop() async {
    _activeUrl = null;
    _port = null;

    // Close HTTP clients
    for (final client in _clients) {
      try {
        client.close();
      } catch (_) {}
    }
    _clients.clear();

    // Kill ffmpeg
    if (_ffmpeg != null) {
      try {
        _ffmpeg!.kill(ProcessSignal.sigterm);
      } catch (_) {}
      _ffmpeg = null;
    }

    // Close HTTP server
    if (_server != null) {
      try {
        await _server!.close(force: true);
      } catch (_) {}
      _server = null;
    }
  }

  /// Find ffmpeg binary on the system.
  static Future<String?> _findFfmpeg() async {
    // Check common locations
    const paths = [
      '/opt/homebrew/bin/ffmpeg',  // macOS Apple Silicon
      '/usr/local/bin/ffmpeg',      // macOS Intel / Linux
      '/usr/bin/ffmpeg',            // Linux system
    ];

    for (final path in paths) {
      if (await File(path).exists()) return path;
    }

    // Try PATH lookup
    try {
      final result = await Process.run('which', ['ffmpeg']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
    } catch (_) {}

    return null;
  }
}
