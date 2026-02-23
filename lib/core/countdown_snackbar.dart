import 'package:flutter/material.dart';

/// A SnackBar content row with a subtle circular countdown indicator.
/// Use with `ScaffoldMessenger.of(context).showSnackBar(...)`.
///
/// Example:
/// ```dart
/// ScaffoldMessenger.of(context).showSnackBar(
///   countdownSnackBar('Message here', seconds: 5),
/// );
/// ```
SnackBar countdownSnackBar(
  String message, {
  int seconds = 5,
}) {
  return SnackBar(
    duration: Duration(seconds: seconds),
    content: _CountdownSnackContent(message: message, seconds: seconds),
  );
}

class _CountdownSnackContent extends StatefulWidget {
  final String message;
  final int seconds;
  const _CountdownSnackContent({required this.message, required this.seconds});

  @override
  State<_CountdownSnackContent> createState() => _CountdownSnackContentState();
}

class _CountdownSnackContentState extends State<_CountdownSnackContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(seconds: widget.seconds),
    )..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(widget.message)),
        const SizedBox(width: 12),
        SizedBox(
          width: 20,
          height: 20,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              return CircularProgressIndicator(
                value: 1.0 - _ctrl.value,
                strokeWidth: 2,
                color: Colors.white24,
                backgroundColor: Colors.white.withValues(alpha: 0.05),
              );
            },
          ),
        ),
      ],
    );
  }
}
