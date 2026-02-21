import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/feature_gate.dart';

/// Warm failover engine (Pro feature).
///
/// Continuously probes alternative streams in the background so that
/// when the primary stream stalls, we can switch instantly (<1s gap)
/// to a known-good alternative.
///
/// Resource-aware: probes use small byte-range requests (~64-128KB)
/// and run at configurable intervals. Disabled on battery/cellular.
class WarmFailoverEngine {
  final Dio _dio;

  /// How often to probe each alternative (seconds).
  final int probeIntervalSeconds;

  /// Bytes to request per probe (enough to detect if stream is alive).
  final int probeSizeBytes;

  Timer? _probeTimer;
  final Map<String, StreamHealth> _health = {};
  bool _running = false;

  WarmFailoverEngine({
    Dio? dio,
    this.probeIntervalSeconds = 30,
    this.probeSizeBytes = 65536, // 64KB
  }) : _dio = dio ?? Dio();

  Map<String, StreamHealth> get health => Map.unmodifiable(_health);
  bool get isRunning => _running;

  /// Start probing alternative streams.
  void start(List<String> alternativeUrls) {
    if (!FeatureGate.warmFailover) return;

    stop();
    _running = true;

    for (final url in alternativeUrls) {
      _health[url] = StreamHealth(url: url);
    }

    // Immediate first probe
    _probeAll();

    // Periodic probes
    _probeTimer = Timer.periodic(
      Duration(seconds: probeIntervalSeconds),
      (_) => _probeAll(),
    );
  }

  /// Stop all probing.
  void stop() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _running = false;
    for (final cancelToken in _activeCancelTokens) {
      cancelToken.cancel();
    }
    _activeCancelTokens.clear();
  }

  final List<CancelToken> _activeCancelTokens = [];

  Future<void> _probeAll() async {
    for (final url in _health.keys.toList()) {
      _probeStream(url);
    }
  }

  Future<void> _probeStream(String url) async {
    final cancelToken = CancelToken();
    _activeCancelTokens.add(cancelToken);

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 5),
          headers: {'Range': 'bytes=0-${probeSizeBytes - 1}'},
        ),
        cancelToken: cancelToken,
      );
      stopwatch.stop();

      final health = _health[url];
      if (health != null) {
        health.lastProbeTime = DateTime.now();
        health.lastLatencyMs = stopwatch.elapsedMilliseconds;
        health.lastBytesReceived = response.data?.length ?? 0;
        health.isHealthy = (response.statusCode ?? 0) >= 200 &&
            (response.statusCode ?? 0) < 400 &&
            (response.data?.isNotEmpty ?? false);
        health.consecutiveFailures = 0;
      }
    } catch (e) {
      stopwatch.stop();
      final health = _health[url];
      if (health != null) {
        health.lastProbeTime = DateTime.now();
        health.isHealthy = false;
        health.consecutiveFailures++;
        health.lastError = e.toString();
      }
    } finally {
      _activeCancelTokens.remove(cancelToken);
    }
  }

  /// Get the best alternative stream (lowest latency, healthy).
  String? getBestAlternative() {
    final healthy = _health.values
        .where((h) => h.isHealthy)
        .toList()
      ..sort((a, b) => a.lastLatencyMs.compareTo(b.lastLatencyMs));
    return healthy.isNotEmpty ? healthy.first.url : null;
  }

  /// Get all healthy alternatives sorted by latency.
  List<String> getHealthyAlternatives() {
    final healthy = _health.values
        .where((h) => h.isHealthy)
        .toList()
      ..sort((a, b) => a.lastLatencyMs.compareTo(b.lastLatencyMs));
    return healthy.map((h) => h.url).toList();
  }

  void dispose() {
    stop();
    _dio.close();
  }
}

/// Health status of a probed stream.
class StreamHealth {
  final String url;
  DateTime? lastProbeTime;
  int lastLatencyMs = 0;
  int lastBytesReceived = 0;
  bool isHealthy = false;
  int consecutiveFailures = 0;
  String? lastError;

  StreamHealth({required this.url});

  /// Whether this stream has been probed recently.
  bool get isStale {
    if (lastProbeTime == null) return true;
    return DateTime.now().difference(lastProbeTime!) >
        const Duration(minutes: 2);
  }
}

/// Riverpod provider.
final warmFailoverProvider = Provider<WarmFailoverEngine>((ref) {
  final engine = WarmFailoverEngine();
  ref.onDispose(() => engine.dispose());
  return engine;
});
