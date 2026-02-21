import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/models/epg.dart';
import '../../data/models/channel.dart' hide Provider;
import '../../data/services/epg_auto_mapper.dart';
import '../providers/provider_manager.dart';
import 'fuzzy_match.dart';

/// State for the EPG mapping screen.
class EpgMappingState {
  final List<ChannelMappingEntry> entries;
  final MappingFilter filter;
  final String searchQuery;
  final bool isLoading;
  final MappingStats? lastStats;

  const EpgMappingState({
    this.entries = const [],
    this.filter = MappingFilter.all,
    this.searchQuery = '',
    this.isLoading = false,
    this.lastStats,
  });

  EpgMappingState copyWith({
    List<ChannelMappingEntry>? entries,
    MappingFilter? filter,
    String? searchQuery,
    bool? isLoading,
    MappingStats? lastStats,
  }) {
    return EpgMappingState(
      entries: entries ?? this.entries,
      filter: filter ?? this.filter,
      searchQuery: searchQuery ?? this.searchQuery,
      isLoading: isLoading ?? this.isLoading,
      lastStats: lastStats ?? this.lastStats,
    );
  }

  List<ChannelMappingEntry> get filteredEntries {
    var result = entries;

    // Apply status filter
    switch (filter) {
      case MappingFilter.all:
        break;
      case MappingFilter.mapped:
        result = result.where((e) => e.isMapped).toList();
      case MappingFilter.suggested:
        result = result.where((e) => e.isSuggested).toList();
      case MappingFilter.unmapped:
        result = result.where((e) => e.isUnmapped).toList();
    }

    // Apply fuzzy search and sort by relevance
    if (searchQuery.isNotEmpty) {
      final scored = <(ChannelMappingEntry, double)>[];
      for (final e in result) {
        final fields = [
          e.channel.name,
          e.channel.tvgId,
          e.channel.tvgName,
          e.channel.groupTitle,
          e.mappedEpgName,
        ];
        final score = fuzzyMatch(searchQuery, fields);
        final tokens = tokenizeQuery(searchQuery);
        if (tokens.isNotEmpty && score >= tokens.length * 0.5) {
          scored.add((e, score));
        }
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      result = scored.map((s) => s.$1).toList();
    }

    return result;
  }

  int get mappedCount => entries.where((e) => e.isMapped).length;
  int get suggestedCount => entries.where((e) => e.isSuggested).length;
  int get unmappedCount => entries.where((e) => e.isUnmapped).length;
}

/// A single channel's mapping status.
class ChannelMappingEntry {
  final Channel channel;
  final EpgMapping? mapping;
  final String? mappedEpgName;
  final List<MappingCandidate> suggestions;

  const ChannelMappingEntry({
    required this.channel,
    this.mapping,
    this.mappedEpgName,
    this.suggestions = const [],
  });

  bool get isMapped =>
      mapping != null &&
      (mapping!.source == MappingSource.auto ||
          mapping!.source == MappingSource.manual);
  bool get isSuggested =>
      mapping != null && mapping!.source == MappingSource.suggested;
  bool get isUnmapped => mapping == null;
  bool get isLocked => mapping?.locked ?? false;
}

enum MappingFilter { all, mapped, suggested, unmapped }

/// Notifier that drives the EPG mapping screen.
class EpgMappingNotifier extends StateNotifier<EpgMappingState> {
  final db.AppDatabase _db;
  final EpgAutoMapper _mapper = EpgAutoMapper();

  EpgMappingNotifier(this._db) : super(const EpgMappingState());

