import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Multi-view player — shows 1-9 streams in a flexible grid.
/// Free feature. Tap a cell to focus audio; long-press to fullscreen.
class MultiViewScreen extends ConsumerStatefulWidget {
  final List<MultiViewChannel> channels;

  const MultiViewScreen({super.key, required this.channels});

  @override
  ConsumerState<MultiViewScreen> createState() => _MultiViewScreenState();
}

class _MultiViewScreenState extends ConsumerState<MultiViewScreen> {
  final List<_StreamCell> _cells = [];
  int _audioFocusIndex = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initPlayers();
  }

  void _initPlayers() {
    for (var i = 0; i < widget.channels.length && i < 9; i++) {
      final player = Player();
      final controller = VideoController(player);
      _cells.add(_StreamCell(
        player: player,
        controller: controller,
        channel: widget.channels[i],
      ));
      // Mute all except the focused one
      player.setVolume(i == _audioFocusIndex ? 100.0 : 0.0);
      player.open(Media(widget.channels[i].url));
    }
  }

  void _setAudioFocus(int index) {
    setState(() => _audioFocusIndex = index);
    for (var i = 0; i < _cells.length; i++) {
      _cells[i].player.setVolume(i == index ? 100.0 : 0.0);
    }
  }

  int get _gridColumns {
    final count = _cells.length;
    if (count <= 1) return 1;
    if (count <= 4) return 2;
    return 3;
  }

  int get _gridRows => (_cells.length / _gridColumns).ceil();

  @override
  void dispose() {
    for (final cell in _cells) {
      cell.player.dispose();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Column(
            children: List.generate(_gridRows, (row) {
              return Expanded(
                child: Row(
                  children: List.generate(_gridColumns, (col) {
                    final index = row * _gridColumns + col;
                    if (index >= _cells.length) {
                      return const Expanded(child: SizedBox());
                    }
                    final cell = _cells[index];
                    final hasFocus = index == _audioFocusIndex;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => _setAudioFocus(index),
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: hasFocus
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white10,
                              width: hasFocus ? 2 : 0.5,
                            ),
                          ),
                          child: Stack(
                            children: [
                              Video(controller: cell.controller),
                              // Channel label
                              Positioned(
                                left: 4,
                                bottom: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    cell.channel.name,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                              // Audio indicator
                              if (hasFocus)
                                const Positioned(
                                  right: 4,
                                  top: 4,
                                  child: Icon(Icons.volume_up,
                                      color: Colors.white70, size: 16),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              );
            }),
          ),
          // Back button
          Positioned(
            top: 40,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white54),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamCell {
  final Player player;
  final VideoController controller;
  final MultiViewChannel channel;

  const _StreamCell({
    required this.player,
    required this.controller,
    required this.channel,
  });
}

/// Channel info for multi-view.
class MultiViewChannel {
  final String name;
  final String url;
  final String? logo;

  const MultiViewChannel({
    required this.name,
    required this.url,
    this.logo,
  });
}
