import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/epg_refresh_service.dart';
import '../providers/provider_manager.dart';
import 'add_epg_source_dialog.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SettingsSection(
            title: 'EPG',
            children: [
              ListTile(
                leading: const Icon(Icons.source_rounded),
                title: const Text('EPG Sources'),
                subtitle: const Text('Manage XMLTV feeds (epg.best, etc.)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openEpgSourcesScreen(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('EPG Mappings'),
                subtitle: const Text('Channel ↔ EPG mapping manager'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Auto-Refresh'),
                subtitle: const Text('Every 12 hours'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          _SettingsSection(
            title: 'Playback',
            children: [
              ListTile(
                leading: const Icon(Icons.speed_rounded),
                title: const Text('Buffer Size'),
                subtitle: const Text('Auto'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.swap_horizontal_circle_rounded),
                title: const Text('Failover Mode'),
                subtitle: const Text('Cold (switch on buffering)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          _SettingsSection(
            title: 'Remote Control',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.web_rounded),
                title: const Text('Web Remote'),
                subtitle: const Text('Allow control from phone browser'),
                value: false,
                onChanged: (value) {},
              ),
              ListTile(
                leading: const Icon(Icons.gamepad_rounded),
                title: const Text('Button Mapping'),
                subtitle: const Text('Customize remote buttons'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          _SettingsSection(
            title: 'About',
            children: [
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('clubTivi'),
                subtitle: Text('v0.1.0 • Open Source • Apache-2.0'),
              ),
              ListTile(
                leading: const Icon(Icons.code_rounded),
                title: const Text('Source Code'),
                subtitle: const Text('github.com/clubanderson/clubTivi'),
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openEpgSourcesScreen(BuildContext context, WidgetRef ref) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _EpgSourcesScreen()),
    );
  }
}

class _EpgSourcesScreen extends ConsumerStatefulWidget {
  const _EpgSourcesScreen();

  @override
  ConsumerState<_EpgSourcesScreen> createState() => _EpgSourcesScreenState();
}

class _EpgSourcesScreenState extends ConsumerState<_EpgSourcesScreen> {
  List<db.EpgSource> _sources = [];
  final Set<String> _refreshing = {};

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    final sources = await ref.read(databaseProvider).getAllEpgSources();
    if (mounted) setState(() => _sources = sources);
  }

  Future<void> _refreshSource(String id) async {
    setState(() => _refreshing.add(id));
    try {
      await ref.read(epgRefreshServiceProvider).refreshSource(id);
      await _loadSources();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Refresh complete')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing.remove(id));
    }
  }

  Future<void> _deleteSource(String id) async {
    await ref.read(databaseProvider).deleteEpgSource(id);
    await _loadSources();
  }

  Future<void> _editSource(db.EpgSource source) async {
    final nameCtrl = TextEditingController(text: source.name);
    final urlCtrl = TextEditingController(text: source.url);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit EPG Source'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
                autofocus: true,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: urlCtrl,
                decoration: const InputDecoration(labelText: 'URL'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == true && mounted) {
      final database = ref.read(databaseProvider);
      await database.upsertEpgSource(db.EpgSourcesCompanion(
        id: Value(source.id),
        name: Value(nameCtrl.text.trim()),
        url: Value(urlCtrl.text.trim()),
        enabled: Value(source.enabled),
      ));
      await _loadSources();
    }
    nameCtrl.dispose();
    urlCtrl.dispose();
  }

  Future<void> _showAddDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const AddEpgSourceDialog(),
    );
    if (result == true) await _loadSources();
  }

  Future<void> _resetToDefaults() async {
    final service = ref.read(epgRefreshServiceProvider);
    await service.resetToDefaultSources();
    await _loadSources();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('EPG sources reset to defaults')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EPG Sources'),
        actions: [
          TextButton.icon(
            onPressed: _resetToDefaults,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reset to Defaults'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddDialog,
        child: const Icon(Icons.add),
      ),
      body: _sources.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No EPG sources configured'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _showAddDialog,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Source'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _sources.length,
              itemBuilder: (context, index) {
                final source = _sources[index];
                final isRefreshing = _refreshing.contains(source.id);
                final lastRefresh = source.lastRefresh;
                return ListTile(
                  title: Text(source.name),
                  subtitle: Text(
                    '${source.url}\n'
                    'Last refresh: ${lastRefresh != null ? _formatTime(lastRefresh) : 'Never'}',
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit source',
                        onPressed: () => _editSource(source),
                      ),
                      if (isRefreshing)
                        const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: () => _refreshSource(source.id),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteSource(source.id),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  String _formatTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.5,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}
