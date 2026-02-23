import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/countdown_snackbar.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/services/app_update_service.dart';
import '../../data/services/backup_service.dart';
import '../../data/services/epg_refresh_service.dart';
import '../providers/provider_manager.dart';
import '../remote/web_remote_server.dart';
import 'add_epg_source_dialog.dart';
import '../shows/shows_providers.dart';
import '../../data/datasources/remote/trakt_client.dart';
import '../../data/datasources/remote/tmdb_client.dart';

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
      // Offer to save to a user-chosen location or share
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Backup Created'),
          content: Text('Saved to:\n$path'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'close'),
              child: const Text('Done'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Save As…'),
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
      } else if (action == 'save') {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Backup',
          fileName: path.split('/').last,
          type: FileType.any,
        );
        if (savePath != null) {
          await File(path).copy(savePath);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Saved to $savePath')),
            );
          }
        }
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

Future<void> _checkForUpdates(BuildContext context) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  final release = await AppUpdateService.checkForUpdate();

  if (!context.mounted) return;
  Navigator.of(context).pop(); // dismiss spinner

  if (release == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      countdownSnackBar('Could not check for updates', seconds: 5),
    );
    return;
  }

  if (!release.isNewer) {
    ScaffoldMessenger.of(context).showSnackBar(
      countdownSnackBar(
        'You\'re up to date! (v${AppUpdateService.currentVersion})',
        seconds: 5,
      ),
    );
    return;
  }

  // New version available
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Text('Update Available — v${release.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Current: v${AppUpdateService.currentVersion}\n'
            'Latest: v${release.version}\n',
          ),
          if (release.body.isNotEmpty)
            Text(
              release.body.length > 300
                  ? '${release.body.substring(0, 300)}…'
                  : release.body,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'later'),
          child: const Text('Later'),
        ),
        if (release.apkDownloadUrl != null)
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'install'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download & Install'),
          ),
      ],
    ),
  );

  if (action == 'install' && release.apkDownloadUrl != null && context.mounted) {
    _downloadUpdate(context, release.apkDownloadUrl!);
  }
}

