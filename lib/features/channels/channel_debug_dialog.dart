import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/models/channel.dart' hide Provider;
import '../../data/services/stream_alternatives_service.dart';
import '../player/player_service.dart';

/// Modal bottom sheet showing technical details about the currently playing
/// channel — useful for troubleshooting buffering and stream issues.
class ChannelDebugDialog extends StatefulWidget {
  final db.Channel channel;
  final PlayerService playerService;
  final String? mappedEpgId;
  final String? originalName;
  final String? vanityName;
  final String? currentProviderName;
  final List<AlternativeDetail> alternatives;
  /// Called when user confirms applying vanity name to alternatives.
  /// Passes list of channel IDs that should receive the vanity name.
  final void Function(List<String> channelIds, String vanityName)? onVanityApplied;

  const ChannelDebugDialog({
    super.key,
    required this.channel,
    required this.playerService,
    this.mappedEpgId,
    this.originalName,
    this.vanityName,
    this.currentProviderName,
    this.alternatives = const [],
    this.onVanityApplied,
  });

  /// Convenience launcher.
  static void show(
    BuildContext context,
    db.Channel channel,
    PlayerService playerService, {
    String? mappedEpgId,
    String? originalName,
    String? vanityName,
    String? currentProviderName,
    List<AlternativeDetail> alternatives = const [],
    void Function(List<String> channelIds, String vanityName)? onVanityApplied,
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
        originalName: originalName,
        vanityName: vanityName,
        currentProviderName: currentProviderName,
        alternatives: alternatives,
        onVanityApplied: onVanityApplied,
      ),
    );
  }

  @override
  State<ChannelDebugDialog> createState() => _ChannelDebugDialogState();
}

