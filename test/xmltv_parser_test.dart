import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/datasources/parsers/xmltv_parser.dart';

void main() {
  late XmltvParser parser;

  setUp(() {
    parser = XmltvParser();
  });

  group('XmltvParser', () {
    test('parses channels and programmes from XMLTV', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="test">
  <channel id="ESPN.us">
    <display-name>ESPN</display-name>
    <display-name>ESPN HD</display-name>
    <icon src="http://logo.com/espn.png"/>
  </channel>
  <channel id="CNN.us">
    <display-name>CNN International</display-name>
  </channel>
  <programme start="20240101120000 +0000" stop="20240101130000 +0000" channel="ESPN.us">
    <title>SportsCenter</title>
    <desc>Latest sports news and highlights.</desc>
    <category>Sports</category>
  </programme>
  <programme start="20240101130000 +0000" stop="20240101140000 +0000" channel="ESPN.us">
    <title>NFL Live</title>
  </programme>
</tv>''';

      final result = parser.parse(xml, sourceId: 'test-source');

      // Channels
      expect(result.channels.length, 2);

      final espn = result.channels.firstWhere((c) => c.id == 'ESPN.us');
      expect(espn.primaryName, 'ESPN');
      expect(espn.displayNames, ['ESPN', 'ESPN HD']);
      expect(espn.iconUrl, 'http://logo.com/espn.png');

      final cnn = result.channels.firstWhere((c) => c.id == 'CNN.us');
      expect(cnn.primaryName, 'CNN International');

      // Programmes
      expect(result.programmes.length, 2);

      final sc = result.programmes[0];
      expect(sc.title, 'SportsCenter');
      expect(sc.description, 'Latest sports news and highlights.');
      expect(sc.category, 'Sports');
      expect(sc.channelId, 'ESPN.us');
    });

    test('handles empty XMLTV gracefully', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv></tv>''';

      final result = parser.parse(xml, sourceId: 'empty');
      expect(result.channels, isEmpty);
      expect(result.programmes, isEmpty);
    });

    test('parses XMLTV date format correctly', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="test"><display-name>Test</display-name></channel>
  <programme start="20240615143000 -0500" stop="20240615150000 -0500" channel="test">
    <title>Test Show</title>
  </programme>
</tv>''';

      final result = parser.parse(xml, sourceId: 's1');
      expect(result.programmes.length, 1);
      expect(result.programmes[0].start, isNotNull);
      expect(result.programmes[0].stop, isNotNull);
    });
  });
}
