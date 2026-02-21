import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'player_service.dart';

/// Full-screen video player with overlay controls.
class PlayerScreen extends ConsumerStatefulWidget {
  final String streamUrl;
  final String channelName;
  final String? channelLogo;
  final List<String> alternativeUrls;

  const PlayerScreen({
    super.key,
    required this.streamUrl,
    required this.channelName,
    this.channelLogo,
    this.alternativeUrls = const [],
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  bool _showOverlay = true;
  int _currentUrlIndex = 0;

  @override
  void initState() {
    super.initState();
    // Immersive mode for TV
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startPlayback();
    _autoHideOverlay();
  }

  void _startPlayback() {
    final playerService = ref.read(playerServiceProvider);
    final urls = [widget.streamUrl, ...widget.alternativeUrls];
    playerService.play(urls[_currentUrlIndex]);

    // Monitor buffering for failover
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
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showOverlay = false);
    });
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) _autoHideOverlay();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerService = ref.watch(playerServiceProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleOverlay,
        child: Stack(
          children: [
            // Video
            Center(
              child: Video(controller: playerService.videoController),
            ),

            // Overlay
            if (_showOverlay) ...[
              // Top bar: channel info
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
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
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 8),
                      if (widget.channelLogo != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Image.network(
                            widget.channelLogo!,
                            width: 32,
                            height: 32,
                            errorBuilder: (c, e, s) => const SizedBox(),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          widget.channelName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
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
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
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
                              playing ? Icons.pause_circle : Icons.play_circle,
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
          ],
        ),
      ),
    );
  }
}
