import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_service.dart';

/// Full-screen video player with overlay controls and keyboard navigation.
class PlayerScreen extends ConsumerStatefulWidget {
  final String streamUrl;
  final String channelName;
  final String? channelLogo;
  final List<String> alternativeUrls;
  final List<Map<String, dynamic>> channels;
  final int currentIndex;

  const PlayerScreen({
    super.key,
    required this.streamUrl,
    required this.channelName,
    this.channelLogo,
    this.alternativeUrls = const [],
    this.channels = const [],
    this.currentIndex = 0,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  bool _showOverlay = true;
  int _currentUrlIndex = 0;

  // Channel switching state
  late int _channelIndex;
  late String _currentChannelName;
  late String? _currentChannelLogo;

  // Volume state
  double _volume = 100.0;
  bool _showVolumeOverlay = false;
  Timer? _volumeTimer;

  // Overlay timer
  Timer? _overlayTimer;

  @override
  void initState() {
    super.initState();
    _channelIndex = widget.currentIndex;
    _currentChannelName = widget.channelName;
    _currentChannelLogo = widget.channelLogo;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startPlayback();
    _autoHideOverlay();
  }

  void _startPlayback() {
    final playerService = ref.read(playerServiceProvider);

    // Only start playback if not already playing (preview already started it)
    if (!(playerService.player.state.playing ||
        playerService.player.state.buffering)) {
      final urls = [widget.streamUrl, ...widget.alternativeUrls];
      playerService.play(urls[_currentUrlIndex]);
    }

    playerService.bufferingStream.listen((buffering) {
      playerService.onBufferingChanged(buffering);
      if (playerService.shouldFailover && _hasAlternativeStreams) {
        _switchToNextStream();
      }
    });
  }

  bool get _hasAlternativeStreams {
    final urls = [widget.streamUrl, ...widget.alternativeUrls];
    return _currentUrlIndex < urls.length - 1;
  }

  void _switchToNextStream() {
    setState(() => _currentUrlIndex++);
    final urls = [widget.streamUrl, ...widget.alternativeUrls];
    ref.read(playerServiceProvider).play(urls[_currentUrlIndex]);
  }

  void _autoHideOverlay() {
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) _autoHideOverlay();
  }

  // ---- Keyboard controls ----

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Escape / Backspace → exit fullscreen
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    // Up arrow → previous channel
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.channelUp) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    // Down arrow → next channel
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.channelDown) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }

    // Left arrow → volume down
    if (key == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    // Right arrow → volume up
    if (key == LogicalKeyboardKey.arrowRight) {
      _adjustVolume(5);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _switchChannel(int delta) {
    if (widget.channels.isEmpty) return;
    setState(() {
      _channelIndex =
          (_channelIndex + delta) % widget.channels.length;
      if (_channelIndex < 0) _channelIndex += widget.channels.length;
      final ch = widget.channels[_channelIndex];
      _currentChannelName = ch['name'] as String? ?? '';
      _currentChannelLogo = ch['tvgLogo'] as String?;
      _currentUrlIndex = 0;
      _showOverlay = true;
    });
    final ch = widget.channels[_channelIndex];
    ref.read(playerServiceProvider).play(ch['streamUrl'] as String? ?? '');
    _autoHideOverlay();
  }

  void _adjustVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 100.0);
      _showVolumeOverlay = true;
    });
    ref.read(playerServiceProvider).setVolume(_volume);
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolumeOverlay = false);
    });
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _volumeTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerService = ref.watch(playerServiceProvider);

    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _toggleOverlay,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Video — fill entire screen
              Video(controller: playerService.videoController),

              // Overlay
              if (_showOverlay) ...[
                // Top bar: channel info + ESC hint
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white, size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 4),
                        if (_currentChannelLogo != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Image.network(
                              _currentChannelLogo!,
                              width: 24,
                              height: 24,
                              errorBuilder: (c, e, s) =>
                                  const SizedBox(),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            _currentChannelName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // ESC exit hint
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'ESC',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom bar: controls
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        StreamBuilder<bool>(
                          stream: playerService.playingStream,
                          builder: (context, snapshot) {
                            final playing = snapshot.data ?? false;
                            return IconButton(
                              iconSize: 48,
                              icon: Icon(
                                playing
                                    ? Icons.pause_circle
                                    : Icons.play_circle,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                if (playing) {
                                  playerService.pause();
                                } else {
                                  playerService.resume();
                                }
                              },
                            );
                          },
                        ),
                        if (_hasAlternativeStreams)
                          IconButton(
                            icon: const Icon(
                              Icons.swap_horiz_rounded,
                              color: Colors.white70,
                            ),
                            tooltip: 'Switch stream',
                            onPressed: _switchToNextStream,
                          ),
                      ],
                    ),
                  ),
                ),
              ],

              // Volume overlay
              if (_showVolumeOverlay)
                Positioned(
                  top: 80,
                  right: 24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _volume == 0
                              ? Icons.volume_off
                              : _volume < 50
                                  ? Icons.volume_down
                                  : Icons.volume_up,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_volume.round()}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
