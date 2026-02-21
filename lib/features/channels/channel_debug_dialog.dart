import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../data/datasources/local/database.dart' as db;
import '../player/player_service.dart';

/// Modal bottom sheet showing technical details about the currently playing
/// channel — useful for troubleshooting buffering and stream issues.
class ChannelDebugDialog extends StatefulWidget {
  final db.Channel channel;
  final PlayerService playerService;
  final String? mappedEpgId;

  const ChannelDebugDialog({
    super.key,
    required this.channel,
    required this.playerService,
    this.mappedEpgId,
  });

  /// Convenience launcher.
  static void show(
    BuildContext context,
    db.Channel channel,
    PlayerService playerService, {
    String? mappedEpgId,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0A1128),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ChannelDebugDialog(
        channel: channel,
        playerService: playerService,
        mappedEpgId: mappedEpgId,
      ),
    );
  }

  @override
  State<ChannelDebugDialog> createState() => _ChannelDebugDialogState();
}

class _ChannelDebugDialogState extends State<ChannelDebugDialog> {
  // Buffering sparkline data (last 60 points).
  final List<bool> _bufferHistory = List.filled(60, false, growable: true);
  StreamSubscription<bool>? _bufferingSub;

  int _bufferEventCount = 0;
  int _bufferingSeconds = 0;
  Timer? _bufferingTimer;
  bool _currentlyBuffering = false;

