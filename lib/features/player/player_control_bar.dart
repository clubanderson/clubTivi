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
  /// Callback to show the cast picker dialog.
  final VoidCallback? onCastTap;

  /// Callback to navigate back / exit fullscreen.
  final VoidCallback? onBackTap;

  /// Whether the cast session is active.
  final bool isCasting;

  const PlayerControlBar({
    super.key,
    this.onCastTap,
    this.onBackTap,
    this.isCasting = false,
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

  // Stream subscriptions
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _scheduleHide();
    _subscribeToPlayer();
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

                      // Volume icon + slider
                      Icon(
                        _volume == 0
                            ? Icons.volume_off
                            : _volume < 50
                                ? Icons.volume_down
                                : Icons.volume_up,
                        color: Colors.white,
                        size: 20,
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

                      // Interlaced badge
                      _badge('inv',
                          bgColor: Colors.red.shade700, fontSize: 10),
                      const SizedBox(width: 4),

                      // Record
                      _iconBtn(Icons.fiber_manual_record,
                          color: Colors.red.shade400,
                          size: 16,
                          onTap: () => _comingSoon('Recording')),
                      const SizedBox(width: 4),

                      // Encoding label
                      _badge('E', fontSize: 10),

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
                      _iconBtn(Icons.camera_alt_outlined,
                          onTap: () => _comingSoon('Screenshot')),
                      _iconBtn(Icons.star_border,
                          onTap: () => _comingSoon('Favorite')),
                      _iconBtn(Icons.picture_in_picture_alt,
                          onTap: () => _comingSoon('PiP')),
                      _iconBtn(
                        widget.isCasting
                            ? Icons.cast_connected
                            : Icons.cast,
                        color:
                            widget.isCasting ? Colors.amber : Colors.white,
                        onTap: widget.onCastTap,
                      ),
                      _iconBtn(Icons.info_outline,
                          onTap: () => _comingSoon('Info')),
                      _iconBtn(Icons.settings,
                          onTap: () => _comingSoon('Settings')),
                      _iconBtn(Icons.list,
                          onTap: () => _comingSoon('Channel list')),
                      _iconBtn(Icons.sort,
                          onTap: () => _comingSoon('Sort/filter')),
                      _badge('EPG', fontSize: 10),
                      const SizedBox(width: 6),
                      _badge('-- fps', fontSize: 10),
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
