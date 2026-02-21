import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cast_service.dart';

/// Shows a dialog to discover and select a cast target device.
Future<CastDevice?> showCastDialog(BuildContext context, WidgetRef ref) async {
  return showDialog<CastDevice>(
    context: context,
    builder: (ctx) => _CastDialog(ref: ref),
  );
}

class _CastDialog extends StatefulWidget {
  final WidgetRef ref;
  const _CastDialog({required this.ref});

  @override
  State<_CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends State<_CastDialog> {
  late final CastService _castService;
  StreamSubscription? _sub;
  List<CastDevice> _devices = [];
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _castService = widget.ref.read(castServiceProvider);
    _startScan();
  }

  void _startScan() async {
    _sub = _castService.devicesStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    await _castService.startDiscovery();
    // Stop auto-scanning after 30 seconds
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Row(
        children: [
          const Icon(Icons.cast_rounded, color: Colors.amber, size: 22),
          const SizedBox(width: 8),
          const Text('Cast to Device', style: TextStyle(color: Colors.white, fontSize: 16)),
          const Spacer(),
          if (_scanning)
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber),
            ),
        ],
      ),
      content: SizedBox(
        width: 320,
        height: 300,
        child: _devices.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _scanning ? Icons.radar_rounded : Icons.cast_connected_rounded,
                      size: 48,
                      color: Colors.white24,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _scanning
                          ? 'Scanning for devices…'
                          : 'No devices found.\nMake sure devices are on the same network.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    if (!_scanning) ...[
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: () {
                          setState(() { _scanning = true; _devices.clear(); });
                          _startScan();
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Scan Again'),
                        style: TextButton.styleFrom(foregroundColor: Colors.amber),
                      ),
                    ],
                  ],
                ),
              )
            : ListView.builder(
                itemCount: _devices.length,
                itemBuilder: (ctx, i) {
                  final device = _devices[i];
                  final isActive = _castService.activeDevice?.id == device.id;
                  return ListTile(
                    leading: Icon(
                      _iconForDevice(device),
                      color: isActive ? Colors.amber : Colors.white54,
                      size: 28,
                    ),
                    title: Text(
                      device.name,
                      style: TextStyle(
                        color: isActive ? Colors.amber : Colors.white,
                        fontSize: 14,
                        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      device.type.toUpperCase(),
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    trailing: isActive
                        ? const Icon(Icons.check_circle_rounded, color: Colors.amber, size: 20)
                        : null,
                    onTap: () => Navigator.of(context).pop(device),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    hoverColor: Colors.white.withValues(alpha: 0.05),
                  );
                },
              ),
      ),
      actions: [
        if (_castService.isCasting)
          TextButton.icon(
            onPressed: () async {
              await _castService.stopCasting();
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.cast_connected_rounded, size: 16),
            label: const Text('Stop Casting'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }

  IconData _iconForDevice(CastDevice device) {
    final name = device.name.toLowerCase();
    if (name.contains('apple tv') || name.contains('airplay')) {
      return Icons.tv_rounded;
    } else if (name.contains('chromecast') || name.contains('google')) {
      return Icons.cast_rounded;
    } else if (name.contains('samsung') || name.contains('lg') || name.contains('sony') || name.contains('tv')) {
      return Icons.tv_rounded;
    } else if (name.contains('sonos') || name.contains('speaker')) {
      return Icons.speaker_rounded;
    }
    return Icons.devices_rounded;
  }
}
