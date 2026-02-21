import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/local/database.dart' as db;
import 'add_provider_dialog.dart';
import 'provider_manager.dart';

/// Watches all providers as a stream for reactive UI updates.
final _providersStreamProvider = StreamProvider<List<db.Provider>>((ref) {
  final database = ref.watch(databaseProvider);
  return database.select(database.providers).watch();
});

class ProvidersScreen extends ConsumerWidget {
  const ProvidersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(_providersStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('IPTV Providers')),
      body: providersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (providers) => providers.isEmpty
            ? const _EmptyState()
            : _ProviderList(providers: providers),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAddProviderDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Add Provider'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_rounded, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('No providers configured',
              style: TextStyle(fontSize: 20, color: Colors.white54)),
          SizedBox(height: 8),
          Text(
            'Add an M3U playlist or Xtream Codes login',
            style: TextStyle(fontSize: 14, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

class _ProviderList extends ConsumerWidget {
  final List<db.Provider> providers;
  const _ProviderList({required this.providers});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: providers.length,
      itemBuilder: (context, index) =>
          _ProviderCard(provider: providers[index]),
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  final db.Provider provider;
  const _ProviderCard({required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const accent = Color(0xFF6C5CE7);
    final isXtream = provider.type == 'xtream';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              isXtream ? Icons.api_rounded : Icons.playlist_play_rounded,
              color: accent,
              size: 36,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    provider.name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isXtream ? 'Xtream' : 'M3U',
                          style: const TextStyle(
                              fontSize: 11, color: accent),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '— channels',
                        style: TextStyle(
                            fontSize: 12, color: Colors.white.withValues(alpha: 0.4)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              tooltip: 'Refresh',
              onPressed: () async {
                final manager = ref.read(providerManagerProvider);
                try {
                  final count = await manager.refreshProvider(provider.id);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Loaded $count channels')),
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Refresh failed: $e')),
                  );
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 20, color: Colors.redAccent),
              tooltip: 'Delete',
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A2E),
                    title: const Text('Delete Provider'),
                    content: Text('Remove "${provider.name}" and all its channels?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete',
                            style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  final manager = ref.read(providerManagerProvider);
                  await manager.deleteProvider(provider.id);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
