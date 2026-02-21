import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/epg.dart';
import 'epg_mapping_notifier.dart';
import 'fuzzy_match.dart';

class EpgMappingScreen extends ConsumerStatefulWidget {
  const EpgMappingScreen({super.key});

  @override
  ConsumerState<EpgMappingScreen> createState() => _EpgMappingScreenState();
}

class _EpgMappingScreenState extends ConsumerState<EpgMappingScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(epgMappingProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(epgMappingProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('EPG Mappings'),
        actions: [
          TextButton.icon(
            onPressed: state.isLoading
                ? null
                : () async {
                    final stats =
                        await ref.read(epgMappingProvider.notifier).runAutoMapper();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                          'Auto-mapped ${stats.mapped} channels, '
                          '${stats.suggested} suggestions, '
                          '${stats.unmapped} unmapped '
                          '(${stats.elapsed.inMilliseconds}ms)',
                        ),
                      ));
                    }
                  },
            icon: const Icon(Icons.auto_fix_high_rounded),
            label: const Text('Auto-Map'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              // TODO: Handle import/export
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'import', child: Text('Import Mappings')),
              PopupMenuItem(value: 'export', child: Text('Export Mappings')),
              PopupMenuItem(value: 'clear', child: Text('Clear All')),
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
                SegmentedButton<MappingFilter>(
                  segments: [
                    ButtonSegment(
                      value: MappingFilter.all,
                      label: Text('All (${state.entries.length})'),
                    ),
                    ButtonSegment(
                      value: MappingFilter.mapped,
                      label: Text('✅ ${state.mappedCount}'),
                    ),
                    ButtonSegment(
                      value: MappingFilter.suggested,
                      label: Text('🟡 ${state.suggestedCount}'),
                    ),
                    ButtonSegment(
                      value: MappingFilter.unmapped,
                      label: Text('🔴 ${state.unmappedCount}'),
                    ),
                  ],
                  selected: {state.filter},
                  onSelectionChanged: (value) {
                    ref.read(epgMappingProvider.notifier).setFilter(value.first);
                  },
                ),
                const SizedBox(width: 12),
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
                      ref.read(epgMappingProvider.notifier).setSearch(value);
                    },
                  ),
                ),
              ],
            ),
          ),

          // Loading indicator
          if (state.isLoading) const LinearProgressIndicator(),

          // Channel mapping list
          Expanded(
            child: state.filteredEntries.isEmpty
                ? _EmptyState(
                    hasChannels: state.entries.isNotEmpty,
                    filter: state.filter,
                  )
                : ListView.builder(
                    itemCount: state.filteredEntries.length,
                    itemBuilder: (context, index) {
                      return _MappingTile(
                        entry: state.filteredEntries[index],
                        onTap: () => _showMappingDialog(
                          state.filteredEntries[index],
                        ),
                        onRemove: () {
                          final e = state.filteredEntries[index];
                          ref.read(epgMappingProvider.notifier).removeMapping(
                            e.channel.id,
                            e.channel.providerId,
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showMappingDialog(ChannelMappingEntry entry) {
    showDialog(
      context: context,
      builder: (context) => _ManualMappingDialog(entry: entry),
    );
  }
}

class _MappingTile extends StatelessWidget {
  final ChannelMappingEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _MappingTile({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final statusIcon = entry.isMapped
        ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
        : entry.isSuggested
            ? const Icon(Icons.help, color: Colors.orange, size: 20)
            : const Icon(Icons.cancel, color: Colors.red, size: 20);

    final confidenceText = entry.mapping != null
        ? '${(entry.mapping!.confidence * 100).toInt()}%'
        : '';

    return ListTile(
      leading: statusIcon,
      title: Text(entry.channel.name),
      subtitle: entry.mappedEpgName != null
          ? Text(
              '→ ${entry.mappedEpgName} $confidenceText',
              style: TextStyle(
                color: entry.isSuggested ? Colors.orange : Colors.green,
              ),
            )
          : Text(
              entry.channel.tvgId ?? 'No EPG ID',
              style: const TextStyle(color: Colors.white38),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.isLocked)
            const Icon(Icons.lock, size: 16, color: Colors.white38),
          if (entry.isMapped || entry.isSuggested)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Remove mapping',
              onPressed: onRemove,
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _ManualMappingDialog extends StatefulWidget {
  final ChannelMappingEntry entry;

  const _ManualMappingDialog({required this.entry});

  @override
  State<_ManualMappingDialog> createState() => _ManualMappingDialogState();
}

class _ManualMappingDialogState extends State<_ManualMappingDialog> {
  final _searchController = TextEditingController();

  List<MappingCandidate> get _filteredSuggestions {
    final query = _searchController.text;
    final suggestions = widget.entry.suggestions;
    if (query.isEmpty) return suggestions;

    final scored = <(MappingCandidate, double)>[];
    for (final s in suggestions) {
      final fields = [s.epgDisplayName, s.epgChannelId];
      final score = fuzzyMatch(query, fields);
      final tokens = tokenizeQuery(query);
      if (tokens.isNotEmpty && score >= tokens.length * 0.5) {
        scored.add((s, score));
      }
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.map((s) => s.$1).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredSuggestions = _filteredSuggestions;
    return AlertDialog(
      title: Text('Map: ${widget.entry.channel.name}'),
      content: SizedBox(
        width: 400,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Channel info
            if (widget.entry.channel.tvgId != null)
              Text(
                'tvg-id: ${widget.entry.channel.tvgId}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            if (widget.entry.channel.groupTitle != null)
              Text(
                'Group: ${widget.entry.channel.groupTitle}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            const SizedBox(height: 12),

            // Search EPG channels
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search EPG channels...',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),

            // Suggestions
            if (filteredSuggestions.isNotEmpty) ...[
              const Text(
                'Suggestions:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 4),
            ],

            Expanded(
              child: filteredSuggestions.isEmpty
                  ? const Center(
                      child: Text(
                        'No EPG channels available.\nAdd an EPG source first.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filteredSuggestions.length,
                      itemBuilder: (context, index) {
                        final s = filteredSuggestions[index];
                        return ListTile(
                          dense: true,
                          title: Text(s.epgDisplayName),
                          subtitle: Text(
                            '${s.epgChannelId} • ${(s.confidence * 100).toInt()}%',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: Text(
                            s.matchReasons.join(', '),
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white38),
                          ),
                          onTap: () {
                            Navigator.of(context).pop(s);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasChannels;
  final MappingFilter filter;

  const _EmptyState({required this.hasChannels, required this.filter});

  @override
  Widget build(BuildContext context) {
    if (!hasChannels) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off_rounded, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text('No channels to map',
                style: TextStyle(fontSize: 20, color: Colors.white54)),
            SizedBox(height: 8),
            Text('Add a provider and EPG source first',
                style: TextStyle(fontSize: 14, color: Colors.white38)),
          ],
        ),
      );
    }

    return Center(
      child: Text(
        'No ${filter.name} channels',
        style: const TextStyle(fontSize: 16, color: Colors.white38),
      ),
    );
  }
}
