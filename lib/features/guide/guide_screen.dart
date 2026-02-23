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
    // Scroll to "now" on load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final nowMinutes = _focusTime.hour * 60 + _focusTime.minute;
        _scrollController.jumpTo(nowMinutes * _pixelsPerMinute - 100);
      }
    });
  }

  Future<void> _loadMappings() async {
    final database = ref.read(databaseProvider);
    final mappings = await database.getAllMappings();
    final epgMap = <String, String>{};
    for (final m in mappings) {
      epgMap[m.channelId] = '${m.epgSourceId}_${m.epgChannelId}';
    }
    final epgSources = await database.getAllEpgSources();
    final validIds = <String>{};
    for (final src in epgSources) {
      final chs = await database.getEpgChannelsForSource(src.id);
      for (final ch in chs) {
        validIds.add(ch.id);
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
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
              // Time ruler
              SizedBox(
                height: 32,
                child: _TimeRuler(
                  scrollController: _scrollController,
                  focusDate: _focusTime,
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
                          scrollController: _scrollController,
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
          return SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '${hour.toString().padLeft(2, '0')}:00',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
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
  final ScrollController scrollController;
  final db.AppDatabase database;
  final String? epgChannelId;
  final DateTime focusDate;
  final double pixelsPerMinute;

  const _ChannelGuideRow({
    required this.channelName,
    this.channelLogo,
    required this.scrollController,
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
      if (mounted) setState(() { _programmes = progs; _loading = false; });
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

    return SizedBox(
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
          // Programme timeline
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scrollController,
              scrollDirection: Axis.horizontal,
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
        message: '${prog.title}\n${_fmtTime(prog.start)} – ${_fmtTime(prog.stop)}',
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
          alignment: Alignment.centerLeft,
          child: Text(
            prog.title,
            style: TextStyle(
              fontSize: 10,
              color: isNow ? Colors.white : Colors.white70,
              fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
            ),
            maxLines: 2, overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  String _fmtTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
