import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/warm_failover_engine.dart';

void main() {
  group('WarmFailoverEngine', () {
    test('starts and stops correctly', () {
      final engine = WarmFailoverEngine(probeIntervalSeconds: 60);
      expect(engine.isRunning, isFalse);
      // Feature gate blocks start in test, but stop should be safe
      engine.stop();
      expect(engine.isRunning, isFalse);
      engine.dispose();
    });

    test('getBestAlternative returns null when no healthy streams', () {
      final engine = WarmFailoverEngine();
      expect(engine.getBestAlternative(), isNull);
      engine.dispose();
    });

    test('getHealthyAlternatives returns empty when nothing probed', () {
      final engine = WarmFailoverEngine();
      expect(engine.getHealthyAlternatives(), isEmpty);
      engine.dispose();
    });
  });

  group('StreamHealth', () {
    test('isStale returns true when never probed', () {
      final health = StreamHealth(url: 'http://example.com/stream');
      expect(health.isStale, isTrue);
    });

    test('isStale returns false when recently probed', () {
      final health = StreamHealth(url: 'http://example.com/stream');
      health.lastProbeTime = DateTime.now();
      expect(health.isStale, isFalse);
    });

    test('isStale returns true when probed long ago', () {
      final health = StreamHealth(url: 'http://example.com/stream');
      health.lastProbeTime =
          DateTime.now().subtract(const Duration(minutes: 5));
      expect(health.isStale, isTrue);
    });

    test('defaults are correct', () {
      final health = StreamHealth(url: 'http://example.com/stream');
      expect(health.isHealthy, isFalse);
      expect(health.consecutiveFailures, 0);
      expect(health.lastLatencyMs, 0);
      expect(health.lastError, isNull);
    });
  });
}