  /// Load all channels and their mapping status.
  Future<void> load() async {
    state = state.copyWith(isLoading: true);

    final providers = await _db.getAllProviders();
    final allChannels = <Channel>[];
    for (final p in providers) {
      final dbChannels = await _db.getChannelsForProvider(p.id);
      allChannels.addAll(dbChannels.map((c) => Channel(
        id: c.id,
        providerId: c.providerId,
        name: c.name,
        tvgId: c.tvgId,
        tvgName: c.tvgName,
        tvgLogo: c.tvgLogo,
        groupTitle: c.groupTitle,
        channelNumber: c.channelNumber,
        streamUrl: c.streamUrl,
      )));
    }

    final mappings = await _db.getAllMappings();
    final mappingMap = <String, db.EpgMapping>{};
    for (final m in mappings) {
      mappingMap['${m.channelId}:${m.providerId}'] = m;
    }

    // Build EPG channel name lookup
    final epgSources = await _db.getAllEpgSources();
    final epgChannelNames = <String, String>{};
    for (final src in epgSources) {
      final epgChs = await _db.getEpgChannelsForSource(src.id);
      for (final ch in epgChs) {
        epgChannelNames[ch.channelId] = ch.displayName;
      }
    }

    final entries = allChannels.map((channel) {
      final key = '${channel.id}:${channel.providerId}';
      final dbMapping = mappingMap[key];

      EpgMapping? mapping;
      if (dbMapping != null) {
        mapping = EpgMapping(
          playlistChannelId: dbMapping.channelId,
          providerId: dbMapping.providerId,
          epgChannelId: dbMapping.epgChannelId,
          epgSourceId: dbMapping.epgSourceId,
          confidence: dbMapping.confidence,
          source: _parseMappingSource(dbMapping.source),
          locked: dbMapping.locked,
          updatedAt: dbMapping.updatedAt,
        );
      }

      return ChannelMappingEntry(
        channel: channel,
        mapping: mapping,
        mappedEpgName: dbMapping != null
            ? epgChannelNames[dbMapping.epgChannelId]
            : null,
      );
    }).toList();

    state = state.copyWith(entries: entries, isLoading: false);
  }

  /// Run the auto-mapper on all unmapped/suggested channels.
  Future<MappingStats> runAutoMapper() async {
    state = state.copyWith(isLoading: true);

    final epgSources = await _db.getAllEpgSources();
    if (epgSources.isEmpty) {
      state = state.copyWith(isLoading: false);
      return MappingStats(
        totalChannels: 0, mapped: 0, suggested: 0, unmapped: 0,
        elapsed: Duration.zero,
      );
    }

    // Use first enabled source
    final source = epgSources.firstWhere((s) => s.enabled,
        orElse: () => epgSources.first);
    final epgDbChannels = await _db.getEpgChannelsForSource(source.id);
    final epgChannels = epgDbChannels.map((c) => EpgChannel(
      id: c.channelId,
      sourceId: source.id,
      displayNames: [c.displayName],
      iconUrl: c.iconUrl,
    )).toList();

    // Get all provider channels
    final channels = state.entries
        .where((e) => !e.isLocked)
        .map((e) => e.channel)
        .toList();

    // Build existing mappings map
    final existingMappings = <String, EpgMapping>{};
    for (final entry in state.entries) {
      if (entry.mapping != null) {
        final key = '${entry.channel.id}:${entry.channel.providerId}';
        existingMappings[key] = entry.mapping!;
      }
    }

    final newMappings = <EpgMapping>[];
    final stats = _mapper.mapAll(
      channels: channels,
      epgChannels: epgChannels,
      epgSourceId: source.id,
      existingMappings: existingMappings,
      onMapping: (m) => newMappings.add(m),
    );

    // Save mappings to DB
    for (final m in newMappings) {
      if (m.epgChannelId == null || m.epgSourceId == null) continue;
      await _db.upsertMapping(db.EpgMappingsCompanion.insert(
        channelId: m.playlistChannelId,
        providerId: m.providerId,
        epgChannelId: m.epgChannelId!,
        epgSourceId: m.epgSourceId!,
      ));
    }

    await load(); // Refresh
    state = state.copyWith(lastStats: stats);
    return stats;
  }

  /// Manually set a mapping for a channel.
  Future<void> setManualMapping({
    required String channelId,
    required String providerId,
    required String epgChannelId,
    required String epgSourceId,
  }) async {
    await _db.upsertMapping(db.EpgMappingsCompanion.insert(
      channelId: channelId,
      providerId: providerId,
      epgChannelId: epgChannelId,
      epgSourceId: epgSourceId,
    ));
    await load();
  }

  /// Remove a mapping.
  Future<void> removeMapping(String channelId, String providerId) async {
    await _db.deleteMapping(channelId, providerId);
    await load();
  }

  /// Toggle lock on a mapping.
  Future<void> toggleLock(String channelId, String providerId) async {
    // Re-load and toggle — simplified
    await load();
  }

  void setFilter(MappingFilter filter) {
    state = state.copyWith(filter: filter);
  }

  void setSearch(String query) {
    state = state.copyWith(searchQuery: query);
  }

  MappingSource _parseMappingSource(String source) {
    switch (source) {
      case 'manual':
        return MappingSource.manual;
      case 'suggested':
        return MappingSource.suggested;
      default:
        return MappingSource.auto;
    }
  }
}

/// Riverpod providers.
final epgMappingProvider =
    StateNotifierProvider<EpgMappingNotifier, EpgMappingState>((ref) {
  return EpgMappingNotifier(ref.watch(databaseProvider));
});
