import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/datasources/parsers/m3u_parser.dart';
import 'package:clubtivi/data/models/channel.dart';

void main() {
  late M3uParser parser;

  setUp(() {
    parser = M3uParser();
  });

  group('M3uParser', () {
    test('parses basic M3U Plus playlist', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-id="ESPN.us" tvg-name="ESPN HD" tvg-logo="http://logo.com/espn.png" group-title="Sports",ESPN HD
http://example.com/live/espn
#EXTINF:-1 tvg-id="CNN.us" tvg-name="CNN" group-title="News",CNN International
http://example.com/live/cnn
''';

      final result = parser.parse(content, providerId: 'test-provider');

      expect(result.channelCount, 2);
      expect(result.hasErrors, false);

      final espn = result.channels[0];
      expect(espn.name, 'ESPN HD');
      expect(espn.tvgId, 'ESPN.us');
      expect(espn.tvgLogo, 'http://logo.com/espn.png');
      expect(espn.groupTitle, 'Sports');
      expect(espn.streamUrl, 'http://example.com/live/espn');

      final cnn = result.channels[1];
      expect(cnn.name, 'CNN International');
      expect(cnn.tvgId, 'CNN.us');
      expect(cnn.groupTitle, 'News');
    });

    test('parses channel numbers from tvg-chno', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-id="ABC.us" tvg-chno="7",ABC
http://example.com/live/abc
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].channelNumber, 7);
    });

    test('detects VOD from group-title', () {
      const content = '''#EXTM3U
#EXTINF:-1 group-title="VOD | Action",The Matrix
http://example.com/movie/123.mp4
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].streamType, StreamType.vod);
    });

    test('detects VOD from Xtream URL pattern', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-name="Inception",Inception
http://example.com/movie/user/pass/456.mp4
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].streamType, StreamType.vod);
    });

    test('detects series from group-title', () {
      const content = '''#EXTM3U
#EXTINF:-1 group-title="Series | Drama",Breaking Bad S01E01
http://example.com/series/user/pass/789.mp4
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channels[0].streamType, StreamType.series);
    });

    test('handles missing #EXTM3U header gracefully', () {
      const content = '''#EXTINF:-1,Test Channel
http://example.com/test
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channelCount, 1);
      expect(result.hasErrors, true);
    });

    test('generates stable IDs from tvg-id', () {
      const content = '''#EXTM3U
#EXTINF:-1 tvg-id="ESPN.us",ESPN
http://example.com/espn
''';

      final result = parser.parse(content, providerId: 'myProvider');
      expect(result.channels[0].id, 'myProvider_ESPN.us');
    });

    test('skips entries without a name', () {
      const content = '''#EXTM3U
#EXTINF:-1,
http://example.com/empty
#EXTINF:-1,Valid Channel
http://example.com/valid
''';

      final result = parser.parse(content, providerId: 'p1');
      expect(result.channelCount, 1);
      expect(result.channels[0].name, 'Valid Channel');
    });
  });
}
