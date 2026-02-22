import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _glowController;

  // Staggered animations driven by _controller (0→1 over 3s)
  late final Animation<double> _iconScale;
  late final Animation<double> _iconOpacity;
  late final Animation<double> _wave1;
  late final Animation<double> _wave2;
  late final Animation<double> _wave3;
  late final Animation<double> _titleOpacity;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _taglineOpacity;
  late final Animation<double> _fadeOut;

  // Continuous glow pulse
  late final Animation<double> _glowPulse;

  static const _accent = Color(0xFF6C5CE7);
  static const _surface = Color(0xFF0A0A0F);

  @override
  void initState() {
    super.initState();

    // Main timeline: 3.5 seconds total
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    );

    // Glow pulse: loops continuously
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _glowPulse = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    // Icon: scale in with elastic bounce (0.0→0.4 of timeline)
    _iconScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.4, curve: ElasticOutCurve(0.8)),
      ),
    );
    _iconOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.15, curve: Curves.easeOut),
      ),
    );

    // Streaming waves: staggered fade-in (0.2→0.55)
    _wave1 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.20, 0.40, curve: Curves.easeOut),
      ),
    );
    _wave2 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.30, 0.48, curve: Curves.easeOut),
      ),
    );
    _wave3 = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.38, 0.55, curve: Curves.easeOut),
      ),
    );

    // Title: fade + slide up (0.35→0.60)
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.60, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.60, curve: Curves.easeOut),
      ),
    );

    // Tagline: subtle fade-in (0.50→0.70)
    _taglineOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.50, 0.70, curve: Curves.easeOut),
      ),
    );

    // Fade out everything (0.85→1.0)
    _fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.85, 1.0, curve: Curves.easeIn),
      ),
    );

    _controller.forward();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        context.go('/');
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      body: AnimatedBuilder(
        animation: Listenable.merge([_controller, _glowController]),
        builder: (context, _) {
          return FadeTransition(
            opacity: _fadeOut,
            child: Stack(
              children: [
                // Animated radial glow background
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GlowPainter(
                      color: _accent,
                      intensity: _glowPulse.value,
                      progress: _iconOpacity.value,
                    ),
                  ),
                ),
                // Centered content
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon + waves stack
                      SizedBox(
                        width: 200,
                        height: 200,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Streaming wave arcs
                            Positioned(
                              right: 8,
                              top: 20,
                              child: CustomPaint(
                                size: const Size(60, 60),
                                painter: _WavesPainter(
                                  color: _accent,
                                  wave1: _wave1.value,
                                  wave2: _wave2.value,
                                  wave3: _wave3.value,
                                ),
                              ),
                            ),
                            // App icon
                            Opacity(
                              opacity: _iconOpacity.value,
                              child: Transform.scale(
                                scale: _iconScale.value,
                                child: Image.asset(
                                  'assets/icon/clubtivi-icon.png',
                                  width: 160,
                                  height: 160,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                      // Title with shimmer
                      SlideTransition(
                        position: _titleSlide,
                        child: Opacity(
                          opacity: _titleOpacity.value,
                          child: Shimmer.fromColors(
                            baseColor: Colors.white,
                            highlightColor: _accent.withValues(alpha: 0.9),
                            period: const Duration(milliseconds: 2000),
                            child: const Text(
                              'clubTivi',
                              style: TextStyle(
                                fontSize: 42,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Tagline
                      Opacity(
                        opacity: _taglineOpacity.value,
                        child: Text(
                          'live tv, your way',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w300,
                            color: Colors.white.withValues(alpha: 0.5),
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Radial purple glow behind the logo.
class _GlowPainter extends CustomPainter {
  final Color color;
  final double intensity;
  final double progress;

  _GlowPainter({
    required this.color,
    required this.intensity,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final center = Offset(size.width / 2, size.height / 2 - 40);
    final maxRadius = size.width * 0.6;

    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: 0.15 * intensity * progress),
          color.withValues(alpha: 0.05 * intensity * progress),
          Colors.transparent,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius));

    canvas.drawCircle(center, maxRadius, paint);
  }

  @override
  bool shouldRepaint(_GlowPainter oldDelegate) =>
      intensity != oldDelegate.intensity || progress != oldDelegate.progress;
}

/// Animated streaming wave arcs (like WiFi/broadcast signal).
class _WavesPainter extends CustomPainter {
  final Color color;
  final double wave1;
  final double wave2;
  final double wave3;

  _WavesPainter({
    required this.color,
    required this.wave1,
    required this.wave2,
    required this.wave3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.15, size.height * 0.85);
    const startAngle = -math.pi / 2 - 0.6;
    const sweepAngle = 1.2;

    void drawArc(double radius, double opacity, double strokeWidth) {
      if (opacity <= 0) return;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity * 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }

    drawArc(14, wave1, 2.5);
    drawArc(24, wave2, 2.5);
    drawArc(34, wave3, 2.5);
  }

  @override
  bool shouldRepaint(_WavesPainter oldDelegate) =>
      wave1 != oldDelegate.wave1 ||
      wave2 != oldDelegate.wave2 ||
      wave3 != oldDelegate.wave3;
}
