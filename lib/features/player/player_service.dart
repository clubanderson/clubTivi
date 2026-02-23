import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:media_kit_video/media_kit_video.dart';

import 'adaptive_buffer.dart';
import 'stream_proxy.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../../data/services/stream_health_tracker.dart';

/// Manages video playback with stream failover support.
class PlayerService {
  Player? _player;
  VideoController? _videoController;
  final AdaptiveBufferManager _bufferManager = AdaptiveBufferManager();
  bool _isBuffering = false;
  DateTime? _bufferStartTime;
  StreamSubscription<Tracks>? _tracksSub;

  // Buffer health tracking (persists across info dialog opens)
  final List<bool> bufferHistory = List.filled(60, false, growable: true);
  int bufferEventCount = 0;
  int bufferingSeconds = 0;
  bool _trackingBuffering = false;
  Timer? _bufferTrackTimer;
  StreamSubscription<bool>? _bufferTrackSub;

  /// Buffer stall threshold before triggering failover.
  static const bufferStallThreshold = Duration(seconds: 3);

  // Auto-failover state
  String? _currentUrl;
  String? _currentChannelId;
  String? _currentEpgChannelId;
  String? _currentTvgId;
  String? _currentChannelName;
  String? _currentVanityName;
  String? _currentOriginalName;
  StreamAlternativesService? _alternatives;
  StreamHealthTracker? _healthTracker;
  Timer? _failoverCheckTimer;
  int _consecutiveLowBuffer = 0;
  final StreamProxy _streamProxy = StreamProxy();
  bool _proxyActive = false;

  // ── Warm failover: background pre-buffer player ──
  Player? _warmPlayer;
  String? _warmUrl;
  bool _warmReady = false;
  StreamSubscription<bool>? _warmBufferSub;
  Timer? _warmTimeoutTimer;

  /// Broadcast current stream URL changes (for UI like failover dialog).
  final _currentUrlController = StreamController<String?>.broadcast();
  Stream<String?> get currentUrlStream => _currentUrlController.stream;
  String? get currentUrl => _currentUrl;

  /// Callback invoked when auto-failover switches streams.
  /// Provides the provider name or URL fragment for UI toast.
  void Function(String message)? onFailover;

  /// The channel ID that failover most recently switched to, if available.
  String? lastFailoverChannelId;

  bool _playerReady = false;
  final _playerReadyCompleter = Completer<void>();

