import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              context.go('/');
            }
          },
        ),
        title: const Text('IPTV Providers'),
      ),
      body: providersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (providers) => FocusTraversalGroup(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // Add Provider button at top — reachable via D-pad
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: FilledButton.icon(
                  autofocus: providers.isEmpty,
                  onPressed: () => showAddProviderDialog(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Provider'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                  ),
                ),
              ),
              if (providers.isNotEmpty) ...[
                const _SectionHeader(title: 'Your Providers'),
                ...providers.map((p) => _ProviderCard(provider: p)),
                const SizedBox(height: 24),
              ],
              const _SectionHeader(title: 'Free TV Providers'),
              const SizedBox(height: 8),
              const Text(
                'Select to add free ad-supported channels',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ...FreeTvProvider.all.map((fp) => _FreeTvProviderTile(
                    freeProvider: fp,
                    isAdded: providers.any((p) => p.id == fp.id),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: Colors.white70,
        ),
      ),
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

/// A well-known free FAST TV provider
class FreeTvProvider {
  final String id;
  final String name;
  final String url;
  final String? epgUrl;
  final IconData icon;
  final String description;

  const FreeTvProvider({
    required this.id,
    required this.name,
    required this.url,
    this.epgUrl,
    this.icon = Icons.live_tv_rounded,
    this.description = '',
  });

  static const all = [
    FreeTvProvider(
      id: 'pluto-tv',
      name: 'Pluto TV',
      url: 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_pluto.m3u',
      description: '400+ free channels — news, movies, sports, comedy',
      icon: Icons.live_tv_rounded,
    ),
    FreeTvProvider(
      id: 'samsung-tv-plus',
      name: 'Samsung TV Plus',
      url: 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_samsung.m3u',
      description: 'Free channels from Samsung — entertainment, news, sports',
      icon: Icons.tv_rounded,
    ),
    FreeTvProvider(
      id: 'plex-tv',
      name: 'Plex FAST',
      url: 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_plex.m3u',
      description: 'Free live TV from Plex — movies, shows, news',
      icon: Icons.play_circle_outline_rounded,
    ),
    FreeTvProvider(
      id: 'stirr-tv',
      name: 'Stirr',
      url: 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_stirr.m3u',
      description: 'Free local & national channels from Sinclair',
      icon: Icons.cell_tower_rounded,
    ),
    FreeTvProvider(
      id: 'xumo-tv',
      name: 'Xumo',
      url: 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_xumo.m3u',
      description: 'Free streaming — news, sports, movies, kids',
      icon: Icons.stream_rounded,
    ),
    FreeTvProvider(
      id: 'tubi-tv',
      name: 'Tubi',
      url: 'https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_tubi.m3u',
      description: 'Free movies and TV shows, ad-supported',
      icon: Icons.movie_filter_rounded,
    ),
    FreeTvProvider(
      id: 'roku-channel',
      name: 'The Roku Channel',
      url: 'https://www.apsattv.com/rok.m3u',
      description: 'Free live TV and on-demand from Roku',
      icon: Icons.connected_tv_rounded,
    ),
    FreeTvProvider(
      id: 'iptv-org-us',
      name: 'IPTV-Org (US)',
      url: 'https://iptv-org.github.io/iptv/countries/us.m3u',
      description: 'Community-maintained US channels aggregator',
      icon: Icons.public_rounded,
    ),
  ];
}

class _FreeTvProviderTile extends ConsumerWidget {
  final FreeTvProvider freeProvider;
  final bool isAdded;

  const _FreeTvProviderTile({
    required this.freeProvider,
    required this.isAdded,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const accent = Color(0xFF6C5CE7);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(freeProvider.icon, color: accent, size: 32),
        title: Text(
          freeProvider.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          freeProvider.description,
          style: const TextStyle(fontSize: 12, color: Colors.white54),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: isAdded
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle, color: Colors.greenAccent, size: 22),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Colors.white38, size: 20),
                    tooltip: 'Re-sync',
                    onPressed: () => _addProvider(context, ref),
                  ),
                ],
              )
            : IconButton(
                icon: const Icon(Icons.add_circle_outline, color: accent, size: 28),
                onPressed: () => _addProvider(context, ref),
              ),
      ),
    );
  }

  Future<void> _addProvider(BuildContext context, WidgetRef ref) async {
    try {
      final manager = ref.read(providerManagerProvider);
      await manager.addM3uProvider(
        id: freeProvider.id,
        name: freeProvider.name,
        url: freeProvider.url,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${freeProvider.name} ${isAdded ? "refreshed" : "added"} — loading channels...')),
      );
    } on ProviderLimitException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add: $e')),
      );
    }
  }
}
