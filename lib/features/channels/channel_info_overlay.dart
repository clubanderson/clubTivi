import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../player/player_service.dart';

/// Cable TV-style channel info banner that slides in when switching channels.
///
/// Set [position] to [OverlayPosition.top] (default) or
/// [OverlayPosition.bottom].
enum OverlayPosition { top, bottom }

class ChannelInfoOverlay extends StatefulWidget {
  final int channelNumber;
  final String channelName;
  final String? channelLogo;
  final String? groupTitle;
  final String? currentProgramme;
  final String? currentProgrammeTime;
  final String? nextProgramme;
  final String? nextProgrammeTime;
  final PlayerService playerService;
  final VoidCallback? onDismissed;
  final OverlayPosition position;

  const ChannelInfoOverlay({
    super.key,
    required this.channelNumber,
    required this.channelName,
    this.channelLogo,
    this.groupTitle,
    this.currentProgramme,
    this.currentProgrammeTime,
    this.nextProgramme,
    this.nextProgrammeTime,
    required this.playerService,
    this.onDismissed,
    this.position = OverlayPosition.top,
  });

  @override
  State<ChannelInfoOverlay> createState() => _ChannelInfoOverlayState();
}

class _ChannelInfoOverlayState extends State<ChannelInfoOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  Timer? _autoHideTimer;

  // Buffering sparkline data (last 30 points).
  final List<bool> _bufferHistory = List.filled(30, false, growable: true);
  StreamSubscription<bool>? _bufferingSub;
  Timer? _sparklineTimer;

  // Resolution info read from player state.
  int? _videoHeight;
  StreamSubscription<int?>? _heightSub;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    final isTop = widget.position == OverlayPosition.top;
    _slideAnimation = Tween<Offset>(
      begin: Offset(0, isTop ? -1 : 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    ));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );

    _animController.forward();
    _startAutoHide();

    // Subscribe to buffering stream for sparkline.
    _bufferingSub =
        widget.playerService.bufferingStream.listen((isBuffering) {
      if (!mounted) return;
      setState(() {
        _bufferHistory.removeAt(0);
        _bufferHistory.add(isBuffering);
      });
    });

    // Poll sparkline at 1 Hz to keep it ticking even when not buffering.
    _sparklineTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        // The listener above pushes real values; this just forces repaint.
      });
    });

    // Subscribe to video dimensions.
    _heightSub =
        widget.playerService.player.stream.height.listen((h) {
      if (mounted) setState(() => _videoHeight = h);
    });
  }

  void _startAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 5), _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    await _animController.reverse();
    widget.onDismissed?.call();
  }

  /// Reset the overlay (e.g. when channel changes again before auto-hide).
  void reset() {
    _animController.forward(from: 0);
    _startAutoHide();
  }

  @override
  void didUpdateWidget(covariant ChannelInfoOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelNumber != widget.channelNumber ||
        oldWidget.channelName != widget.channelName) {
      reset();
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _sparklineTimer?.cancel();
    _bufferingSub?.cancel();
    _heightSub?.cancel();
    _animController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Resolution helpers
  // ---------------------------------------------------------------------------

  String _resolutionLabel() {
    final h = _videoHeight;
    if (h == null || h == 0) return '';
    if (h >= 2160) return '4K';
    if (h >= 1080) return '1080p';
    if (h >= 720) return '720p';
    if (h >= 480) return '480p';
    return 'SD';
  }

  Color _resolutionColor() {
    final h = _videoHeight;
    if (h == null || h == 0) return Colors.grey;
    if (h >= 720) return const Color(0xFF00B894); // green for HD+
    return const Color(0xFFFDCB6E); // yellow for SD
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isTop = widget.position == OverlayPosition.top;
    return Positioned(
      left: 0,
      right: 0,
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    // Channel number
                    Text(
                      '${widget.channelNumber}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6C5CE7),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Logo
                    if (widget.channelLogo != null &&
                        widget.channelLogo!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.network(
                            widget.channelLogo!,
                            width: 28,
                            height: 28,
                            fit: BoxFit.contain,
                            errorBuilder: (c, e, s) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    // Channel name + programme
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  widget.channelName,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (widget.groupTitle != null &&
                                  widget.groupTitle!.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  widget.groupTitle!,
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white38),
                                ),
                              ],
                            ],
                          ),
                          if (widget.currentProgramme != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '${widget.currentProgramme!}${widget.currentProgrammeTime != null ? '  ${widget.currentProgrammeTime}' : ''}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white60),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Resolution badge
                    if (_resolutionLabel().isNotEmpty)
                      _badge(_resolutionLabel(), _resolutionColor()),
                    const SizedBox(width: 6),
                    // Sparkline
                    SizedBox(
                      width: 50,
                      height: 20,
                      child: CustomPaint(
                          painter: _BufferingSparkline(_bufferHistory)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(String label, Color bg, {Color textColor = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Buffering sparkline painter
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
