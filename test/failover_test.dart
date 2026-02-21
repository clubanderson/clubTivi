import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/failover_engine.dart';
import 'package:clubtivi/data/models/channel.dart';

void main() {
  group('ColdFailoverEngine', () {
    late ColdFailoverEngine engine;

    setUp(() {
      engine = ColdFailoverEngine(
        stallThreshold: Duration.zero, // Instant for testing
        maxAttempts: 3,
      );
      engine.configure(
        primaryUrl: 'http://provider1.com/espn',
        alternatives: [
          'http://provider2.com/espn',
          'http://provider3.com/espn',
        ],
      );
    });

    test('returns null when buffering starts', () {
      expect(engine.onBufferingChanged(true), isNull);
    });

    test('switches to next URL on sustained buffering', () {
      engine.onBufferingChanged(true);
      // With zero threshold, second call should trigger switch
      final newUrl = engine.onBufferingChanged(true);
      expect(newUrl, 'http://provider2.com/espn');
    });

    test('resets attempt count when playback resumes', () {
      engine.onBufferingChanged(true);
      engine.onBufferingChanged(true); // triggers switch
      engine.onBufferingChanged(false); // resumes OK
      expect(engine.attemptCount, 0);
    });

    test('round-robins through all alternatives', () {
      // First failover
      engine.onBufferingChanged(true);
      final url1 = engine.onBufferingChanged(true);
      expect(url1, 'http://provider2.com/espn');

      // Second failover
      engine.onBufferingChanged(true);
      final url2 = engine.onBufferingChanged(true);
      expect(url2, 'http://provider3.com/espn');

      // Wraps back to primary
      engine.onBufferingChanged(true);
      final url3 = engine.onBufferingChanged(true);
      expect(url3, 'http://provider1.com/espn');
    });

    test('stops after max attempts', () {
      for (var i = 0; i < 3; i++) {
        engine.onBufferingChanged(true);
        engine.onBufferingChanged(true);
      }
      expect(engine.isExhausted, true);
      engine.onBufferingChanged(true);
      expect(engine.onBufferingChanged(true), isNull);
    });

    test('switchToNext forces immediate failover', () {
      final url = engine.switchToNext();
      expect(url, 'http://provider2.com/espn');
    });

    test('returns null with no alternatives', () {
      final solo = ColdFailoverEngine();
      solo.configure(primaryUrl: 'http://only.com/ch1', alternatives: []);
      expect(solo.switchToNext(), isNull);
      expect(solo.hasAlternatives, false);
    });
  });

  group('CrossProviderMatcher', () {
    test('finds alternative streams by EPG ID', () {
      final matcher = CrossProviderMatcher();
      final channels = [
        _ch('p1_espn', 'p1', 'http://p1.com/espn'),
        _ch('p2_espn', 'p2', 'http://p2.com/espn'),
        _ch('p3_espn', 'p3', 'http://p3.com/espn'),
        _ch('p1_cnn', 'p1', 'http://p1.com/cnn'),
      ];
      final epgMap = {
        'p1_espn': 'ESPN.us',
        'p2_espn': 'ESPN.us',
        'p3_espn': 'ESPN.us',
        'p1_cnn': 'CNN.us',
      };

      final alts = matcher.findAlternativeStreams(
        currentChannelId: 'p1_espn',
        epgChannelId: 'ESPN.us',
        allChannels: channels,
        channelToEpgMap: epgMap,
      );

      expect(alts, ['http://p2.com/espn', 'http://p3.com/espn']);
    });
  });
}

Channel _ch(String id, String providerId, String url) => Channel(
      id: id,
      providerId: providerId,
      name: id,
      streamUrl: url,
    );
