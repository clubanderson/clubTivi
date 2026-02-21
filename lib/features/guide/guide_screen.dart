import 'package:flutter/material.dart';

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Program Guide')),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_view_week_rounded, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text('EPG Guide', style: TextStyle(fontSize: 20, color: Colors.white54)),
            SizedBox(height: 8),
            Text(
              'Add an EPG source to see program listings',
              style: TextStyle(fontSize: 14, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}