Future<void> _downloadUpdate(BuildContext context, String apkUrl) async {
  double progress = 0;
  late StateSetter dialogSetState;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        dialogSetState = setState;
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Downloading Update…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 12),
              Text('${(progress * 100).toStringAsFixed(0)}%'),
            ],
          ),
        );
      },
    ),
  );

  await AppUpdateService.downloadAndInstall(
    apkUrl,
    onProgress: (p) {
      try { dialogSetState(() => progress = p); } catch (_) {}
    },
    onError: (error) {
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red),
        );
      }
    },
  );
  // Dismiss dialog after install intent launches
  if (context.mounted) Navigator.of(context).pop();
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _localIp = '';

  @override
  void initState() {
    super.initState();
    _detectLocalIp();
  }

  Future<void> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            if (mounted) setState(() => _localIp = addr.address);
            return;
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final webRemote = ref.watch(webRemoteServerProvider);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final pf = FocusManager.instance.primaryFocus;
          if (pf?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
            pf!.unfocus();
            return;
          }
          Future.microtask(() {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
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
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            } else {
              context.go('/');
            }
          },
        ),
        title: const Text('Settings'),
      ),
      body: FocusTraversalGroup(
        child: ListView(
          children: [
          _SettingsSection(
            title: 'Providers',
            children: [
              ListTile(
                autofocus: true,
                leading: const Icon(Icons.dns_rounded),
                title: const Text('Manage Providers'),
                subtitle: const Text('M3U, Xtream Codes, free TV sources'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/providers'),
              ),
            ],
          ),
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
                onTap: () => context.push('/epg-mapping'),
              ),
              _AutoRefreshTile(),
            ],
          ),
          _SettingsSection(
            title: 'Playback',
            children: [
              _UserAgentTile(),
              _BufferSizeTile(),
              _FailoverModeTile(),
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
                subtitle: Text(webRemote.isRunning
                    ? 'Running — open http://${_localIp.isNotEmpty ? _localIp : '<detecting...>'}:${webRemote.port} on your phone'
                    : 'Allow control from phone browser'),
                value: webRemote.isRunning,
                onChanged: (value) async {
                  if (value) {
                    await webRemote.start();
                  } else {
                    await webRemote.stop();
                  }
                  setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.gamepad_rounded),
                title: const Text('Button Mapping'),
                subtitle: const Text('Customize remote buttons'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showButtonMappingInfo(context),
              ),
            ],
          ),
          _SettingsSection(
            title: 'Recordings',
            children: [
              _RecordingsFolderTile(),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('How it works'),
                subtitle: const Text('Tap to learn about recording setup'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showRecordingHelp(context),
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
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('clubTivi'),
                subtitle: Text('v${AppUpdateService.currentVersion} • Open Source • Apache-2.0'),
              ),
              ListTile(
                leading: const Icon(Icons.system_update_rounded),
                title: const Text('Check for Updates'),
                subtitle: const Text('Download latest version from GitHub'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _checkForUpdates(context),
              ),
              ListTile(
                leading: const Icon(Icons.code_rounded),
                title: const Text('Source Code'),
                subtitle: const Text('github.com/clubanderson/clubTivi'),
                onTap: () => launchUrl(Uri.parse('https://github.com/clubanderson/clubTivi')),
              ),
            ],
          ),
          _ShowsApiKeysSection(),
        ],
        ),
      ),
    ),
      ),
    );
  }

  void _openEpgSourcesScreen(BuildContext context, WidgetRef ref) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _EpgSourcesScreen()),
    );
  }

  void _showRecordingHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recording Setup'),
        content: const SingleChildScrollView(
          child: Text(
            '1. Choose a folder\n'
            '   Tap "Recording Folder" above and pick any folder on your device.\n'
            '   clubTivi will save all recordings there.\n\n'
            '2. Start recording\n'
            '   While watching a channel, tap the record (●) button in the\n'
            '   player controls. Recording starts immediately.\n\n'
            '3. Stop recording\n'
            '   Tap the record button again, or change channels.\n'
            '   The file is saved as MP4 in your chosen folder.\n\n'
            '4. View recordings\n'
            '   Open "Recordings" in the sidebar to browse and play\n'
            '   your saved recordings.\n\n'
            'Tips:\n'
            '• Make sure you have enough disk space\n'
            '• Recordings use the original stream quality\n'
            '• On macOS: the folder picker grants clubTivi access automatically\n'
            '• On Android: choose a folder in internal storage or SD card',
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
        ],
      ),
    );
  }

  void _showButtonMappingInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Button Mapping'),
        content: const Text(
          'clubTivi supports the following remote controls:\n\n'
          '• IR remotes (via Android TV / Fire TV)\n'
          '• Bluetooth gamepads\n'
          '• Keyboard shortcuts\n'
          '• Web Remote (enable in Remote Control settings)\n\n'
          'Default mappings:\n'
          '  ↑↓←→  Navigate\n'
          '  Enter/OK  Select / Play\n'
          '  Esc/Back  Go back\n'
          '  Space  Play/Pause\n'
          '  M  Mute\n'
          '  ↑↓ (in player)  Volume\n'
          '  ←→ (in player)  Seek ±10s\n\n'
          'Custom mapping editor coming soon.',
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
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
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await ref.read(databaseProvider).getAllEpgSources();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
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
    try {
      await ref.read(databaseProvider).deleteEpgSource(id);
      if (!mounted) return;
      await _loadSources();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
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
    if (result == true && mounted) await _loadSources();
  }

  Future<void> _resetToDefaults() async {
    try {
      final service = ref.read(epgRefreshServiceProvider);
      await service.resetToDefaultSources();
      if (!mounted) return;
      await _loadSources();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('EPG sources reset to defaults')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reset failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          final pf = FocusManager.instance.primaryFocus;
          if (pf?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
            pf!.unfocus();
            return;
          }
          Future.microtask(() {
            Navigator.of(context).pop();
          });
        },
      },
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Error loading sources: $_error'),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () {
                          setState(() { _loading = true; _error = null; });
                          _loadSources();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _sources.isEmpty
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
                  leading: Switch(
                    value: source.enabled,
                    onChanged: (val) async {
                      final database = ref.read(databaseProvider);
                      await database.upsertEpgSource(db.EpgSourcesCompanion(
                        id: Value(source.id),
                        name: Value(source.name),
                        url: Value(source.url),
                        enabled: Value(val),
                      ));
                      await _loadSources();
                    },
                  ),
                  title: Text(
                    source.name,
                    style: TextStyle(
                      color: source.enabled ? null : Colors.white38,
                    ),
                  ),
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
    ),
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
  bool _loaded = false;
  bool _traktVerifying = false;
  bool? _traktVerified;
  bool _tmdbVerifying = false;
  bool? _tmdbVerified;

  @override
  void dispose() {
    _traktCtrl.dispose();
    _tmdbCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(showsApiKeysProvider);
    if (!_loaded && (keys.traktClientId.isNotEmpty || keys.tmdbApiKey.isNotEmpty)) {
      _traktCtrl.text = keys.traktClientId;
      _tmdbCtrl.text = keys.tmdbApiKey;
      _loaded = true;
    }

    final debridCount = keys.configuredDebridCount;

    return _SettingsSection(
      title: 'Shows & Movies',
      children: [
        _ApiKeyCard(
          title: 'Trakt',
          subtitle: keys.hasTraktKey ? 'Configured ✓' : 'Not configured',
          isConfigured: keys.hasTraktKey,
          icon: Icons.tv_rounded,
          controller: _traktCtrl,
          tokenLabel: 'Client ID',
          tokenHint: 'trakt.tv/oauth/applications',
          tokenUrl: 'https://trakt.tv/oauth/applications',
          isVerifying: _traktVerifying,
          verifyResult: _traktVerified,
          onSave: () => _saveTrakt(),
          onVerify: () => _verifyTrakt(),
          onClear: () {
            _traktCtrl.clear();
            _saveTrakt();
          },
        ),
        _ApiKeyCard(
          title: 'TMDB',
          subtitle: keys.hasTmdbKey ? 'Configured ✓' : 'Not configured',
          isConfigured: keys.hasTmdbKey,
          icon: Icons.image_rounded,
          controller: _tmdbCtrl,
          tokenLabel: 'API Key',
          tokenHint: 'themoviedb.org/settings/api',
          tokenUrl: 'https://www.themoviedb.org/settings/api',
          isVerifying: _tmdbVerifying,
          verifyResult: _tmdbVerified,
          onSave: () => _saveTmdb(),
          onVerify: () => _verifyTmdb(),
          onClear: () {
            _tmdbCtrl.clear();
            _saveTmdb();
          },
        ),
        ListTile(
          leading: const Icon(Icons.cloud_download_rounded),
          title: const Text('Debrid Services'),
          subtitle: Text(
            debridCount > 0
                ? '$debridCount service${debridCount > 1 ? 's' : ''} configured'
                : 'Not configured',
            style: TextStyle(
              fontSize: 12,
              color: debridCount > 0 ? Colors.green : Colors.white38,
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/debrid-services'),
        ),
      ],
    );
  }

  Future<void> _saveTrakt() async {
    final keys = ref.read(showsApiKeysProvider);
    await ref.read(showsApiKeysProvider.notifier).save(
      traktClientId: _traktCtrl.text.trim(),
      tmdbApiKey: keys.tmdbApiKey,
      debridTokens: keys.debridTokens,
    );
    ref.invalidate(showsRepositoryProvider);
    if (mounted) {
      setState(() => _traktVerified = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Trakt key saved')),
      );
    }
  }

  Future<void> _saveTmdb() async {
    final keys = ref.read(showsApiKeysProvider);
    await ref.read(showsApiKeysProvider.notifier).save(
      traktClientId: keys.traktClientId,
      tmdbApiKey: _tmdbCtrl.text.trim(),
      debridTokens: keys.debridTokens,
    );
    ref.invalidate(showsRepositoryProvider);
    if (mounted) {
      setState(() => _tmdbVerified = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TMDB key saved')),
      );
    }
  }

  Future<void> _verifyTrakt() async {
    final token = _traktCtrl.text.trim();
    if (token.isEmpty) return;
    setState(() { _traktVerifying = true; _traktVerified = null; });
    try {
      final client = TraktClient(clientId: token);
      final results = await client.getTrendingShows(limit: 1);
      if (mounted) setState(() => _traktVerified = results.isNotEmpty);
    } catch (_) {
      if (mounted) setState(() => _traktVerified = false);
    } finally {
      if (mounted) setState(() => _traktVerifying = false);
    }
  }

  Future<void> _verifyTmdb() async {
    final token = _tmdbCtrl.text.trim();
    if (token.isEmpty) return;
    setState(() { _tmdbVerifying = true; _tmdbVerified = null; });
    try {
      final client = TmdbClient(apiKey: token);
      final results = await client.getTrendingTv();
      if (mounted) setState(() => _tmdbVerified = results.isNotEmpty);
    } catch (_) {
      if (mounted) setState(() => _tmdbVerified = false);
    } finally {
      if (mounted) setState(() => _tmdbVerifying = false);
    }
  }

}

/// Reusable card for API key configuration (matches debrid card style).
class _ApiKeyCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final bool isConfigured;
  final IconData icon;
  final TextEditingController controller;
  final String tokenLabel;
  final String tokenHint;
  final String tokenUrl;
  final bool isVerifying;
  final bool? verifyResult;
  final VoidCallback onSave;
  final VoidCallback onVerify;
  final VoidCallback onClear;

  const _ApiKeyCard({
    required this.title,
    required this.subtitle,
    required this.isConfigured,
    required this.icon,
    required this.controller,
    required this.tokenLabel,
    required this.tokenHint,
    required this.tokenUrl,
    required this.isVerifying,
    this.verifyResult,
    required this.onSave,
    required this.onVerify,
    required this.onClear,
  });

  @override
  State<_ApiKeyCard> createState() => _ApiKeyCardState();
}