  Player get player {
    if (_player == null) {
      _player = Player(
        configuration: const PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
        ),
      );
      _initPlayer(_player!);
    }
    return _player!;
  }

  Future<void> _initPlayer(Player p) async {
    final np = p.platform;
    if (np is native_player.NativePlayer) {
      // Downmix surround to stereo for output compatibility
      await np.setProperty('audio-channels', 'stereo');
      // Normalize volume when downmixing surround to stereo
      await np.setProperty('audio-normalize-downmix', 'yes');
      // EBU R128 loudness normalization — keeps volume consistent across streams
      await np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
      // Disable SPDIF passthrough which can cause silent output
      await np.setProperty('audio-spdif', '');
      // Volume
      await np.setProperty('volume', '100');
      await np.setProperty('mute', 'no');
      // Android TV: enable hardware decoding and optimize buffering
      if (Platform.isAndroid) {
        await np.setProperty('hwdec', 'mediacodec-copy');
        await np.setProperty('vo', 'gpu');
        await np.setProperty('framedrop', 'vo');
      }
    }
    await p.setVolume(100);
    _playerReady = true;
    _playerReadyCompleter.complete();
  }

  /// Wait for player properties to be applied before playback.
  Future<void> _ensureReady() async {
    if (!_playerReady) {
      // Access player to trigger creation if needed
      player; // ignore: unnecessary_statements
      await _playerReadyCompleter.future;
    }
  }

  VideoController get videoController {
    _videoController ??= VideoController(player);
    return _videoController!;
  }

  /// Inject services for auto-failover (call once at startup).
  void configureFailover(StreamAlternativesService alternatives, StreamHealthTracker health) {
    _alternatives = alternatives;
    _healthTracker = health;
  }

  // Failover group override: manual alternatives from user-created groups
  List<String>? _failoverGroupUrls;

  /// Start playing a stream URL with optional channel metadata for failover.
  Future<void> play(String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
    List<String>? failoverGroupUrls,
  }) async {
    _isBuffering = false;
    _bufferStartTime = null;
    _consecutiveLowBuffer = 0;
    _currentUrl = url;
    _currentChannelId = channelId;
    _currentEpgChannelId = epgChannelId;
    _currentTvgId = tvgId;
    _currentChannelName = channelName;
    _currentVanityName = vanityName;
    _currentOriginalName = originalName;
    _failoverGroupUrls = failoverGroupUrls;
    _tracksSub?.cancel();
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _proxyActive = false;
    await _streamProxy.stop();
    await _ensureReady();
    await player.open(Media(url));
    await _bufferManager.applyForStream(url, this);
    await player.setVolume(100.0);

    // Check for missing audio after a brief delay and retry through
    // ffmpeg proxy if needed (fixes EAC-3 with non-standard codec tags)
    _scheduleAudioCheck(url);

    // Reset and start buffer tracking for the new stream
    bufferHistory.fillRange(0, 60, false);
    bufferEventCount = 0;
    bufferingSeconds = 0;
    startBufferTracking();
    _startFailoverMonitor();
  }

  /// Check audio tracks after playback starts; retry through ffmpeg proxy
  /// if no real audio tracks are detected.
  void _scheduleAudioCheck(String originalUrl) {
    _tracksSub?.cancel();
    // Give mpv 3 seconds to detect audio tracks before checking
    _tracksSub = Stream<void>.fromFuture(
      Future<void>.delayed(const Duration(seconds: 3)),
    ).asyncMap((_) => player.state.tracks).listen((tracks) {
      _tracksSub?.cancel();
      if (_proxyActive || _currentUrl != originalUrl) return;

      final realAudio = tracks.audio.where((a) => a.id != 'auto' && a.id != 'no').length;
      if (realAudio > 0) {
        debugPrint('[Player] Audio OK: $realAudio tracks detected');
        return;
      }

      // No real audio detected — try ffmpeg proxy
      debugPrint('[Player] No audio tracks after 3s, trying ffmpeg proxy for $originalUrl');
      _retryWithProxy(originalUrl);
    });
  }

  /// Re-open the stream through the local ffmpeg proxy.
  Future<void> _retryWithProxy(String originalUrl) async {
    if (_proxyActive) return; // Avoid recursive retry
    final proxyUrl = await _streamProxy.start(originalUrl);
    if (proxyUrl == null) {
      debugPrint('[Player] ffmpeg proxy unavailable, keeping direct playback');
      return;
    }
    // Verify the stream URL hasn't changed while we were starting the proxy
    if (_currentUrl != originalUrl) {
      await _streamProxy.stop();
      return;
    }
    _proxyActive = true;
    debugPrint('[Player] Switching to proxied stream: $proxyUrl');
    await player.open(Media(proxyUrl));
    await _bufferManager.applyForStream(originalUrl, this);
    await player.setVolume(100.0);
  }

  /// Whether audio tracks are available on the current stream.
  Stream<bool> get hasAudioStream =>
      player.stream.tracks.map((t) => t.audio.length > 1);

  /// Number of audio tracks.
  Stream<int> get audioTrackCountStream =>
      player.stream.tracks.map((t) => t.audio.length);

  /// Stop playback.
  Future<void> stop() async {
    _bufferManager.stop();
    await player.stop();
  }

  /// Pause playback.
  Future<void> pause() async {
    await player.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    await player.play();
  }

  /// Set volume (0.0 - 100.0).
  Future<void> setVolume(double volume) async {
    await player.setVolume(volume.clamp(0.0, 100.0));
  }

  /// Stream of buffering state changes.
  Stream<bool> get bufferingStream => player.stream.buffering;

  /// Stream of playback position.
  Stream<Duration> get positionStream => player.stream.position;

  /// Stream of duration.
  Stream<Duration> get durationStream => player.stream.duration;

  /// Stream of whether playback is playing.
  Stream<bool> get playingStream => player.stream.playing;

  /// Check if buffer stall exceeds threshold (for failover trigger).
  bool get shouldFailover {
    if (!_isBuffering || _bufferStartTime == null) return false;
    return DateTime.now().difference(_bufferStartTime!) > bufferStallThreshold;
  }

  /// Called when buffering state changes — used by failover engine.
  void onBufferingChanged(bool buffering) {
    if (buffering && !_isBuffering) {
      _isBuffering = true;
      _bufferStartTime = DateTime.now();
    } else if (!buffering) {
      _isBuffering = false;
      _bufferStartTime = null;
    }
  }

  /// Read an mpv property from the underlying native player.
  /// Returns null if unavailable (e.g. on web or before player init).
  Future<String?> getMpvProperty(String name) async {
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      try {
        return await np.getProperty(name);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Take a screenshot via mpv's screenshot-to-file command.
  Future<String?> takeScreenshot(String path) async {
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      try {
        await np.setProperty('screenshot-format', 'png');
        await np.command(['screenshot-to-file', path, 'video']);
        return path;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Current adaptive buffer manager for UI access.
  AdaptiveBufferManager get bufferManager => _bufferManager;

  /// Start tracking buffer events and accumulating buffering time.
  void startBufferTracking() {
    if (_trackingBuffering) return;
    _trackingBuffering = true;

    _bufferTrackSub?.cancel();
    _bufferTrackSub = player.stream.buffering.listen((isBuffering) {
      bufferHistory.removeAt(0);
      bufferHistory.add(isBuffering);
      if (isBuffering && !_isBuffering) bufferEventCount++;
    });

    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (player.state.buffering) bufferingSeconds++;
    });
  }

  // ── Auto-failover monitor ──────────────────────────────────────────────

  void _startFailoverMonitor() {
    _failoverCheckTimer?.cancel();
    _failoverCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_currentUrl == null) return;
      if (_alternatives == null && (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) return;

      final raw = await getMpvProperty('demuxer-cache-duration');
      final cacheSecs = double.tryParse(raw ?? '');
      if (cacheSecs == null) return;

      // Record health sample
      _healthTracker?.recordBufferSample(_currentUrl!, cacheSecs);

      if (cacheSecs < 1.0) {
        _consecutiveLowBuffer++;
        if (_consecutiveLowBuffer >= 2 && !_warmReady && _warmPlayer == null) {
          // 4+ seconds of low buffer → start pre-buffering alternative (warm)
          _startWarmPreload();
        }
        if (_consecutiveLowBuffer >= 3) {
          // 6+ seconds of critically low buffer → failover
          _healthTracker?.recordStall(_currentUrl!);
          await _autoFailover();
        }
      } else {
        _consecutiveLowBuffer = 0;
        // Buffer recovered — dispose warm player if not yet used
        if (_warmPlayer != null && !_warmReady) {
          _disposeWarmPlayer();
        }
      }
    });
  }

  /// Get failover alternative URLs, preferring manual group URLs over auto-detected.
  List<String> _getFailoverAlternatives() {
    if (_currentUrl == null) return [];

    // Prefer manually-defined failover group URLs
    if (_failoverGroupUrls != null && _failoverGroupUrls!.isNotEmpty) {
      return _failoverGroupUrls!
          .where((u) => u != _currentUrl)
          .toList();
    }

    // Fall back to auto-detected alternatives
    if (_alternatives == null) return [];
    return _alternatives!.getAlternatives(
      channelId: _currentChannelId ?? '',
      epgChannelId: _currentEpgChannelId,
      tvgId: _currentTvgId,
      channelName: _currentChannelName,
      vanityName: _currentVanityName,
      originalName: _currentOriginalName,
      excludeUrl: _currentUrl!,
    );
  }

  /// Start pre-buffering the best alternative stream in a hidden player.
  void _startWarmPreload() {
    if (_currentUrl == null) return;

    final alts = _getFailoverAlternatives();
    if (alts.isEmpty) return;

    final warmUrl = alts.first;
    debugPrint('[Failover] Warm pre-buffering: $warmUrl');
    _warmUrl = warmUrl;
    _warmReady = false;

    _warmPlayer = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );

    // Configure warm player: muted, with loudnorm, no video output
    final np = _warmPlayer!.platform;
    if (np is native_player.NativePlayer) {
      np.setProperty('vid', 'no'); // disable video decoding
      np.setProperty('audio-channels', 'stereo');
      np.setProperty('audio-normalize-downmix', 'yes');
      np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
      np.setProperty('volume', '0'); // silent
    }

    // Listen for buffering state — when it stops buffering, stream is ready
    _warmBufferSub?.cancel();
    bool initialBuffering = true;
    _warmBufferSub = _warmPlayer!.stream.buffering.listen((buffering) {
      if (initialBuffering && buffering) return; // still loading
      if (initialBuffering && !buffering) {
        initialBuffering = false;
        _warmReady = true;
        _warmTimeoutTimer?.cancel();
        debugPrint('[Failover] Warm player ready: $_warmUrl');
      }
    });

    _warmPlayer!.open(Media(warmUrl));

    // Timeout: if warm player doesn't become ready in 10s, dispose it
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = Timer(const Duration(seconds: 10), () {
      if (!_warmReady) {
        debugPrint('[Failover] Warm pre-buffer timed out');
        _disposeWarmPlayer();
      }
    });
  }

  /// Dispose the warm pre-buffer player and clean up.
  void _disposeWarmPlayer() {
    _warmBufferSub?.cancel();
    _warmBufferSub = null;
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = null;
    _warmPlayer?.dispose();
    _warmPlayer = null;
    _warmUrl = null;
    _warmReady = false;
  }

  Future<void> _autoFailover() async {
    if (_currentUrl == null) return;
    if (_alternatives == null && (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) return;

    // If warm player is ready, do an instant switch
    if (_warmReady && _warmPlayer != null && _warmUrl != null) {
      debugPrint('[Failover] Instant switch to warm-buffered: $_warmUrl');
      final newUrl = _warmUrl!;
      _consecutiveLowBuffer = 0;
      _failoverCheckTimer?.cancel();

      // Dispose warm player (we'll re-open on main player)
      _disposeWarmPlayer();

      // Switch main player to the pre-buffered URL
      _currentUrl = newUrl;
      _proxyActive = false;
      await _streamProxy.stop();
      await player.open(Media(newUrl));
      await _bufferManager.applyForStream(newUrl, this);
      _startFailoverMonitor();

      _currentUrlController.add(newUrl);
      lastFailoverChannelId = _alternatives?.channelIdForUrl(newUrl);
      onFailover?.call('⚡ Switched stream (warm)');
      return;
    }

    // Cold failover: find best alternative and switch directly
    final alts = _getFailoverAlternatives();

    if (alts.isEmpty) return;

    final newUrl = alts.first;
    _consecutiveLowBuffer = 0;

    // Switch stream (keep channel metadata — it's the same content)
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _currentUrl = newUrl;
    _proxyActive = false;
    await _streamProxy.stop();
    await player.open(Media(newUrl));
    await _bufferManager.applyForStream(newUrl, this);
    _startFailoverMonitor();

    _currentUrlController.add(newUrl);
    lastFailoverChannelId = _alternatives?.channelIdForUrl(newUrl);
    onFailover?.call('⚡ Switched stream');
  }

  void dispose() {
    _bufferManager.stop();
    _tracksSub?.cancel();
    _bufferTrackSub?.cancel();
    _bufferTrackTimer?.cancel();
    _failoverCheckTimer?.cancel();
    _disposeWarmPlayer();
    _healthTracker?.save();
    _streamProxy.stop();
    _player?.dispose();
  }
}

/// Riverpod provider for the player service (singleton).
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  // Inject failover services
  try {
    final alternatives = ref.read(streamAlternativesProvider);
    final health = ref.read(streamHealthTrackerProvider);
    service.configureFailover(alternatives, health);
  } catch (_) {
    // Services may not be available yet — failover will be disabled
  }
  ref.onDispose(() => service.dispose());
  return service;
});
