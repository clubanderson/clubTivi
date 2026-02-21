import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/backup_service.dart';
import '../../data/services/epg_refresh_service.dart';
import '../providers/provider_manager.dart';
import 'add_epg_source_dialog.dart';
import '../shows/shows_providers.dart';

Future<void> _exportBackup(BuildContext context) async {
  try {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final path = await BackupService.exportBackup();
    if (context.mounted) Navigator.of(context).pop();
    if (context.mounted) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Backup Created'),
          content: Text('Saved to:\n$path\n\nShare to transfer to another device?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'close'),
              child: const Text('Done'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, 'share'),
              icon: const Icon(Icons.share_rounded, size: 18),
              label: const Text('Share'),
            ),
          ],
        ),
      );
      if (action == 'share') {
        await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
      }
    }
  } catch (e) {
    if (context.mounted) {
      try { Navigator.of(context).pop(); } catch (_) {}
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

Future<void> _importBackup(BuildContext context) async {
  try {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    final filePath = result.files.single.path;
    if (filePath == null) return;

    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore Backup?'),
        content: const Text(
          'This will replace all current data with the backup.\n\n'
          'The app will need to restart after restoring.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.amber),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final summary = await BackupService.importBackup(filePath);
    if (context.mounted) Navigator.of(context).pop();
    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Backup Restored'),
          content: Text('$summary\n\nPlease restart the app for changes to take effect.'),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      try { Navigator.of(context).pop(); } catch (_) {}
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restore failed: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
        title: const Text('Settings'),
      ),
      body: FocusTraversalGroup(
        child: ListView(
          children: [
          _SettingsSection(
            title: 'EPG',
            children: [
              ListTile(
                autofocus: true,
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
            title: 'Display',
            children: [
              _TimeFormatTile(),
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
            title: 'Backup & Restore',
            children: [
              ListTile(
                leading: const Icon(Icons.upload_rounded),
                title: const Text('Export Backup'),
                subtitle: const Text('Save providers, EPG, favorites, API keys'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _exportBackup(context),
              ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Import Backup'),
                subtitle: const Text('Restore from a .clubtivi file'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _importBackup(context),
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
          _ShowsApiKeysSection(),
        ],
        ),
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

class _ShowsApiKeysSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ShowsApiKeysSection> createState() => _ShowsApiKeysSectionState();
}

class _ShowsApiKeysSectionState extends ConsumerState<_ShowsApiKeysSection> {
  final _traktCtrl = TextEditingController();
  final _tmdbCtrl = TextEditingController();
  final _debridCtrl = TextEditingController();
  bool _loaded = false;

  @override
  void dispose() {
    _traktCtrl.dispose();
    _tmdbCtrl.dispose();
    _debridCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(showsApiKeysProvider);
    if (!_loaded && keys.traktClientId.isNotEmpty) {
      _traktCtrl.text = keys.traktClientId;
      _tmdbCtrl.text = keys.tmdbApiKey;
      _debridCtrl.text = keys.debridApiToken;
      _loaded = true;
    }

    return _SettingsSection(
      title: 'Shows & Movies (Trakt + TMDB + Real-Debrid)',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              _apiKeyField(
                controller: _traktCtrl,
                label: 'Trakt Client ID',
                hint: 'Get from trakt.tv/oauth/applications',
                icon: Icons.tv,
                hasValue: keys.hasTraktKey,
              ),
              const SizedBox(height: 8),
              _apiKeyField(
                controller: _tmdbCtrl,
                label: 'TMDB API Key',
                hint: 'API Key or Read Access Token from themoviedb.org',
                icon: Icons.image,
                hasValue: keys.hasTmdbKey,
              ),
              const SizedBox(height: 8),
              _apiKeyField(
                controller: _debridCtrl,
                label: 'Real-Debrid API Token',
                hint: 'Get from real-debrid.com/apitoken',
                icon: Icons.cloud_download,
                hasValue: keys.hasDebridKey,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    await ref.read(showsApiKeysProvider.notifier).save(
                      traktClientId: _traktCtrl.text.trim(),
                      tmdbApiKey: _tmdbCtrl.text.trim(),
                      debridApiToken: _debridCtrl.text.trim(),
                    );
                    // Invalidate shows repo so it picks up new keys
                    ref.invalidate(showsRepositoryProvider);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Shows API keys saved')),
                      );
                    }
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('Save Keys'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _apiKeyField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool hasValue,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: true,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: hasValue
            ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
            : null,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
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

class _TimeFormatTile extends StatefulWidget {
  @override
  State<_TimeFormatTile> createState() => _TimeFormatTileState();
}

class _TimeFormatTileState extends State<_TimeFormatTile> {
  bool _use24Hour = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() => _use24Hour = prefs.getBool('use_24_hour_time') ?? false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.schedule_rounded),
      title: const Text('24-Hour Time'),
      subtitle: Text(_use24Hour ? '14:30' : '2:30 PM'),
      value: _use24Hour,
      onChanged: (value) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('use_24_hour_time', value);
        setState(() => _use24Hour = value);
      },
    );
  }
}