class _ApiKeyCardState extends State<_ApiKeyCard> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = !widget.isConfigured;
  }

  @override
  Widget build(BuildContext context) {
    final hasToken = widget.controller.text.trim().isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: const Color(0xFF16213E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              widget.icon,
              color: widget.isConfigured
                  ? const Color(0xFF6C5CE7)
                  : Colors.white30,
            ),
            title: Text(
              widget.title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: widget.isConfigured ? Colors.white : Colors.white70,
              ),
            ),
            subtitle: Text(
              widget.subtitle,
              style: TextStyle(
                fontSize: 12,
                color: widget.isConfigured ? Colors.green : Colors.white38,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.isConfigured)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20,
                        color: Colors.redAccent),
                    tooltip: 'Remove',
                    onPressed: widget.onClear,
                  ),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: Colors.white38,
                ),
              ],
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: widget.controller,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: widget.tokenLabel,
                      hintText: widget.tokenHint,
                      prefixIcon: const Icon(Icons.vpn_key, size: 20),
                      suffixIcon: _buildSuffixIcon(),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: hasToken ? widget.onSave : null,
                          icon: const Icon(Icons.save, size: 18),
                          label: const Text('Save'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: hasToken && !widget.isVerifying
                            ? widget.onVerify
                            : null,
                        icon: widget.isVerifying
                            ? const SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.verified_outlined, size: 18),
                        label: const Text('Verify'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () {
                          final url = Uri.parse(widget.tokenUrl);
                          launchUrl(url, mode: LaunchMode.externalApplication);
                        },
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Get Key'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget? _buildSuffixIcon() {
    if (widget.isVerifying) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (widget.verifyResult == true) {
      return const Icon(Icons.check_circle, color: Colors.green, size: 20);
    }
    if (widget.verifyResult == false) {
      return const Icon(Icons.error, color: Colors.redAccent, size: 20);
    }
    if (widget.isConfigured) {
      return const Icon(Icons.check_circle, color: Colors.green, size: 20);
    }
    return null;
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

class _UserAgentTile extends StatefulWidget {
  @override
  State<_UserAgentTile> createState() => _UserAgentTileState();
}

class _UserAgentTileState extends State<_UserAgentTile> {
  String _userAgent = 'Default';
  static const _key = 'playback_user_agent';
  static const _presets = [
    'Default',
    'VLC/3.0',
    'Kodi/20.0',
    'ExoPlayer',
    'Lavf/60',
    'Mozilla/5.0',
  ];

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _userAgent = prefs.getString(_key) ?? 'Default');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.badge_rounded),
      title: const Text('User Agent'),
      subtitle: Text(_userAgent, style: const TextStyle(color: Colors.purpleAccent)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final controller = TextEditingController(
          text: _userAgent == 'Default' ? '' : _userAgent,
        );
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('User Agent'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Enter custom user agent...',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Presets', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ),
                const SizedBox(height: 8),
                ...List.generate(_presets.length, (i) => ListTile(
                  dense: true,
                  title: Text(_presets[i]),
                  selected: _userAgent == _presets[i],
                  onTap: () => Navigator.pop(ctx, _presets[i]),
                )),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final custom = controller.text.trim();
                  Navigator.pop(ctx, custom.isEmpty ? 'Default' : custom);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
        if (picked != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_key, picked);
          setState(() => _userAgent = picked);
        }
      },
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

