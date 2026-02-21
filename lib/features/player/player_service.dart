import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Manages video playback with stream failover support.
class PlayerService {
  Player? _player;
  VideoController? _videoController;
  bool _isBuffering = false;
  DateTime? _bufferStartTime;

  /// Buffer stall threshold before triggering failover.
  static const bufferStallThreshold = Duration(seconds: 3);

  Player get player {
    _player ??= Player();
    return _player!;
  }

  VideoController get videoController {
    _videoController ??= VideoController(player);
    return _videoController!;
  }

  /// Start playing a stream URL.
  Future<void> play(String url) async {
    _isBuffering = false;
    _bufferStartTime = null;
    await player.open(Media(url));
    await player.setVolume(100.0);

    // Auto-select first audio track when tracks become available.
    // Some streams don't auto-select audio.
    player.stream.tracks.listen((tracks) {
      if (tracks.audio.length > 1) {
        // Index 0 is usually "no" / auto; pick first real track
        final audioTrack = tracks.audio.length > 1 ? tracks.audio[1] : tracks.audio.first;
        player.setAudioTrack(audioTrack);
      }
    });
  }

  /// Whether audio tracks are available on the current stream.
  Stream<bool> get hasAudioStream =>
      player.stream.tracks.map((t) => t.audio.length > 1);

  /// Number of audio tracks.
  Stream<int> get audioTrackCountStream =>
      player.stream.tracks.map((t) => t.audio.length);

  /// Stop playback.
  Future<void> stop() async {
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

  void dispose() {
    _player?.dispose();
  }
}

/// Riverpod provider for the player service (singleton).
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  ref.onDispose(() => service.dispose());
  return service;
});
