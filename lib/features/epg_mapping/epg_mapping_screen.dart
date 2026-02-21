import 'package:flutter/material.dart';

class EpgMappingScreen extends StatelessWidget {
  const EpgMappingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EPG Mappings'),
        actions: [
          TextButton.icon(
            onPressed: () {
              // TODO: Run auto-mapper
            },
            icon: const Icon(Icons.auto_fix_high_rounded),
            label: const Text('Auto-Map'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              // TODO: Handle menu actions
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'import', child: Text('Import Mappings')),
              const PopupMenuItem(value: 'export', child: Text('Export Mappings')),
              const PopupMenuItem(value: 'clear', child: Text('Clear All')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Status filter
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('All')),
                    ButtonSegment(value: 'mapped', label: Text('✅ Mapped')),
                    ButtonSegment(value: 'suggested', label: Text('🟡 Suggested')),
                    ButtonSegment(value: 'unmapped', label: Text('🔴 Unmapped')),
                  ],
                  selected: const {'all'},
                  onSelectionChanged: (value) {
                    // TODO: Filter
                  },
                ),
                const SizedBox(width: 12),
                // Search
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search channels...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      isDense: true,
                    ),
                    onChanged: (value) {
                      // TODO: Search
                    },
                  ),
                ),
              ],
            ),
          ),
          // Stats bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.white.withValues(alpha: 0.05),
            child: const Row(
              children: [
                _StatChip(label: 'Mapped', count: 0, color: Colors.green),
                SizedBox(width: 16),
                _StatChip(label: 'Suggested', count: 0, color: Colors.orange),
                SizedBox(width: 16),
                _StatChip(label: 'Unmapped', count: 0, color: Colors.red),
              ],
            ),
          ),
          // Channel mapping list
          const Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.link_off_rounded, size: 64, color: Colors.white24),
                  SizedBox(height: 16),
                  Text(
                    'No channels to map',
                    style: TextStyle(fontSize: 20, color: Colors.white54),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Add a provider and EPG source first',
                    style: TextStyle(fontSize: 14, color: Colors.white38),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatChip({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count $label',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ],
    );
  }
}
