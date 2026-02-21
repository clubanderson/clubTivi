import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ChannelsScreen extends StatelessWidget {
  const ChannelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text(
                    'clubTivi',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.tv_rounded),
                    tooltip: 'Guide',
                    onPressed: () => context.push('/guide'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.dns_rounded),
                    tooltip: 'Providers',
                    onPressed: () => context.push('/providers'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.link_rounded),
                    tooltip: 'EPG Mappings',
                    onPressed: () => context.push('/epg-mapping'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_rounded),
                    tooltip: 'Settings',
                    onPressed: () => context.push('/settings'),
                  ),
                ],
              ),
            ),
            // Empty state
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.live_tv_rounded, size: 64, color: Colors.white24),
                    SizedBox(height: 16),
                    Text(
                      'No channels yet',
                      style: TextStyle(fontSize: 20, color: Colors.white54),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Add an IPTV provider to get started',
                      style: TextStyle(fontSize: 14, color: Colors.white38),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
