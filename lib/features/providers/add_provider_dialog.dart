import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'provider_manager.dart';

/// Shows the Add Provider bottom sheet. Returns `true` if a provider was added.
Future<bool?> showAddProviderDialog(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A2E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _AddProviderSheet(),
  );
}

class _AddProviderSheet extends ConsumerStatefulWidget {
  const _AddProviderSheet();

  @override
  ConsumerState<_AddProviderSheet> createState() => _AddProviderSheetState();
}

class _AddProviderSheetState extends ConsumerState<_AddProviderSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _m3uFormKey = GlobalKey<FormState>();
  final _xtreamFormKey = GlobalKey<FormState>();

  // M3U fields
  final _m3uName = TextEditingController();
  final _m3uUrl = TextEditingController();

  // Xtream fields
  final _xtreamName = TextEditingController();
  final _xtreamUrl = TextEditingController();
  final _xtreamUser = TextEditingController();
  final _xtreamPass = TextEditingController();

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _m3uName.dispose();
    _m3uUrl.dispose();
    _xtreamName.dispose();
    _xtreamUrl.dispose();
    _xtreamUser.dispose();
    _xtreamPass.dispose();
    super.dispose();
  }

  String _slugify(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _generateId(String name) {
    final slug = _slugify(name);
    final ts = DateTime.now().millisecondsSinceEpoch;
    return '${slug.isEmpty ? 'provider' : slug}-$ts';
  }

  String? _validateRequired(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    return null;
  }

  String? _validateUrl(String? value) {
    if (value == null || value.trim().isEmpty) return 'Required';
    if (!value.trim().startsWith('http')) return 'URL must start with http';
    return null;
  }

  Future<void> _submitM3u() async {
    if (!_m3uFormKey.currentState!.validate()) return;
    await _addProvider(() {
      final manager = ref.read(providerManagerProvider);
      return manager.addM3uProvider(
        id: _generateId(_m3uName.text.trim()),
        name: _m3uName.text.trim(),
        url: _m3uUrl.text.trim(),
      );
    });
  }

  Future<void> _submitXtream() async {
    if (!_xtreamFormKey.currentState!.validate()) return;
    await _addProvider(() {
      final manager = ref.read(providerManagerProvider);
      return manager.addXtreamProvider(
        id: _generateId(_xtreamName.text.trim()),
        name: _xtreamName.text.trim(),
        url: _xtreamUrl.text.trim(),
        username: _xtreamUser.text.trim(),
        password: _xtreamPass.text.trim(),
      );
    });
  }

  Future<void> _addProvider(Future<void> Function() action) async {
    setState(() => _loading = true);
    try {
      await action();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Provider added successfully')),
      );
    } on ProviderLimitException catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Provider Limit Reached'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Text('Error'),
          content: Text('Failed to add provider:\n$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pasteUrl(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      controller.text = data!.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF6C5CE7);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 480,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Add Provider',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TabBar(
              controller: _tabController,
              indicatorColor: accent,
              labelColor: accent,
              unselectedLabelColor: Colors.white54,
              tabs: const [
                Tab(text: 'M3U Playlist'),
                Tab(text: 'Xtream Codes'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildM3uTab(),
                  _buildXtreamTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildM3uTab() {
    return Form(
      key: _m3uFormKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextFormField(
            controller: _m3uName,
            decoration: const InputDecoration(
              labelText: 'Provider Name',
              hintText: 'e.g. My IPTV',
              border: OutlineInputBorder(),
            ),
            validator: _validateRequired,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _m3uUrl,
            decoration: InputDecoration(
              labelText: 'M3U URL',
              hintText: 'http://...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                tooltip: 'Paste',
                onPressed: () => _pasteUrl(_m3uUrl),
              ),
            ),
            validator: _validateUrl,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 24),
          _buildSubmitButton(onPressed: _submitM3u),
        ],
      ),
    );
  }

  Widget _buildXtreamTab() {
    return Form(
      key: _xtreamFormKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextFormField(
            controller: _xtreamName,
            decoration: const InputDecoration(
              labelText: 'Provider Name',
              hintText: 'e.g. My Xtream',
              border: OutlineInputBorder(),
            ),
            validator: _validateRequired,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _xtreamUrl,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://...',
              border: OutlineInputBorder(),
            ),
            validator: _validateUrl,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _xtreamUser,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
            validator: _validateRequired,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _xtreamPass,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
            validator: _validateRequired,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: 24),
          _buildSubmitButton(onPressed: _submitXtream),
        ],
      ),
    );
  }

  Widget _buildSubmitButton({required VoidCallback onPressed}) {
    const accent = Color(0xFF6C5CE7);
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: _loading ? null : onPressed,
        style: FilledButton.styleFrom(backgroundColor: accent),
        child: _loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Add Provider', style: TextStyle(fontSize: 16)),
      ),
    );
  }
}
