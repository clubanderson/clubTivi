import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
        title: const Text('IPTV Providers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 28),
            tooltip: 'Add Provider',
            onPressed: () => showAddProviderDialog(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: providersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (providers) => FocusTraversalGroup(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              if (providers.isNotEmpty) ...[
                const _SectionHeader(title: 'Your Providers'),
                ...providers.map((p) => _ProviderCard(provider: p)),
                const SizedBox(height: 24),
              ],
              const _SectionHeader(title: 'Free TV Providers'),
              const SizedBox(height: 4),
              ...FreeTvProvider.all.map((fp) => _FreeTvProviderTile(
                    freeProvider: fp,
                    isAdded: providers.any((p) => p.id == fp.id),
                  )),
            ],
          ),
        ),
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

class _ProviderCard extends ConsumerStatefulWidget {
  final db.Provider provider;
  const _ProviderCard({required this.provider});

  @override
  ConsumerState<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends ConsumerState<_ProviderCard> {
  bool _refreshing = false;

  /// Refresh this provider's catalog, showing progress on the card itself.
  /// Re-entrant calls (double-tap, D-pad repeat) are ignored while running.
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final manager = ref.read(providerManagerProvider);
    try {
      final count = await manager.refreshProvider(widget.provider.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded $count channels')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Refresh failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF6C5CE7);
    final isXtream = widget.provider.type == 'xtream';

    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          // SELECT on provider card → refresh
          _refresh();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: hasFocus
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: accent, width: 2),
            )
          : null,
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
                    widget.provider.name,
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
                        _refreshing
                            ? 'Refreshing…'
                            : isXtream
                                ? '— channels, movies & series'
                                : '- channels',
                        style: TextStyle(
                            fontSize: 12,
                            color: _refreshing
                                ? accent
                                : Colors.white.withValues(alpha: 0.4)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_refreshing)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accent,
                  ),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Refresh',
                onPressed: _refresh,
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 20, color: Colors.redAccent),
              tooltip: 'Delete',
              onPressed: _refreshing ? null : () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A2E),
                    title: Row(
                      children: [
                        const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                        const SizedBox(width: 8),
                        Text(widget.provider.name),
                      ],
                    ),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context, false),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                        onPressed: () => Navigator.pop(context, true),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  final manager = ref.read(providerManagerProvider);
                  await manager.deleteProvider(widget.provider.id);
                }
              },
            ),
          ],
        ),
      ),
    );
        },  // Builder builder
      ),  // Builder
    );  // Focus
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

class _FreeTvProviderTile extends ConsumerStatefulWidget {
  final FreeTvProvider freeProvider;
  final bool isAdded;

  const _FreeTvProviderTile({
    required this.freeProvider,
    required this.isAdded,
  });

  @override
  ConsumerState<_FreeTvProviderTile> createState() =>
      _FreeTvProviderTileState();
}

class _FreeTvProviderTileState extends ConsumerState<_FreeTvProviderTile> {
  bool _refreshing = false;

  /// Add (or re-sync) this free provider, showing progress on the tile.
  /// Re-entrant calls are ignored while a sync is running.
  Future<void> _addProvider() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final manager = ref.read(providerManagerProvider);
      await manager.addM3uProvider(
        id: widget.freeProvider.id,
        name: widget.freeProvider.name,
        url: widget.freeProvider.url,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.freeProvider.name} ${widget.isAdded ? "refreshed" : "added"}',
          ),
        ),
      );
    } on ProviderLimitException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add: $e')),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF6C5CE7);
    final freeProvider = widget.freeProvider;
    final isAdded = widget.isAdded;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            _addProvider();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _refreshing ? null : _addProvider,
              child: Container(
                decoration: hasFocus
                    ? BoxDecoration(
                        border: Border.all(color: accent, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      )
                    : null,
                child: ListTile(
                  leading: Icon(freeProvider.icon, color: accent, size: 32),
                  title: Text(
                    freeProvider.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _refreshing
                        ? (isAdded ? 'Refreshing…' : 'Adding…')
                        : freeProvider.description,
                    style: TextStyle(
                        fontSize: 12,
                        color: _refreshing ? accent : Colors.white54),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _refreshing
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accent,
                            ),
                          ),
                        )
                      : isAdded
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.check_circle,
                                    color: Colors.greenAccent, size: 22),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.refresh_rounded,
                                      color: Colors.white38, size: 20),
                                  tooltip: 'Re-sync',
                                  onPressed: _addProvider,
                                ),
                              ],
                            )
                          : const Icon(Icons.add_circle_outline,
                              color: accent, size: 28),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
