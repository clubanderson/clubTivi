import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/datasources/remote/debrid_service.dart';
import '../shows/shows_providers.dart';

/// Sub-screen for managing debrid service API tokens.
class DebridServicesScreen extends ConsumerStatefulWidget {
  const DebridServicesScreen({super.key});

  @override
  ConsumerState<DebridServicesScreen> createState() =>
      _DebridServicesScreenState();
}

class _DebridServicesScreenState extends ConsumerState<DebridServicesScreen> {
  final Map<DebridType, TextEditingController> _controllers = {};
  final Map<DebridType, bool> _verifying = {};
  final Map<DebridType, bool?> _verified = {};

  @override
  void initState() {
    super.initState();
    for (final type in DebridType.values) {
      _controllers[type] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool _loaded = false;

  void _loadTokens(ShowsApiKeys keys) {
    if (_loaded) return;
    _loaded = true;
    for (final type in DebridType.values) {
      _controllers[type]!.text = keys.debridTokens[type] ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = ref.watch(showsApiKeysProvider);
    _loadTokens(keys);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Future.microtask(() {
            if (mounted) Navigator.pop(context);
          });
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12122A),
        title: const Text('Debrid Services'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'Configure one or more debrid services. '
              'The first configured service will be used for stream resolution.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
          for (final type in DebridType.values)
            _DebridServiceCard(
              type: type,
              controller: _controllers[type]!,
              isConfigured: (keys.debridTokens[type] ?? '').isNotEmpty,
              isVerifying: _verifying[type] ?? false,
              verifyResult: _verified[type],
              onSave: () => _saveToken(type),
              onVerify: () => _verifyToken(type),
              onClear: () => _clearToken(type),
            ),
        ],
      ),
      ),
      ),
    );
  }

  Future<void> _saveToken(DebridType type) async {
    final token = _controllers[type]!.text.trim();
    await ref.read(showsApiKeysProvider.notifier).saveDebridToken(type, token);
    ref.invalidate(showsRepositoryProvider);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${type.displayName} token saved')),
      );
    }
    setState(() => _verified[type] = null);
  }

  Future<void> _verifyToken(DebridType type) async {
    final token = _controllers[type]!.text.trim();
    if (token.isEmpty) return;
    setState(() {
      _verifying[type] = true;
      _verified[type] = null;
    });
    try {
      final service = createDebridService(type, token);
      final ok = await service.verifyToken();
      if (mounted) setState(() => _verified[type] = ok);
    } catch (_) {
      if (mounted) setState(() => _verified[type] = false);
    } finally {
      if (mounted) setState(() => _verifying[type] = false);
    }
  }

  Future<void> _clearToken(DebridType type) async {
    _controllers[type]!.clear();
    await ref.read(showsApiKeysProvider.notifier).saveDebridToken(type, '');
    ref.invalidate(showsRepositoryProvider);
    if (mounted) {
      setState(() => _verified[type] = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${type.displayName} token removed')),
      );
    }
  }
}

class _DebridServiceCard extends StatefulWidget {
  final DebridType type;
  final TextEditingController controller;
  final bool isConfigured;
  final bool isVerifying;
  final bool? verifyResult;
  final VoidCallback onSave;
  final VoidCallback onVerify;
  final VoidCallback onClear;

  const _DebridServiceCard({
    required this.type,
    required this.controller,
    required this.isConfigured,
    required this.isVerifying,
    this.verifyResult,
    required this.onSave,
    required this.onVerify,
    required this.onClear,
  });

  @override
  State<_DebridServiceCard> createState() => _DebridServiceCardState();
}

class _DebridServiceCardState extends State<_DebridServiceCard> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = !widget.isConfigured;
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.type;
    final hasToken = widget.controller.text.trim().isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: const Color(0xFF16213E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              Icons.cloud_download_rounded,
              color: widget.isConfigured
                  ? const Color(0xFF6C5CE7)
                  : Colors.white30,
            ),
            title: Text(
              type.displayName,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: widget.isConfigured ? Colors.white : Colors.white70,
              ),
            ),
            subtitle: Text(
              widget.isConfigured ? 'Configured ✓' : 'Not configured',
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
                      labelText: 'API Token',
                      hintText: type.tokenUrl,
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
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.verified_outlined, size: 18),
                        label: const Text('Verify'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () {
                          final url = Uri.parse('https://${type.tokenUrl}');
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
