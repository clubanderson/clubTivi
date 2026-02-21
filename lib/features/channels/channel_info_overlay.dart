import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../player/player_service.dart';

/// Cable TV-style channel info banner that slides up when switching channels.
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
  final List<bool> _bufferHistory = List.filled(30, false);
  StreamSubscription<bool>? _bufferingSub;
  Timer? _sparklineTimer;

  // Resolution info read from player state.
  int? _videoWidth;
  int? _videoHeight;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
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
    _widthSub =
        widget.playerService.player.stream.width.listen((w) {
      if (mounted) setState(() => _videoWidth = w);
    });
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
    _widthSub?.cancel();
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
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.80),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _buildLeftSection(),
                    const SizedBox(width: 20),
                    Expanded(child: _buildCenterSection()),
                    const SizedBox(width: 16),
                    _buildRightSection(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Channel number + logo.
  Widget _buildLeftSection() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '${widget.channelNumber}',
          style: const TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.bold,
            color: Color(0xFF6C5CE7),
            height: 1,
          ),
        ),
        const SizedBox(height: 8),
        if (widget.channelLogo != null && widget.channelLogo!.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              widget.channelLogo!,
              width: 56,
              height: 56,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }

  /// Channel name, current/next programme.
  Widget _buildCenterSection() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.channelName,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (widget.groupTitle != null && widget.groupTitle!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            widget.groupTitle!,
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ],
        if (widget.currentProgramme != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.play_circle_fill,
                  size: 14, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.currentProgramme!,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.currentProgrammeTime != null)
                Text(
                  widget.currentProgrammeTime!,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white54),
                ),
            ],
          ),
        ],
        if (widget.nextProgramme != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.skip_next_rounded,
                  size: 14, color: Colors.white38),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.nextProgramme!,
                  style:
                      const TextStyle(fontSize: 13, color: Colors.white54),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.nextProgrammeTime != null)
                Text(
                  widget.nextProgrammeTime!,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white38),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Resolution badges + buffering sparkline.
  Widget _buildRightSection() {
    final resLabel = _resolutionLabel();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (resLabel.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _badge(resLabel, _resolutionColor()),
              if (_videoWidth != null && _videoHeight != null)
                _badge(
                  '$_videoWidth×$_videoHeight',
                  Colors.white24,
                  textColor: Colors.white60,
                ),
            ],
          ),
        const SizedBox(height: 10),
        // Buffering sparkline
        SizedBox(
          width: 100,
          height: 30,
          child: CustomPaint(painter: _BufferingSparkline(_bufferHistory)),
        ),
        const SizedBox(height: 2),
        const Text(
          'Buffer',
          style: TextStyle(fontSize: 9, color: Colors.white30),
        ),
      ],
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
