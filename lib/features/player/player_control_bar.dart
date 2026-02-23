import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player_service.dart';

/// TiviMate-style fullscreen player control bar.
///
/// Two-row layout on a dark semi-transparent background:
/// - Top row: volume, resolution badge, transport controls, action icons
/// - Bottom row: position, seek bar, duration
class PlayerControlBar extends ConsumerStatefulWidget {
  final VoidCallback? onCastTap;
  final VoidCallback? onBackTap;
  final VoidCallback? onScreenshot;
  final VoidCallback? onFavorite;
  final VoidCallback? onPip;
  final VoidCallback? onInfo;
  final VoidCallback? onSettings;
  final VoidCallback? onChannelList;
  final VoidCallback? onSubtitleToggle;
  final VoidCallback? onSubtitleSelect;
  final VoidCallback? onAudioSelect;
  final bool isCasting;
  final bool isFavorite;
  final bool hasSubtitles;
  final bool subtitlesEnabled;
  final int audioTrackCount;

  const PlayerControlBar({
    super.key,
    this.onCastTap,
    this.onBackTap,
    this.onScreenshot,
    this.onFavorite,
    this.onPip,
    this.onInfo,
    this.onSettings,
    this.onChannelList,
    this.onSubtitleToggle,
    this.onSubtitleSelect,
    this.onAudioSelect,
    this.isCasting = false,
    this.isFavorite = false,
    this.hasSubtitles = false,
    this.subtitlesEnabled = false,
    this.audioTrackCount = 0,
  });

  @override
  ConsumerState<PlayerControlBar> createState() => _PlayerControlBarState();
}

class _PlayerControlBarState extends ConsumerState<PlayerControlBar> {
  bool _visible = true;
  Timer? _hideTimer;

  // Player state cached from streams
  double _volume = 100.0;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int? _videoWidth;
  int? _videoHeight;
  bool _isSeeking = false;
  double _seekValue = 0.0;

  // Mute toggle state
  double _preMuteVolume = 100.0;
  final List<StreamSubscription> _subs = [];
  Timer? _fpsTimer;
  String _fpsLabel = '—';
  String _codecLabel = '';
  bool _isInterlaced = false;
  String _bufferDuration = '—';
  final List<double> _fpsHistory = [];

  @override
  void initState() {
    super.initState();
    _scheduleHide();
    _subscribeToPlayer();
    _startInfoPolling();
  }

