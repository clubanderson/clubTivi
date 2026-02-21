import 'package:flutter/material.dart';

class ProvidersScreen extends StatelessWidget {
  const ProvidersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IPTV Providers')),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_rounded, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text('No providers configured', style: TextStyle(fontSize: 20, color: Colors.white54)),
            SizedBox(height: 8),
            Text(
              'Add an M3U playlist or Xtream Codes login',
              style: TextStyle(fontSize: 14, color: Colors.white38),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // TODO: Open add provider dialog
        },
        icon: const Icon(Icons.add),
        label: const Text('Add Provider'),
      ),
    );
  }
}
