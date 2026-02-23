import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:media_kit_video/media_kit_video.dart';

import 'adaptive_buffer.dart';
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

  /// Callback invoked when auto-failover switches streams.
  /// Provides the provider name or URL fragment for UI toast.
  void Function(String message)? onFailover;

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
      // Exclude only eac3/ac3 AudioToolbox decoders which silently fail
      // on surround streams — keep aac_at since most streams use AAC fine
      await np.setProperty('ad', '-ac3_at,-eac3_at');
      // Allow non-standard codec tags (e.g. 0x0087 for EAC-3 in MPEG-TS)
      await np.setProperty('ad-lavc-o', 'strict=-2');
      // Give the demuxer enough data to detect non-standard audio codecs
      await np.setProperty('demuxer-lavf-probesize', '5000000');
      await np.setProperty('demuxer-lavf-analyzeduration', '5');
      // Downmix surround to stereo for output compatibility
      await np.setProperty('audio-channels', 'stereo');
      // Normalize volume when downmixing surround to stereo
      await np.setProperty('audio-normalize-downmix', 'yes');
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

  /// Start playing a stream URL with optional channel metadata for failover.
  Future<void> play(String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
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
    _tracksSub?.cancel();
    _failoverCheckTimer?.cancel();
    await _ensureReady();
    await player.open(Media(url));
    await _bufferManager.applyForStream(url, this);
    await player.setVolume(100.0);

    // Reset and start buffer tracking for the new stream
    bufferHistory.fillRange(0, 60, false);
    bufferEventCount = 0;
    bufferingSeconds = 0;
    startBufferTracking();
    _startFailoverMonitor();
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

  /// Current stream URL for external reference.
  String? get currentUrl => _currentUrl;

  // ── Auto-failover monitor ──────────────────────────────────────────────

  void _startFailoverMonitor() {
    _failoverCheckTimer?.cancel();
    _failoverCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_alternatives == null || _currentUrl == null) return;

      final raw = await getMpvProperty('demuxer-cache-duration');
      final cacheSecs = double.tryParse(raw ?? '');
      if (cacheSecs == null) return;

      // Record health sample
      _healthTracker?.recordBufferSample(_currentUrl!, cacheSecs);

      if (cacheSecs < 1.0) {
        _consecutiveLowBuffer++;
        if (_consecutiveLowBuffer >= 3) {
          // 6+ seconds of critically low buffer → failover
          _healthTracker?.recordStall(_currentUrl!);
          await _autoFailover();
        }
      } else {
        _consecutiveLowBuffer = 0;
      }
    });
  }

  Future<void> _autoFailover() async {
    if (_alternatives == null || _currentUrl == null) return;

    final alts = _alternatives!.getAlternatives(
      channelId: _currentChannelId ?? '',
      epgChannelId: _currentEpgChannelId,
      tvgId: _currentTvgId,
      channelName: _currentChannelName,
      vanityName: _currentVanityName,
      originalName: _currentOriginalName,
      excludeUrl: _currentUrl!,
    );

    if (alts.isEmpty) return;

    final newUrl = alts.first;
    _consecutiveLowBuffer = 0;

    // Switch stream (keep channel metadata — it's the same content)
    _failoverCheckTimer?.cancel();
    _currentUrl = newUrl;
    await player.open(Media(newUrl));
    await _bufferManager.applyForStream(newUrl, this);
    await player.setVolume(100.0);
    _startFailoverMonitor();

    onFailover?.call('⚡ Switched stream');
  }

  void dispose() {
    _bufferManager.stop();
    _tracksSub?.cancel();
    _bufferTrackSub?.cancel();
    _bufferTrackTimer?.cancel();
    _failoverCheckTimer?.cancel();
    _healthTracker?.save();
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