  @override
  void initState() {
    super.initState();

    _bufferingSub =
        widget.playerService.bufferingStream.listen((isBuffering) {
      if (!mounted) return;
      setState(() {
        _bufferHistory.removeAt(0);
        _bufferHistory.add(isBuffering);
        if (isBuffering && !_currentlyBuffering) _bufferEventCount++;
        _currentlyBuffering = isBuffering;
      });
    });

    // Tick every second to accumulate buffering time.
    _bufferingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_currentlyBuffering) {
        setState(() => _bufferingSeconds++);
      }
    });
  }

  @override
  void dispose() {
    _bufferingSub?.cancel();
    _bufferingTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Color _healthColor() {
    if (_bufferEventCount > 5) return const Color(0xFFFF6B6B);
    if (_bufferEventCount >= 2) return const Color(0xFFFDCB6E);
    return const Color(0xFF00B894);
  }

  String _healthLabel() {
    if (_bufferEventCount > 5) return 'Poor';
    if (_bufferEventCount >= 2) return 'Fair';
    return 'Good';
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final player = widget.playerService.player;
    final ch = widget.channel;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Title
              const Text(
                'Channel Debug Info',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),

              // -- Stream Info ------------------------------------------------
              _sectionCard('Stream Info', [
                _labelValue('Name', ch.name),
                _labelValue('Provider ID', ch.providerId),
                _labelValue('Group', ch.groupTitle ?? '—'),
                _labelValue(
                    'TVG ID / EPG',
                    widget.mappedEpgId != null && widget.mappedEpgId!.isNotEmpty
                        ? '${widget.mappedEpgId!} (mapped)'
                        : (ch.tvgId != null && ch.tvgId!.isNotEmpty)
                            ? ch.tvgId!
                            : 'Unmapped'),
                _labelValue('Stream Type', ch.streamType),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Text(
                      'Stream URL',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: ch.streamUrl));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('URL copied'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.copy_rounded, size: 14, color: Colors.white38),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                SelectableText(
                  ch.streamUrl,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ]),

              const SizedBox(height: 10),

              // -- Playback Stats ---------------------------------------------
              _sectionCard('Playback Stats', [
                // Resolution
                StreamBuilder<int?>(
                  stream: player.stream.width,
                  builder: (_, wSnap) {
                    return StreamBuilder<int?>(
                      stream: player.stream.height,
                      builder: (_, hSnap) {
                        final w = wSnap.data ?? player.state.width;
                        final h = hSnap.data ?? player.state.height;
                        final label = (w != null && h != null && w > 0 && h > 0)
                            ? '$w×$h'
                            : 'Unknown';
                        return _labelValue('Resolution', label);
                      },
                    );
                  },
                ),

                // Playback rate
                StreamBuilder<double>(
                  stream: player.stream.rate,
                  builder: (_, snap) {
                    final rate = snap.data ?? player.state.rate;
                    return _labelValue('Playback Rate', '${rate}x');
                  },
                ),

                // Volume
                StreamBuilder<double>(
                  stream: player.stream.volume,
                  builder: (_, snap) {
                    final vol = snap.data ?? player.state.volume;
                    return _labelValue('Volume', '${vol.toStringAsFixed(0)}%');
                  },
                ),

                // Audio tracks — list each with details
                StreamBuilder<Tracks>(
                  stream: player.stream.tracks,
                  initialData: player.state.tracks,
                  builder: (_, tracksSnap) {
                    final audioTracks = tracksSnap.data?.audio ?? [];
                    final currentAudio = player.state.track.audio;
                    if (audioTracks.isEmpty) {
                      return _labelValue('Audio Tracks', 'None detected');
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _labelValue('Audio Tracks', '${audioTracks.length} total'),
                        ...audioTracks.map((t) {
                          final isCurrent = t.id == currentAudio.id;
                          final label = [
                            if (t.title != null && t.title!.isNotEmpty) t.title!,
                            if (t.language != null && t.language!.isNotEmpty) '(${t.language})',
                            'id: ${t.id}',
                          ].join(' ');
                          return Padding(
                            padding: const EdgeInsets.only(left: 12, top: 2),
                            child: Row(
                              children: [
                                Icon(
                                  isCurrent ? Icons.volume_up_rounded : Icons.volume_mute_rounded,
                                  size: 12,
                                  color: isCurrent ? Colors.greenAccent : Colors.white24,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isCurrent ? Colors.greenAccent : Colors.white54,
                                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 50,
                                  child: isCurrent
                                    ? const Text('Active', style: TextStyle(fontSize: 10, color: Colors.greenAccent))
                                    : GestureDetector(
                                        onTap: () async {
                                          await player.setAudioTrack(t);
                                          await Future.delayed(const Duration(milliseconds: 300));
                                          if (mounted) setState(() {});
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.blueAccent.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text('Select', style: TextStyle(fontSize: 10, color: Colors.blueAccent)),
                                        ),
                                      ),
                                ),
                              ],
                            ),
                          );
                        }),
                        const SizedBox(height: 4),
                      ],
                    );
                  },
                ),

                // Video tracks — list each with details
                StreamBuilder<Tracks>(
                  stream: player.stream.tracks,
                  initialData: player.state.tracks,
                  builder: (_, tracksSnap) {
                    final videoTracks = tracksSnap.data?.video ?? [];
                    final currentVideo = player.state.track.video;
                    if (videoTracks.isEmpty) {
                      return _labelValue('Video Tracks', 'None detected');
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _labelValue('Video Tracks', '${videoTracks.length} total'),
                        ...videoTracks.map((t) {
                          final isCurrent = t.id == currentVideo.id;
                          final label = [
                            if (t.title != null && t.title!.isNotEmpty) t.title!,
                            if (t.language != null && t.language!.isNotEmpty) '(${t.language})',
                            'id: ${t.id}',
                          ].join(' ');
                          return Padding(
                            padding: const EdgeInsets.only(left: 12, top: 2),
                            child: Row(
                              children: [
                                Icon(
                                  isCurrent ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                                  size: 12,
                                  color: isCurrent ? Colors.greenAccent : Colors.white24,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isCurrent ? Colors.greenAccent : Colors.white54,
                                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 50,
                                  child: isCurrent
                                    ? const Text('Active', style: TextStyle(fontSize: 10, color: Colors.greenAccent))
                                    : GestureDetector(
                                        onTap: () async {
                                          await player.setVideoTrack(t);
                                          await Future.delayed(const Duration(milliseconds: 300));
                                          if (mounted) setState(() {});
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.blueAccent.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text('Select', style: TextStyle(fontSize: 10, color: Colors.blueAccent)),
                                        ),
                                      ),
                                ),
                              ],
                            ),
                          );
                        }),
                        const SizedBox(height: 4),
                      ],
                    );
                  },
                ),

                // Playing / buffering state
                StreamBuilder<bool>(
                  stream: player.stream.playing,
                  builder: (_, playSnap) {
                    return StreamBuilder<bool>(
                      stream: player.stream.buffering,
                      builder: (_, bufSnap) {
                        final playing = playSnap.data ?? player.state.playing;
                        final buffering =
                            bufSnap.data ?? player.state.buffering;
                        String state;
                        Color color;
                        if (buffering) {
                          state = 'Buffering';
                          color = Colors.orangeAccent;
                        } else if (playing) {
                          state = 'Playing';
                          color = const Color(0xFF00B894);
                        } else {
                          state = 'Stopped';
                          color = Colors.white38;
                        }
                        return Row(
                          children: [
                            const Text(
                              'State: ',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              state,
                              style: TextStyle(color: color, fontSize: 12),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ]),

              const SizedBox(height: 10),

              // -- Buffering --------------------------------------------------
              _sectionCard('Buffering', [
                // Sparkline (larger)
                SizedBox(
                  width: 280,
                  height: 60,
                  child: CustomPaint(
                    painter: _BufferingSparkline(_bufferHistory),
                  ),
                ),
                const SizedBox(height: 8),
                _labelValue(
                    'Buffer Events', '$_bufferEventCount in this session'),
                _labelValue(
                    'Total Buffering Time', '${_bufferingSeconds}s'),
                Row(
                  children: [
                    const Text(
                      'Buffer Health: ',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _healthColor(),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _healthLabel(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ]),

              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Reusable widgets
  // ---------------------------------------------------------------------------

  Widget _sectionCard(String title, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const Divider(color: Colors.white12, height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _labelValue(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Buffering sparkline painter (same logic as channel_info_overlay.dart)
// -----------------------------------------------------------------------------

class _BufferingSparkline extends CustomPainter {
  final List<bool> data;

  _BufferingSparkline(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final greenPaint = Paint()
      ..color = const Color(0xFF00B894)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final redPaint = Paint()
      ..color = const Color(0xFFFF6B6B)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final stepX = size.width / (data.length - 1).clamp(1, data.length);
    final baseline = size.height * 0.85;
    final peakY = size.height * 0.1;

    for (int i = 0; i < data.length - 1; i++) {
      final x1 = i * stepX;
      final x2 = (i + 1) * stepX;
      final y1 = data[i] ? peakY : baseline;
      final y2 = data[i + 1] ? peakY : baseline;
      final paint = (data[i] || data[i + 1]) ? redPaint : greenPaint;
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BufferingSparkline oldDelegate) => true;
}