  void _startInfoPolling() {
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      final ps = ref.read(playerServiceProvider);
      final results = await Future.wait([
        ps.getMpvProperty('estimated-vf-fps'),
        ps.getMpvProperty('video-codec'),
        ps.getMpvProperty('video-params/pixelformat'),
        ps.getMpvProperty('demuxer-cache-duration'),
      ]);
      if (!mounted) return;
      final fps = double.tryParse(results[0] ?? '');
      final codec = results[1] ?? '';
      final pixFmt = results[2] ?? '';
      final bufDur = double.tryParse(results[3] ?? '');
      setState(() {
        _bufferDuration = bufDur != null ? bufDur.toStringAsFixed(1) : '—';
        _fpsLabel = fps != null ? fps.toStringAsFixed(1) : '—';
        if (fps != null) {
          _fpsHistory.add(fps);
          if (_fpsHistory.length > 60) _fpsHistory.removeAt(0);
        }
        // Extract short codec name (e.g. "h264" from "h264 (High)")
        _codecLabel = codec.split(' ').first.toUpperCase();
        _isInterlaced = pixFmt.contains('interlaced') || pixFmt.contains('tff') || pixFmt.contains('bff');
      });
    });
  }

  void _subscribeToPlayer() {
    final ps = ref.read(playerServiceProvider);
    final player = ps.player;

    _volume = player.state.volume;
    _playing = player.state.playing;
    _position = player.state.position;
    _duration = player.state.duration;
    _videoWidth = player.state.width;
    _videoHeight = player.state.height;

    _subs.add(player.stream.volume.listen((v) {
      if (mounted) setState(() => _volume = v);
    }));
    _subs.add(player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    }));
    _subs.add(player.stream.position.listen((p) {
      if (mounted && !_isSeeking) setState(() => _position = p);
    }));
    _subs.add(player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    }));
    _subs.add(player.stream.width.listen((w) {
      if (mounted) setState(() => _videoWidth = w);
    }));
    _subs.add(player.stream.height.listen((h) {
      if (mounted) setState(() => _videoHeight = h);
    }));
  }

  // --- Visibility / auto-hide ---

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _onInteraction() {
    if (!_visible) {
      setState(() => _visible = true);
    }
    _scheduleHide();
  }

  // --- Helpers ---

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '00:$m:$s';
  }

  String _resolutionLabel() {
    final h = _videoHeight ?? 0;
    if (h >= 2160) return '4K UHD';
    if (h >= 1080) return '1080 HD';
    if (h >= 720) return '720 HD';
    if (h >= 480) return '480 SD';
    if (h > 0) return '${h}p';
    return '—';
  }

  void _comingSoon(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature — coming soon'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.grey.shade800,
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _fpsTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => _onInteraction(),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onInteraction,
        child: AnimatedOpacity(
          opacity: _visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: IgnorePointer(
            ignoring: !_visible,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // ── Top row ──
                Container(
                  color: Colors.black.withValues(alpha: 0.7),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      // Back button
                      _iconBtn(Icons.arrow_back, onTap: widget.onBackTap),
                      const SizedBox(width: 4),

                      // Volume icon (tap to toggle mute) + slider
                      GestureDetector(
                        onTap: () {
                          if (_volume > 0) {
                            _preMuteVolume = _volume;
                            setState(() => _volume = 0);
                            ref.read(playerServiceProvider).setVolume(0);
                          } else {
                            setState(() => _volume = _preMuteVolume > 0 ? _preMuteVolume : 100);
                            ref.read(playerServiceProvider).setVolume(_volume);
                          }
                          _scheduleHide();
                        },
                        child: Icon(
                          _volume == 0
                              ? Icons.volume_off
                              : _volume < 50
                                  ? Icons.volume_down
                                  : Icons.volume_up,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      SizedBox(
                        width: 100,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12),
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            value: _volume,
                            min: 0,
                            max: 100,
                            onChanged: (v) {
                              setState(() => _volume = v);
                              ref.read(playerServiceProvider).setVolume(v);
                              _scheduleHide();
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Resolution badge
                      _badge(_resolutionLabel()),
                      const SizedBox(width: 4),

                      // Interlaced badge (only shown if interlaced)
                      if (_isInterlaced)
                        _badge('INT',
                            bgColor: Colors.red.shade700, fontSize: 10),
                      if (_isInterlaced)
                        const SizedBox(width: 4),

                      // Record
                      _iconBtn(Icons.fiber_manual_record,
                          color: Colors.red.shade400,
                          size: 16,
                          onTap: () => _comingSoon('Recording')),
                      const SizedBox(width: 4),

                      // Codec label
                      if (_codecLabel.isNotEmpty)
                        _badge(_codecLabel, fontSize: 10),

                      const Spacer(),

                      // ── Transport controls (center) ──
                      _iconBtn(Icons.fast_rewind, onTap: () {
                        final ps = ref.read(playerServiceProvider);
                        final target = _position - const Duration(seconds: 10);
                        ps.player.seek(target < Duration.zero
                            ? Duration.zero
                            : target);
                        _scheduleHide();
                      }),
                      const SizedBox(width: 12),
                      _iconBtn(
                        _playing ? Icons.pause : Icons.play_arrow,
                        size: 32,
                        onTap: () {
                          final ps = ref.read(playerServiceProvider);
                          _playing ? ps.pause() : ps.resume();
                          _scheduleHide();
                        },
                      ),
                      const SizedBox(width: 12),
                      _iconBtn(Icons.fast_forward, onTap: () {
                        final ps = ref.read(playerServiceProvider);
                        final target = _position + const Duration(seconds: 10);
                        ps.player.seek(
                            target > _duration ? _duration : target);
                        _scheduleHide();
                      }),

                      const Spacer(),

                      // ── Right side icons ──
                      // CC (subtitle) toggle + long-press picker
                      GestureDetector(
                        onTap: widget.onSubtitleToggle,
                        onLongPress: widget.onSubtitleSelect,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            widget.subtitlesEnabled
                                ? Icons.closed_caption
                                : Icons.closed_caption_disabled,
                            color: widget.subtitlesEnabled
                                ? Colors.white
                                : Colors.white38,
                            size: 20,
                          ),
                        ),
                      ),
                      // Audio track selector (only if > 1 track)
                      if (widget.audioTrackCount > 1)
                        InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: widget.onAudioSelect,
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                const Icon(Icons.audiotrack, color: Colors.white, size: 20),
                                Positioned(
                                  right: -6,
                                  top: -4,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF6C5CE7),
                                      shape: BoxShape.circle,
                                    ),
                                    constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                                    child: Text(
                                      '${widget.audioTrackCount}',
                                      style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      _iconBtn(Icons.camera_alt_outlined,
                          onTap: widget.onScreenshot),
                      _iconBtn(
                        widget.isFavorite ? Icons.star : Icons.star_border,
                        color: widget.isFavorite ? Colors.amber : Colors.white,
                        onTap: widget.onFavorite,
                      ),
                      _iconBtn(Icons.picture_in_picture_alt,
                          onTap: widget.onPip),
                      _iconBtn(
                        widget.isCasting
                            ? Icons.cast_connected
                            : Icons.cast,
                        color:
                            widget.isCasting ? Colors.amber : Colors.white,
                        onTap: widget.onCastTap,
                      ),
                      _iconBtn(Icons.info_outline,
                          onTap: widget.onInfo),
                      _iconBtn(Icons.settings,
                          onTap: widget.onSettings),
                      _iconBtn(Icons.list,
                          onTap: widget.onChannelList),
                      _badge('EPG', fontSize: 10),
                      const SizedBox(width: 6),
                      Tooltip(
                        richMessage: WidgetSpan(
                          child: _FpsSparkline(history: _fpsHistory),
                        ),
                        waitDuration: const Duration(milliseconds: 300),
                        preferBelow: false,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A2E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white24),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: _badge('$_fpsLabel fps', fontSize: 10),
                      ),
                      const SizedBox(width: 4),
                      _badge('buf: ${_bufferDuration}s', fontSize: 10),
                    ],
                  ),
                ),

                // ── Bottom row: seek bar ──
                Container(
                  color: Colors.black.withValues(alpha: 0.7),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Row(
                    children: [
                      Text(
                        _formatDuration(
                            _isSeeking
                                ? Duration(
                                    milliseconds: _seekValue.round())
                                : _position),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 10),
                            activeTrackColor: Colors.blue,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.blue,
                          ),
                          child: Slider(
                            value: _isSeeking
                                ? _seekValue
                                : _position.inMilliseconds
                                    .toDouble()
                                    .clamp(
                                        0,
                                        _duration.inMilliseconds
                                            .toDouble()
                                            .clamp(1, double.infinity)),
                            min: 0,
                            max: _duration.inMilliseconds
                                .toDouble()
                                .clamp(1, double.infinity),
                            onChangeStart: (v) {
                              setState(() {
                                _isSeeking = true;
                                _seekValue = v;
                              });
                            },
                            onChanged: (v) {
                              setState(() => _seekValue = v);
                              _scheduleHide();
                            },
                            onChangeEnd: (v) {
                              ref.read(playerServiceProvider).player.seek(
                                  Duration(milliseconds: v.round()));
                              setState(() => _isSeeking = false);
                            },
                          ),
                        ),
                      ),
                      Text(
                        _formatDuration(_duration),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Small helpers ──

  Widget _iconBtn(IconData icon,
      {VoidCallback? onTap, Color color = Colors.white, double size = 20}) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, color: color, size: size),
      ),
    );
  }

  Widget _badge(String text,
      {Color bgColor = Colors.transparent, double fontSize = 11}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        border: bgColor == Colors.transparent
            ? Border.all(color: Colors.white38)
            : null,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Sparkline chart for FPS history, shown in tooltip.
class _FpsSparkline extends StatelessWidget {
  final List<double> history;
  const _FpsSparkline({required this.history});

  @override
  Widget build(BuildContext context) {
    if (history.length < 2) {
      return const SizedBox(
        width: 180, height: 60,
        child: Center(child: Text('Collecting data…', style: TextStyle(color: Colors.white54, fontSize: 11))),
      );
    }

    final min = history.reduce((a, b) => a < b ? a : b);
    final max = history.reduce((a, b) => a > b ? a : b);
    final avg = history.reduce((a, b) => a + b) / history.length;
    final actualRange = max - min;
    // When FPS is stable (range < 1), use a fixed window around the avg
    // so the sparkline isn't just a flat line at the edge.
    final displayMin = actualRange < 1.0 ? avg - 5.0 : min;
    final displayRange = actualRange < 1.0 ? 10.0 : actualRange;

    return SizedBox(
      width: 200,
      height: 80,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'FPS  min: ${min.toStringAsFixed(1)}  avg: ${avg.toStringAsFixed(1)}  max: ${max.toStringAsFixed(1)}',
            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: CustomPaint(
              size: const Size(200, 50),
              painter: _SparklinePainter(history, displayMin, displayRange),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final double min;
  final double range;

  _SparklinePainter(this.data, this.min, this.range);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;

    final linePaint = Paint()
      ..color = const Color(0xFF6C5CE7)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x806C5CE7), Color(0x006C5CE7)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();
    final fillPath = Path();

    for (var i = 0; i < data.length; i++) {
      final x = (i / (data.length - 1)) * size.width;
      final y = size.height - ((data[i] - min) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) => true;
}
