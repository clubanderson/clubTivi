import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../core/fuzzy_match.dart';
import '../../data/datasources/local/database.dart' as db;
import '../providers/provider_manager.dart';

/// EPG program guide — horizontal timeline grid view.
class GuideScreen extends ConsumerStatefulWidget {
  const GuideScreen({super.key});

  @override
  ConsumerState<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends ConsumerState<GuideScreen> {
  DateTime _focusTime = DateTime.now();
  final _scrollController = ScrollController();
  final _scrollOffset = ValueNotifier<double>(0.0);
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  /// Pixels per minute for the timeline.
  static const _pixelsPerMinute = 4.0;

  /// Total width of the 24-hour timeline.
  static double get _totalWidth => 24 * 60 * _pixelsPerMinute;

  // EPG mapping data (loaded once)
  Map<String, String> _epgMappings = {};
  Set<String> _validEpgChannelIds = {};
  bool _mappingsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadMappings();
    // Pre-set offset to "now" so rows render correctly before jumpTo fires
    final nowMinutes = _focusTime.hour * 60 + _focusTime.minute;
    final initialOffset = (nowMinutes * _pixelsPerMinute - 100).clamp(0.0, 24 * 60 * _pixelsPerMinute);
    _scrollOffset.value = initialOffset;
    // Sync scroll offset to ValueNotifier for all rows
    _scrollController.addListener(() {
      _scrollOffset.value = _scrollController.offset;
    });
    // Scroll to "now" on load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(initialOffset);
      }
    });
  }

  Future<void> _loadMappings() async {
    final database = ref.read(databaseProvider);
    final mappings = await database.getAllMappings();
    final epgSources = await database.getAllEpgSources();
    final currentSourceIds = epgSources.map((s) => s.id).toSet();
    final validIds = <String>{};
    for (final src in epgSources) {
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        validIds.add(ch.id);
      }
    }
    // Resolve mappings — handle stale source IDs from deleted/re-created sources
    final epgMap = <String, String>{};
    for (final m in mappings) {
      if (currentSourceIds.contains(m.epgSourceId)) {
        epgMap[m.channelId] = '${m.epgSourceId}_${m.epgChannelId}';
      } else {
        for (final srcId in currentSourceIds) {
          final candidate = '${srcId}_${m.epgChannelId}';
          if (validIds.contains(candidate)) {
            epgMap[m.channelId] = candidate;
            break;
          }
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _epgMappings = epgMap;
      _validEpgChannelIds = validIds;
      _mappingsLoaded = true;
    });
  }

  /// Resolve a channel to its EPG channel ID for programme lookup.
  String? _resolveEpgId(db.Channel channel) {
    final mapped = _epgMappings[channel.id];
    if (mapped != null && mapped.isNotEmpty) return mapped;
    if (channel.tvgId != null &&
        channel.tvgId!.isNotEmpty &&
        _validEpgChannelIds.contains(channel.tvgId)) {
      return channel.tvgId!;
    }
    return null;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _scrollOffset.dispose();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    // Don't intercept keys when a text field is focused
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        primaryFocus!.unfocus();
      }
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Future.microtask(() {
        if (!mounted) return;
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/');
        }
      });
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _scrollController.animateTo(
        (_scrollController.offset - 200).clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _scrollController.animateTo(
        (_scrollController.offset + 200).clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final database = ref.watch(databaseProvider);

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Program Guide'),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded, size: 18),
            tooltip: 'Previous day',
            onPressed: () => setState(() {
              _focusTime = _focusTime.subtract(const Duration(days: 1));
            }),
          ),
          TextButton(
            onPressed: () => setState(() => _focusTime = DateTime.now()),
            child: Text(
              _formatDate(_focusTime),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
            tooltip: 'Next day',
            onPressed: () => setState(() {
              _focusTime = _focusTime.add(const Duration(days: 1));
            }),
          ),
        ],
      ),
      body: FutureBuilder<List<db.Provider>>(
        future: database.getAllProviders(),
        builder: (context, provSnap) {
          if (!provSnap.hasData || provSnap.data!.isEmpty) {
            return const _GuideEmptyState();
          }
          return Column(
            children: [
              // Time ruler — offset by 120px to align with programme columns
              SizedBox(
                height: 32,
                child: Row(
                  children: [
                    const SizedBox(width: 120),
                    Expanded(
                      child: _TimeRuler(
                        scrollController: _scrollController,
                        focusDate: _focusTime,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Search bar
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search channels...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon:
                        const Icon(Icons.search, color: Colors.white38),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear,
                                color: Colors.white38),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFF16213E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v),
                ),
              ),
              // Channel rows
              Expanded(
                child: FutureBuilder<List<db.Channel>>(
                  future: database.getChannelsForProvider(
                      provSnap.data!.first.id),
                  builder: (context, chanSnap) {
                    if (!chanSnap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    var channels = chanSnap.data!;
                    if (_searchQuery.isNotEmpty) {
                      channels = channels
                          .where((c) => fuzzyMatchPasses(
                              _searchQuery, [c.name, c.groupTitle]))
                          .toList();
                    }
                    return ListView.builder(
                      itemCount: channels.length,
                      itemBuilder: (context, index) {
                        final channel = channels[index];
                        final epgId = _mappingsLoaded ? _resolveEpgId(channel) : null;
                        return _ChannelGuideRow(
                          channelName: channel.name,
                          channelLogo: channel.tvgLogo,
                          scrollOffset: _scrollOffset,
                          database: database,
                          epgChannelId: epgId,
                          focusDate: _focusTime,
                          pixelsPerMinute: _pixelsPerMinute,
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return 'Today';
    }
    return '${dt.month}/${dt.day}';
  }
}

class _TimeRuler extends StatelessWidget {
  final ScrollController scrollController;
  final DateTime focusDate;

  const _TimeRuler({required this.scrollController, required this.focusDate});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: scrollController,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(24, (hour) {
          final width = 60 * _GuideScreenState._pixelsPerMinute;
          final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
          final ampm = hour < 12 ? 'AM' : 'PM';
          return SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '$h12:00 $ampm',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
                overflow: TextOverflow.clip,
                maxLines: 1,
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ChannelGuideRow extends StatefulWidget {
  final String channelName;
  final String? channelLogo;
  final ValueNotifier<double> scrollOffset;
  final db.AppDatabase database;
  final String? epgChannelId;
  final DateTime focusDate;
  final double pixelsPerMinute;

  const _ChannelGuideRow({
    required this.channelName,
    this.channelLogo,
    required this.scrollOffset,
    required this.database,
    this.epgChannelId,
    required this.focusDate,
    required this.pixelsPerMinute,
  });

  @override
  State<_ChannelGuideRow> createState() => _ChannelGuideRowState();
}

class _ChannelGuideRowState extends State<_ChannelGuideRow> {
  List<db.EpgProgramme>? _programmes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadProgrammes();
  }

  @override
  void didUpdateWidget(covariant _ChannelGuideRow old) {
    super.didUpdateWidget(old);
    if (old.epgChannelId != widget.epgChannelId ||
        old.focusDate != widget.focusDate) {
      _loadProgrammes();
    }
  }

  Future<void> _loadProgrammes() async {
    if (widget.epgChannelId == null) {
      if (mounted) setState(() => _programmes = []);
      return;
    }
    setState(() => _loading = true);
    final dayStart = DateTime(
        widget.focusDate.year, widget.focusDate.month, widget.focusDate.day);
    final dayEnd = dayStart.add(const Duration(hours: 24));
    try {
      final progs = await widget.database.getProgrammes(
        epgChannelId: widget.epgChannelId!,
        start: dayStart,
        end: dayEnd,
      );
      // Deduplicate — EPG data can have entries from multiple sources
      // with near-identical times. Remove any programme that significantly
      // overlaps (>50% of its duration) with an already-kept programme.
      final unique = <db.EpgProgramme>[];
      for (final p in progs) {
        final dominated = unique.any((u) {
          final oStart = p.start.isAfter(u.start) ? p.start : u.start;
          final oEnd = p.stop.isBefore(u.stop) ? p.stop : u.stop;
          final overlapMs = oEnd.difference(oStart).inMilliseconds;
          if (overlapMs <= 0) return false;
          final pMs = p.stop.difference(p.start).inMilliseconds;
          return pMs > 0 && overlapMs > pMs * 0.5;
        });
        if (!dominated) unique.add(p);
      }
      if (mounted) setState(() { _programmes = unique; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _programmes = []; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ppm = widget.pixelsPerMinute;
    final dayStart = DateTime(
        widget.focusDate.year, widget.focusDate.month, widget.focusDate.day);
    final now = DateTime.now();

    return ClipRect(
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            // Channel label
            SizedBox(
              width: 120,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    if (widget.channelLogo != null && widget.channelLogo!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Image.network(widget.channelLogo!, width: 24, height: 24,
                          errorBuilder: (_, __, ___) => const Icon(Icons.tv, size: 18, color: Colors.white24)),
                      ),
                    Expanded(
                      child: Text(widget.channelName,
                        style: const TextStyle(fontSize: 11),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            // Programme timeline — synced scroll row
            Expanded(
              child: _SyncedScrollRow(
                scrollOffset: widget.scrollOffset,
                child: SizedBox(
                  width: 24 * 60 * ppm,
                  height: 52,
                  child: _loading
                      ? const SizedBox.shrink()
                      : (_programmes == null || _programmes!.isEmpty)
                          ? Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.03),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Center(
                                child: Text('No EPG data',
                                  style: TextStyle(fontSize: 10, color: Colors.white24)),
                              ),
                            )
                          : Stack(
                              clipBehavior: Clip.hardEdge,
                              children: [
                                for (final prog in _programmes!)
                                  _buildProgrammeBlock(prog, dayStart, now, ppm),
                                // Now indicator line
                                if (now.year == dayStart.year &&
                                    now.month == dayStart.month &&
                                    now.day == dayStart.day)
                                  Positioned(
                                    left: now.difference(dayStart).inMinutes * ppm,
                                    top: 0, bottom: 0,
                                    child: Container(width: 2, color: Colors.red),
                                  ),
                              ],
                            ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgrammeBlock(
      db.EpgProgramme prog, DateTime dayStart, DateTime now, double ppm) {
    final startMin = prog.start.difference(dayStart).inMinutes.toDouble().clamp(0, 24 * 60);
    final endMin = prog.stop.difference(dayStart).inMinutes.toDouble().clamp(0, 24 * 60);
    final width = (endMin - startMin) * ppm;
    if (width <= 0) return const SizedBox.shrink();
    final isNow = now.isAfter(prog.start) && now.isBefore(prog.stop);

    return Positioned(
      left: startMin * ppm,
      top: 2, bottom: 2,
      width: width,
      child: Tooltip(
        richMessage: _buildProgrammeTooltip(prog),
        waitDuration: const Duration(milliseconds: 400),
        preferBelow: true,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        padding: const EdgeInsets.all(12),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
          margin: const EdgeInsets.only(right: 1),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: isNow
                ? const Color(0xFF1A237E).withValues(alpha: 0.9)
                : const Color(0xFF16213E).withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(3),
            border: isNow ? Border.all(color: Colors.blueAccent, width: 1) : null,
          ),
          clipBehavior: Clip.hardEdge,
          alignment: Alignment.centerLeft,
          child: Text(
            prog.title,
            style: TextStyle(
              fontSize: 10,
              color: isNow ? Colors.white : Colors.white70,
              fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
            ),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
        ),
        ),
      ),
    );
  }

  InlineSpan _buildProgrammeTooltip(db.EpgProgramme prog) {
    final buf = StringBuffer();
    buf.writeln(prog.title);
    buf.writeln('${_fmtTime(prog.start)} – ${_fmtTime(prog.stop)}');
    if (prog.subtitle != null && prog.subtitle!.isNotEmpty) {
      buf.writeln(prog.subtitle!);
    }
    if (prog.episodeNum != null && prog.episodeNum!.isNotEmpty) {
      final ep = _formatEpisodeNum(prog.episodeNum!);
      if (ep.isNotEmpty) buf.writeln(ep);
    }
    if (prog.category != null && prog.category!.isNotEmpty) {
      buf.writeln('Category: ${prog.category}');
    }
    if (prog.description != null && prog.description!.isNotEmpty) {
      var desc = prog.description!;
      if (desc.length > 200) desc = '${desc.substring(0, 200)}…';
      buf.writeln(desc);
    }
    final imdbQuery = Uri.encodeComponent(prog.title);
    buf.writeln('🔗 imdb.com/find/?q=$imdbQuery');
    return TextSpan(
      text: buf.toString().trimRight(),
      style: const TextStyle(fontSize: 12, height: 1.4),
    );
  }

  /// Parse XMLTV episode-num (e.g. "1.4." = S02E05, "0.5.0/1" = S01E06)
  String _formatEpisodeNum(String raw) {
    // xmltv_ns format: "season.episode.part" (0-indexed)
    final parts = raw.split('.');
    if (parts.length >= 2) {
      final s = int.tryParse(parts[0].trim());
      final ePart = parts[1].trim().split('/')[0];
      final e = int.tryParse(ePart);
      if (s != null && e != null) {
        return 'S${(s + 1).toString().padLeft(2, '0')}E${(e + 1).toString().padLeft(2, '0')}';
      }
    }
    // Fallback: show raw
    return 'Episode: $raw';
  }

  String _fmtTime(DateTime dt) {
    final h = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }
}

class _GuideEmptyState extends StatelessWidget {
  const _GuideEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.calendar_view_week_rounded,
              size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('EPG Guide',
              style: TextStyle(fontSize: 20, color: Colors.white54)),
          SizedBox(height: 8),
          Text('Add an EPG source to see program listings',
              style: TextStyle(fontSize: 14, color: Colors.white38)),
        ],
      ),
    );
  }
}

/// A horizontal scroll view that syncs position from a ValueNotifier.
/// Each row gets its own ScrollController; NeverScrollableScrollPhysics
/// prevents independent scrolling — only the time ruler drives offset.
class _SyncedScrollRow extends StatefulWidget {
  final ValueNotifier<double> scrollOffset;
  final Widget child;

  const _SyncedScrollRow({required this.scrollOffset, required this.child});

  @override
  State<_SyncedScrollRow> createState() => _SyncedScrollRowState();
}

class _SyncedScrollRowState extends State<_SyncedScrollRow> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.scrollOffset.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (!_controller.hasClients) return;
    final target = widget.scrollOffset.value.clamp(
      0.0, _controller.position.maxScrollExtent,
    );
    if ((_controller.offset - target).abs() > 0.5) {
      _controller.jumpTo(target);
    }
  }

  @override
  void dispose() {
    widget.scrollOffset.removeListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: widget.child,
    );
  }
}