class _ChannelDebugDialogState extends State<ChannelDebugDialog> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Refresh UI every second to pick up latest values from PlayerService.
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Color _healthColor() {
    final count = widget.playerService.bufferEventCount;
    if (count > 5) return const Color(0xFFFF6B6B);
    if (count >= 2) return const Color(0xFFFDCB6E);
    return const Color(0xFF00B894);
  }

  String _healthLabel() {
    final count = widget.playerService.bufferEventCount;
    if (count > 5) return 'Poor';
    if (count >= 2) return 'Fair';
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
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.7,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Title + health badge
              Row(
                children: [
                  const Text('Channel Info',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _healthColor(),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_healthLabel(),
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Two-column layout
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left column: Stream info
                    Expanded(
                      child: _compactCard([
                        _row('Name', ch.name),
                        if (ch.tvgName != null &&
                            ch.tvgName!.isNotEmpty &&
                            ch.tvgName != ch.name)
                          _row('Original', ch.tvgName!),
                        if (widget.originalName != null &&
                            widget.originalName != ch.name &&
                            widget.originalName != ch.tvgName)
                          _row('DB Name', widget.originalName!),
                        _row('Group', ch.groupTitle ?? '—'),
                        _row('EPG',
                          widget.mappedEpgId != null && widget.mappedEpgId!.isNotEmpty
                              ? '${widget.mappedEpgId!} ✓'
                              : (ch.tvgId != null && ch.tvgId!.isNotEmpty)
                                  ? ch.tvgId!
                                  : 'Unmapped'),
                        _row('Type', ch.streamType),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Text('URL ', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                            InkWell(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: ch.streamUrl));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('URL copied'), duration: Duration(seconds: 1)));
                              },
                              child: const Icon(Icons.copy_rounded, size: 12, color: Colors.white38),
                            ),
                          ],
                        ),
                        Text(ch.streamUrl,
                          style: const TextStyle(color: Colors.white38, fontSize: 9, fontFamily: 'monospace'),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    // Right column: Playback stats
                    Expanded(
                      child: _compactCard([
                        // Resolution
                        StreamBuilder<int?>(
                          stream: player.stream.width,
                          builder: (_, wSnap) => StreamBuilder<int?>(
                            stream: player.stream.height,
                            builder: (_, hSnap) {
                              final w = wSnap.data ?? player.state.width;
                              final h = hSnap.data ?? player.state.height;
                              return _row('Resolution', (w != null && h != null && w > 0) ? '$w×$h' : '—');
                            },
                          ),
                        ),
                        // State
                        StreamBuilder<bool>(
                          stream: player.stream.playing,
                          builder: (_, playSnap) => StreamBuilder<bool>(
                            stream: player.stream.buffering,
                            builder: (_, bufSnap) {
                              final playing = playSnap.data ?? player.state.playing;
                              final buffering = bufSnap.data ?? player.state.buffering;
                              return _row('State', buffering ? 'Buffering' : playing ? 'Playing' : 'Stopped');
                            },
                          ),
                        ),
                        // Volume
                        StreamBuilder<double>(
                          stream: player.stream.volume,
                          builder: (_, snap) => _row('Volume', '${(snap.data ?? player.state.volume).toStringAsFixed(0)}%'),
                        ),
                        // Audio tracks summary
                        StreamBuilder<Tracks>(
                          stream: player.stream.tracks,
                          initialData: player.state.tracks,
                          builder: (_, tracksSnap) {
                            final audio = tracksSnap.data?.audio ?? [];
                            final current = player.state.track.audio;
                            final label = audio.isEmpty ? 'None'
                                : '${current.title ?? current.language ?? current.id} (${audio.length})';
                            return _row('Audio', label);
                          },
                        ),
                        // Video tracks summary
                        StreamBuilder<Tracks>(
                          stream: player.stream.tracks,
                          initialData: player.state.tracks,
                          builder: (_, tracksSnap) {
                            final video = tracksSnap.data?.video ?? [];
                            return _row('Video Tracks', '${video.length}');
                          },
                        ),
                        // Rate
                        StreamBuilder<double>(
                          stream: player.stream.rate,
                          builder: (_, snap) => _row('Rate', '${snap.data ?? player.state.rate}x'),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Failover alternatives (shows current + alternatives)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF16213E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.swap_horiz, size: 14, color: Colors.white54),
                        const SizedBox(width: 4),
                        Text(
                          'Failover Group (${widget.alternatives.length + 1})',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Current channel (always first)
                    _failoverRow(
                      name: ch.name,
                      providerName: widget.currentProviderName,
                      badge: 'current',
                      badgeColor: const Color(0xFF00B894),
                      healthScore: null,
                    ),
                    if (widget.alternatives.isNotEmpty) ...[
                      const Divider(color: Colors.white12, height: 8),
                      ...widget.alternatives.take(8).map((alt) => _failoverRow(
                        name: alt.channel.name,
                        providerName: alt.providerName.isNotEmpty ? alt.providerName : null,
                        badge: alt.matchReason,
                        badgeColor: null,
                        healthScore: alt.healthScore,
                      )),
                      if (widget.alternatives.length > 8)
                        Text(
                          '  +${widget.alternatives.length - 8} more',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 9),
                        ),
                    ] else ...[
                      const Divider(color: Colors.white12, height: 8),
                      const Text(
                        '  No failover alternatives found',
                        style: TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Buffering sparkline (compact, full width)
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF16213E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 30,
                        child: CustomPaint(painter: _BufferingSparkline(widget.playerService.bufferHistory)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${widget.playerService.bufferEventCount} events',
                          style: const TextStyle(color: Colors.white54, fontSize: 10)),
                        Text('${widget.playerService.bufferingSeconds}s buffering',
                          style: const TextStyle(color: Colors.white54, fontSize: 10)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// A single row in the failover group showing channel name, provider badge,
  /// match reason badge, and health score.
  Widget _failoverRow({
    required String name,
    String? providerName,
    required String badge,
    Color? badgeColor,
    double? healthScore,
  }) {
    final isCurrentRow = badge == 'current';
    final healthColor = healthScore == null
        ? const Color(0xFF00B894)
        : healthScore > 0.7
            ? const Color(0xFF00B894)
            : healthScore > 0.4
                ? const Color(0xFFFDCB6E)
                : const Color(0xFFFF6B6B);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          // Health dot
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: isCurrentRow ? const Color(0xFF00B894) : healthColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          // Provider badge
          if (providerName != null && providerName.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: isCurrentRow
                    ? const Color(0xFF00B894).withAlpha(40)
                    : const Color(0xFF6C5CE7).withAlpha(40),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isCurrentRow
                      ? const Color(0xFF00B894).withAlpha(80)
                      : const Color(0xFF6C5CE7).withAlpha(80),
                  width: 0.5,
                ),
              ),
              child: Text(
                providerName,
                style: TextStyle(
                  color: isCurrentRow
                      ? const Color(0xFF00B894)
                      : const Color(0xFF6C5CE7),
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          // Channel name
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                color: isCurrentRow ? Colors.white : Colors.white70,
                fontSize: 10,
                fontWeight: isCurrentRow ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          // Match reason badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: badgeColor?.withAlpha(40) ?? Colors.white10,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              badge,
              style: TextStyle(
                color: badgeColor ?? Colors.white38,
                fontSize: 8,
                fontWeight: isCurrentRow ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          // Health %
          if (healthScore != null) ...[
            const SizedBox(width: 4),
            Text(
              '${(healthScore * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                color: healthColor,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _compactCard(List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ',
            style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold, fontSize: 11)),
          Expanded(
            child: Text(value,
              style: const TextStyle(color: Colors.white, fontSize: 11),
              overflow: TextOverflow.ellipsis, maxLines: 1),
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

// =============================================================================
// VLC-style debug info overlay — semi-transparent, monospace, top-left
// =============================================================================

/// A positioned overlay that shows real-time stream technical details.
/// Toggle with the `D` key or the info button in the control bar.
class ChannelDebugOverlay extends StatefulWidget {
  final db.Channel channel;
  final PlayerService playerService;
  final String? providerName;
  final String? mappedEpgId;

  const ChannelDebugOverlay({
    super.key,
    required this.channel,
    required this.playerService,
    this.providerName,
    this.mappedEpgId,
  });

  @override
  State<ChannelDebugOverlay> createState() => _ChannelDebugOverlayState();
}

class _ChannelDebugOverlayState extends State<ChannelDebugOverlay> {
  Timer? _refreshTimer;

  // Cached mpv properties (refreshed every second)
  String _videoCodec = '—';
  String _audioCodec = '—';
  String _resolution = '—';
  String _fps = '—';
  String _videoBitrate = '—';
  String _audioBitrate = '—';
  String _bufferDuration = '—';
  String _containerFormat = '—';
  String _hwdec = '—';
  bool _buffering = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    final ps = widget.playerService;
    final results = await Future.wait([
      ps.getMpvProperty('video-codec'),       // 0
      ps.getMpvProperty('audio-codec-name'),   // 1
      ps.getMpvProperty('video-params/w'),     // 2
      ps.getMpvProperty('video-params/h'),     // 3
      ps.getMpvProperty('container-fps'),      // 4
      ps.getMpvProperty('video-bitrate'),      // 5
      ps.getMpvProperty('audio-bitrate'),      // 6
      ps.getMpvProperty('demuxer-cache-duration'), // 7
      ps.getMpvProperty('file-format'),        // 8
      ps.getMpvProperty('hwdec-current'),      // 9
    ]);
    if (!mounted) return;

    final w = results[2];
    final h = results[3];
    final vBitrate = _formatBitrate(results[5]);
    final aBitrate = _formatBitrate(results[6]);
    final bufDur = results[7];

    setState(() {
      _videoCodec = results[0] ?? '—';
      _audioCodec = results[1] ?? '—';
      _resolution = (w != null && h != null) ? '${w}×$h' : '—';
      _fps = _formatFps(results[4]);
      _videoBitrate = vBitrate;
      _audioBitrate = aBitrate;
      _bufferDuration = bufDur != null ? '${double.tryParse(bufDur)?.toStringAsFixed(1) ?? bufDur}s' : '—';
      _containerFormat = results[8] ?? '—';
      _hwdec = results[9] ?? 'sw';
      _buffering = ps.player.state.buffering;
    });
  }

  String _formatBitrate(String? raw) {
    if (raw == null) return '—';
    final bits = double.tryParse(raw);
    if (bits == null) return raw;
    if (bits >= 1000000) return '${(bits / 1000000).toStringAsFixed(1)} Mbps';
    if (bits >= 1000) return '${(bits / 1000).toStringAsFixed(0)} kbps';
    return '${bits.toStringAsFixed(0)} bps';
  }

  String _formatFps(String? raw) {
    if (raw == null) return '—';
    final v = double.tryParse(raw);
    if (v == null) return raw;
    return v.toStringAsFixed(2);
  }

  String _maskUrl(String url) {
    // Show scheme + host + first 20 chars of path, then ...
    final uri = Uri.tryParse(url);
    if (uri == null) return url.length > 60 ? '${url.substring(0, 60)}…' : url;
    final hostPart = '${uri.scheme}://${uri.host}';
    final path = uri.path;
    if (path.length <= 25) return '$hostPart$path';
    return '$hostPart${path.substring(0, 25)}…';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.channel;
    final epgLabel = widget.mappedEpgId != null && widget.mappedEpgId!.isNotEmpty
        ? widget.mappedEpgId!
        : (ch.tvgId ?? '—');

    final lines = <_DebugLine>[
      _DebugLine('Channel', ch.name),
      if (widget.providerName != null && widget.providerName!.isNotEmpty)
        _DebugLine('Provider', widget.providerName!),
      _DebugLine('EPG ID', epgLabel),
      _DebugLine('URL', _maskUrl(ch.streamUrl)),
      const _DebugLine('', ''),
      _DebugLine('Container', _containerFormat),
      _DebugLine('Video Codec', _videoCodec),
      _DebugLine('Audio Codec', _audioCodec),
      _DebugLine('Resolution', _resolution),
      _DebugLine('Frame Rate', '$_fps fps'),
      _DebugLine('HW Decode', _hwdec),
      const _DebugLine('', ''),
      _DebugLine('Video Bitrate', _videoBitrate),
      _DebugLine('Audio Bitrate', _audioBitrate),
      _DebugLine('Buffer', _bufferDuration),
      _DebugLine('State', _buffering ? 'Buffering' : 'Playing'),
    ];

    return Positioned(
      top: 8,
      left: 8,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '⚙ Debug Info',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00B894),
                ),
              ),
              const SizedBox(height: 4),
              ...lines.map((l) {
                if (l.label.isEmpty && l.value.isEmpty) {
                  return const SizedBox(height: 4);
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 90,
                        child: Text(
                          l.label,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          l.value,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: l.label == 'State' && _buffering
                                ? Colors.orangeAccent
                                : Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _DebugLine {
  final String label;
  final String value;
  const _DebugLine(this.label, this.value);
}
