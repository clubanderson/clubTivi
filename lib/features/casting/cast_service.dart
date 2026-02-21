import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

final _log = Logger(printer: SimplePrinter());

/// Represents a discovered cast target on the local network.
class CastDevice {
  final String id;
  final String name;
  final String type; // 'dlna'
  final DLNADevice? dlnaDevice;

  CastDevice({required this.id, required this.name, required this.type, this.dlnaDevice});

  @override
  String toString() => '$name ($type)';
}

/// Manages device discovery and casting of IPTV streams via DLNA/UPnP.
class CastService {
  DLNAManager? _dlnaManager;
  DeviceManager? _deviceManager;
  StreamSubscription? _deviceSub;

  final _devicesController = StreamController<List<CastDevice>>.broadcast();
  final Map<String, CastDevice> _devices = {};

  CastDevice? _activeDevice;
  String? _activeUrl;
  bool _isCasting = false;

  /// Stream of discovered cast devices.
  Stream<List<CastDevice>> get devicesStream => _devicesController.stream;

  /// Currently available devices.
  List<CastDevice> get devices => _devices.values.toList();

  /// Whether we are actively casting.
  bool get isCasting => _isCasting;

  /// The device we are casting to.
  CastDevice? get activeDevice => _activeDevice;

  /// Start scanning for DLNA/UPnP devices on the local network.
  Future<void> startDiscovery() async {
    await stopDiscovery();
    _devices.clear();
    _dlnaManager = DLNAManager();
    try {
      _deviceManager = await _dlnaManager!.start(reusePort: true);
      _deviceSub = _deviceManager!.devices.stream.listen((deviceMap) {
        _devices.clear();
        for (final entry in deviceMap.entries) {
          final dlna = entry.value;
          final name = dlna.info.friendlyName;
          _devices[entry.key] = CastDevice(
            id: entry.key,
            name: name.isNotEmpty ? name : 'Unknown Device',
            type: 'dlna',
            dlnaDevice: dlna,
          );
        }
        _devicesController.add(_devices.values.toList());
      });
      _log.i('DLNA discovery started');
    } catch (e) {
      _log.e('DLNA discovery failed: $e');
    }
  }

  /// Stop scanning.
  Future<void> stopDiscovery() async {
    _deviceSub?.cancel();
    _deviceSub = null;
    _dlnaManager?.stop();
    _dlnaManager = null;
    _deviceManager = null;
  }

  /// Cast a stream URL to the given device.
  Future<bool> castTo(CastDevice device, String url, {String title = ''}) async {
    try {
      if (device.dlnaDevice != null) {
        await device.dlnaDevice!.setUrl(url, title: title);
        await device.dlnaDevice!.play();
        _activeDevice = device;
        _activeUrl = url;
        _isCasting = true;
        _log.i('Casting to ${device.name}: $url');
        return true;
      }
      return false;
    } catch (e) {
      _log.e('Cast failed: $e');
      return false;
    }
  }

  /// Stop casting on the active device.
  Future<void> stopCasting() async {
    try {
      if (_activeDevice?.dlnaDevice != null) {
        await _activeDevice!.dlnaDevice!.stop();
      }
    } catch (e) {
      _log.e('Stop cast error: $e');
    }
    _activeDevice = null;
    _activeUrl = null;
    _isCasting = false;
  }

  /// Pause playback on the active device.
  Future<void> pause() async {
    try {
      await _activeDevice?.dlnaDevice?.pause();
    } catch (e) {
      _log.e('Cast pause error: $e');
    }
  }

  /// Resume playback on the active device.
  Future<void> resume() async {
    try {
      await _activeDevice?.dlnaDevice?.play();
    } catch (e) {
      _log.e('Cast resume error: $e');
    }
  }

  /// Set volume (0-100) on the active device.
  Future<void> setVolume(int volume) async {
    try {
      await _activeDevice?.dlnaDevice?.volume(volume.clamp(0, 100));
    } catch (e) {
      _log.e('Cast volume error: $e');
    }
  }

  /// Switch channel: cast a new URL to the same device.
  Future<bool> switchChannel(String url, {String title = ''}) async {
    if (_activeDevice == null) return false;
    return castTo(_activeDevice!, url, title: title);
  }

  void dispose() {
    stopCasting();
    stopDiscovery();
    _devicesController.close();
  }
}

/// Riverpod provider for the cast service (singleton).
final castServiceProvider = Provider<CastService>((ref) {
  final service = CastService();
  ref.onDispose(() => service.dispose());
  return service;
});