class _AutoRefreshTile extends StatefulWidget {
  @override
  State<_AutoRefreshTile> createState() => _AutoRefreshTileState();
}

class _AutoRefreshTileState extends State<_AutoRefreshTile> {
  int _hours = 12;
  static const _key = 'epg_auto_refresh_hours';
  static const _options = [1, 4, 6, 12, 24, 48];

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _hours = prefs.getInt(_key) ?? 12);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.refresh_rounded),
      title: const Text('Auto-Refresh'),
      subtitle: Text('Every $_hours hours'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final picked = await showDialog<int>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Auto-Refresh Interval'),
            children: [
              for (final h in _options)
                RadioListTile<int>(
                  title: Text('Every $h hour${h == 1 ? '' : 's'}'),
                  value: h,
                  groupValue: _hours,
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),
            ],
          ),
        );
        if (picked != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(_key, picked);
          setState(() => _hours = picked);
        }
      },
    );
  }
}

class _BufferSizeTile extends StatefulWidget {
  @override
  State<_BufferSizeTile> createState() => _BufferSizeTileState();
}

class _BufferSizeTileState extends State<_BufferSizeTile> {
  String _buffer = 'Auto';
  static const _key = 'playback_buffer_size';
  static const _options = {
    'Auto': 'Auto',
    'None': 'None',
    '1 MB (Small)': '1',
    '2 MB (Small)': '2',
    '4 MB (Medium)': '4',
    '8 MB (Large)': '8',
    '16 MB (XL)': '16',
  };

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _buffer = prefs.getString(_key) ?? 'Auto');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.speed_rounded),
      title: const Text('Buffer Size'),
      subtitle: Text(_buffer),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Buffer Size'),
            children: [
              for (final entry in _options.entries)
                RadioListTile<String>(
                  title: Text(entry.key),
                  value: entry.key,
                  groupValue: _buffer,
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),
            ],
          ),
        );
        if (picked != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_key, picked);
          setState(() => _buffer = picked);
        }
      },
    );
  }
}

