import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/datasources/local/database.dart' as db;
import '../../data/services/epg_refresh_service.dart';
import '../providers/provider_manager.dart';

/// Dialog for adding a new EPG source.
class AddEpgSourceDialog extends ConsumerStatefulWidget {
  const AddEpgSourceDialog({super.key});

  @override
  ConsumerState<AddEpgSourceDialog> createState() =>
      _AddEpgSourceDialogState();
}

class _AddEpgSourceDialogState extends ConsumerState<AddEpgSourceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      final database = ref.read(databaseProvider);
      final service = ref.read(epgRefreshServiceProvider);
      final id = const Uuid().v4();

      await database.upsertEpgSource(db.EpgSourcesCompanion.insert(
        id: id,
        name: _nameController.text.trim(),
        url: _urlController.text.trim(),
      ));

      // Trigger refresh in background
      service.refreshSource(id).catchError((_) {});

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addDefaults() async {
    setState(() => _loading = true);
    try {
      final service = ref.read(epgRefreshServiceProvider);
      // Force add defaults even if sources exist
      final database = ref.read(databaseProvider);
      final existing = await database.getAllEpgSources();
      if (existing.isEmpty) {
        await service.addDefaultSources();
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add EPG Source'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. IPTV-Org EPG',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com/epg.xml.gz',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (!v.trim().startsWith('http')) {
                    return 'Must start with http';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _loading ? null : _addDefaults,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Add Default Sources'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}
