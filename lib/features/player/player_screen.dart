import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../features/providers/provider_manager.dart' show databaseProvider;
import '../casting/cast_service.dart';
import '../casting/cast_dialog.dart';
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

  // EPG state
  String? _nowPlayingTitle;
  String? _nowPlayingTime;
  String? _nextTitle;
  String? _nextTime;

  @override
  void initState() {
    super.initState();
    _channelIndex = widget.currentIndex;
    _currentChannelName = widget.channelName;
    _currentChannelLogo = widget.channelLogo;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startPlayback();
    _autoHideOverlay();
    _loadEpgInfo();
  }

  Future<void> _loadEpgInfo() async {
    if (widget.channels.isEmpty) return;
    final ch = widget.channels[_channelIndex];
    final epgId = ch['epgId'] as String?;
    if (epgId == null || epgId.isEmpty) {
      if (mounted) {
        setState(() {
          _nowPlayingTitle = null;
          _nowPlayingTime = null;
          _nextTitle = null;
          _nextTime = null;
        });
      }
      return;
    }

    final database = ref.read(databaseProvider);
    final now = DateTime.now();
    final programmes = await database.getProgrammes(
      epgChannelId: epgId,
      start: now.subtract(const Duration(hours: 1)),
      end: now.add(const Duration(hours: 6)),
    );

    if (!mounted) return;

    db.EpgProgramme? current;
    db.EpgProgramme? next;
    for (final p in programmes) {
      if (now.isAfter(p.start) && now.isBefore(p.stop)) {
        current = p;
      } else if (current != null && next == null && now.isBefore(p.start)) {
        next = p;
        break;
      }
    }

    setState(() {
      _nowPlayingTitle = current?.title;
      _nowPlayingTime = current != null
          ? '${_fmtTime(current.start)} – ${_fmtTime(current.stop)}'
          : null;
      _nextTitle = next?.title;
      _nextTime = next != null
          ? '${_fmtTime(next.start)} – ${_fmtTime(next.stop)}'
          : null;
    });
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _startPlayback() {
    final playerService = ref.read(playerServiceProvider);
    final urls = [widget.streamUrl, ...widget.alternativeUrls];

    // If channels list is empty, this is a show/VOD stream — always start fresh
    final isShowStream = widget.channels.isEmpty;

    if (isShowStream ||
        !(playerService.player.state.playing ||
            playerService.player.state.buffering)) {
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

  Future<void> _showCastPicker() async {
    final device = await showCastDialog(context, ref);
    if (device != null && mounted) {
      final castService = ref.read(castServiceProvider);
      final urls = [widget.streamUrl, ...widget.alternativeUrls];
      final success = await castService.castTo(
        device,
        urls[_currentUrlIndex],
        title: widget.channelName,
      );
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Casting to ${device.name}'),
            backgroundColor: Colors.green.shade800,
            duration: const Duration(seconds: 2),
          ),
        );
        setState(() {});
      }
    }
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
    final isAndroid = Platform.isAndroid;

    // Escape / Backspace / Back → exit fullscreen
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack) {
      GoRouter.of(context).canPop()
          ? GoRouter.of(context).pop()
          : GoRouter.of(context).go('/');
      return KeyEventResult.handled;
    }

    // Select / Enter → toggle overlay
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _toggleOverlay();
      return KeyEventResult.handled;
    }

    // Channel switching: use channelUp/Down on Android, arrows elsewhere
    if (key == LogicalKeyboardKey.channelUp ||
        (!isAndroid && key == LogicalKeyboardKey.arrowUp)) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.channelDown ||
        (!isAndroid && key == LogicalKeyboardKey.arrowDown)) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }

    // Volume: only on non-Android (D-pad arrows needed for focus on Android)
    if (!isAndroid && key == LogicalKeyboardKey.arrowLeft) {
      _adjustVolume(-5);
      return KeyEventResult.handled;
    }

    if (!isAndroid && key == LogicalKeyboardKey.arrowRight) {
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
    _loadEpgInfo();
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
                          onPressed: () {
                            GoRouter.of(context).canPop()
                                ? GoRouter.of(context).pop()
                                : GoRouter.of(context).go('/');
                          },
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _currentChannelName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_nowPlayingTitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  '▶ $_nowPlayingTitle${_nowPlayingTime != null ? '  $_nowPlayingTime' : ''}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              if (_nextTitle != null) ...[
                                Text(
                                  'Next: $_nextTitle${_nextTime != null ? '  $_nextTime' : ''}',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
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
                        IconButton(
                          icon: Icon(
                            ref.read(castServiceProvider).isCasting
                                ? Icons.cast_connected_rounded
                                : Icons.cast_rounded,
                            color: ref.read(castServiceProvider).isCasting
                                ? Colors.amber
                                : Colors.white70,
                          ),
                          tooltip: 'Cast to device',
                          onPressed: () => _showCastPicker(),
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