class _FailoverModeTile extends StatefulWidget {
  @override
  State<_FailoverModeTile> createState() => _FailoverModeTileState();
}

class _FailoverModeTileState extends State<_FailoverModeTile> {
  String _mode = 'cold';
  static const _key = 'failover_mode';
  static const _options = {
    'cold': 'Cold (switch on buffering)',
    'warm': 'Warm (background probes)',
    'off': 'Off',
  };

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _mode = prefs.getString(_key) ?? 'cold');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.swap_horizontal_circle_rounded),
      title: const Text('Failover Mode'),
      subtitle: Text(_options[_mode] ?? _mode),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Failover Mode'),
            children: [
              for (final entry in _options.entries)
                RadioListTile<String>(
                  title: Text(entry.value),
                  subtitle: entry.key == 'warm'
                      ? const Text('Monitors alternate streams in background', style: TextStyle(fontSize: 12))
                      : entry.key == 'cold'
                          ? const Text('Switches only when buffering detected', style: TextStyle(fontSize: 12))
                          : null,
                  value: entry.key,
                  groupValue: _mode,
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),
            ],
          ),
        );
        if (picked != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_key, picked);
          setState(() => _mode = picked);
        }
      },
    );
  }
}

class _RecordingsFolderTile extends StatefulWidget {
  @override
  State<_RecordingsFolderTile> createState() => _RecordingsFolderTileState();
}

