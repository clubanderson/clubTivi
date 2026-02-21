import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/epg_auto_mapper.dart';
import 'package:clubtivi/data/models/epg.dart';
import 'package:clubtivi/data/models/channel.dart';

void main() {
  late EpgAutoMapper mapper;

  setUp(() {
    mapper = EpgAutoMapper();
  });

  final epgChannels = [
    EpgChannel(
      id: 'ESPN.us',
      sourceId: 'src1',
      displayNames: ['ESPN', 'ESPN HD'],
      iconUrl: 'http://logo.com/espn.png',
    ),
    EpgChannel(
      id: 'CNN.us',
      sourceId: 'src1',
      displayNames: ['CNN', 'CNN International'],
      iconUrl: 'http://logo.com/cnn.png',
    ),
    EpgChannel(
      id: 'SkySp1.uk',
      sourceId: 'src1',
      displayNames: ['Sky Sports 1'],
      iconUrl: null,
    ),
  ];

  group('EpgAutoMapper', () {
    test('exact tvg-id match yields confidence 1.0', () {
      final channel = Channel(
        id: 'p1_ESPN.us',
        providerId: 'p1',
        name: 'ESPN HD',
        tvgId: 'ESPN.us',
        streamUrl: 'http://example.com/espn',
      );

      final candidates = mapper.findCandidates(
        channel: channel,
        epgChannels: epgChannels,
        epgSourceId: 'src1',
      );

      expect(candidates, isNotEmpty);
      expect(candidates.first.epgChannelId, 'ESPN.us');
      expect(candidates.first.confidence, greaterThanOrEqualTo(0.9));
    });

    test('fuzzy name match finds close matches', () {
      final channel = Channel(
        id: 'p1_cnn',
        providerId: 'p1',
        name: 'CNN International HD',
        streamUrl: 'http://example.com/cnn',
      );

      final candidates = mapper.findCandidates(
        channel: channel,
        epgChannels: epgChannels,
        epgSourceId: 'src1',
      );

      expect(candidates, isNotEmpty);
      // Should find CNN.us as a candidate
      final cnnCandidate =
          candidates.where((c) => c.epgChannelId == 'CNN.us').toList();
      expect(cnnCandidate, isNotEmpty);
    });

    test('mapAll produces stats', () {
      final channels = [
        Channel(
          id: 'p1_ESPN.us',
          providerId: 'p1',
          name: 'ESPN HD',
          tvgId: 'ESPN.us',
          streamUrl: 'http://example.com/espn',
        ),
        Channel(
          id: 'p1_unknown',
          providerId: 'p1',
          name: 'xyzzy_no_match_channel',
          streamUrl: 'http://example.com/unknown',
        ),
      ];

      final mappings = <EpgMapping>[];
      final stats = mapper.mapAll(
        channels: channels,
        epgChannels: epgChannels,
        epgSourceId: 'src1',
        existingMappings: {},
        onMapping: (m) => mappings.add(m),
      );

      expect(stats.totalChannels, 2);
      expect(stats.mapped + stats.suggested + stats.unmapped, 2);
    });

    test('respects locked mappings', () {
      final channels = [
        Channel(
          id: 'p1_ESPN.us',
          providerId: 'p1',
          name: 'ESPN HD',
          tvgId: 'ESPN.us',
          streamUrl: 'http://example.com/espn',
        ),
      ];

      final existing = {
        'p1_ESPN.us:p1': EpgMapping(
          playlistChannelId: 'p1_ESPN.us',
          providerId: 'p1',
          epgChannelId: 'SomeOther.us',
          epgSourceId: 'src1',
          confidence: 1.0,
          source: MappingSource.manual,
          locked: true,
          updatedAt: DateTime.now(),
        ),
      };

      int callCount = 0;
      final stats = mapper.mapAll(
        channels: channels,
        epgChannels: epgChannels,
        epgSourceId: 'src1',
        existingMappings: existing,
        onMapping: (_) => callCount++,
      );

      // Locked mapping should be counted as mapped, not re-mapped
      expect(callCount, 0);
      expect(stats.mapped, 1);
    });
  });
}