class _RecordingsFolderTileState extends State<_RecordingsFolderTile> {
  String? _folder;
  static const _key = 'recordings_folder';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _folder = prefs.getString(_key));
    });
  }

  Future<void> _pickLocal() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose where to save recordings',
    );
    if (result != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, result);
      setState(() => _folder = result);
    }
  }

  Future<void> _enterNetworkPath(BuildContext context) async {
    final controller = TextEditingController(
      text: _folder != null && _folder!.startsWith('smb://') || 
            _folder != null && _folder!.startsWith('nfs://') ||
            _folder != null && _folder!.startsWith('afp://') ||
            _folder != null && _folder!.startsWith('ftp://') ||
            _folder != null && _folder!.startsWith('webdav://')
          ? _folder : '',
    );
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Network Storage'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the network path to your shared folder:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'smb://192.168.1.100/Recordings',
                isDense: true,
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            const SizedBox(height: 16),
            const Text('Supported protocols:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('• SMB — smb://server/share  (Windows/NAS)', style: TextStyle(fontSize: 11, color: Colors.white54)),
            const Text('• NFS — nfs://server/path  (Linux/NAS)', style: TextStyle(fontSize: 11, color: Colors.white54)),
            const Text('• AFP — afp://server/share  (Apple)', style: TextStyle(fontSize: 11, color: Colors.white54)),
            const Text('• FTP — ftp://user:pass@server/path', style: TextStyle(fontSize: 11, color: Colors.white54)),
            const Text('• WebDAV — webdav://server/path', style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (path != null && path.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, path);
      setState(() => _folder = path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder_rounded),
      title: const Text('Recording Location'),
      subtitle: Text(
        _folder ?? 'Not set — tap to choose',
        style: TextStyle(
          color: _folder != null ? Colors.purpleAccent : Colors.white38,
          fontSize: 13,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_folder != null)
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: 'Clear',
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove(_key);
                setState(() => _folder = null);
              },
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () async {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Recording Location'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'local'),
                child: const Row(children: [
                  Icon(Icons.folder_rounded, size: 20),
                  SizedBox(width: 12),
                  Text('Local Folder'),
                ]),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, 'network'),
                child: const Row(children: [
                  Icon(Icons.lan_rounded, size: 20),
                  SizedBox(width: 12),
                  Text('Network Share (SMB/NFS/AFP/FTP)'),
                ]),
              ),
            ],
          ),
        );
        if (choice == 'local') {
          await _pickLocal();
        } else if (choice == 'network' && context.mounted) {
          await _enterNetworkPath(context);
        }
      },
    );
  }
}
