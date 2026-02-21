import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  void initState() {
    super.initState();
    // Scroll to "now" on load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final nowMinutes = _focusTime.hour * 60 + _focusTime.minute;
        _scrollController.jumpTo(nowMinutes * _pixelsPerMinute - 100);
      }
    });
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
                        return _ChannelGuideRow(
                          channelName: channel.name,
                          channelLogo: channel.tvgLogo,
                          scrollController: _scrollController,
                          database: database,
                          channelId: channel.id,
                          focusDate: _focusTime,
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

class _ChannelGuideRow extends StatelessWidget {
  final String channelName;
  final String? channelLogo;
  final ScrollController scrollController;
  final db.AppDatabase database;
  final String channelId;
  final DateTime focusDate;

  const _ChannelGuideRow({
    required this.channelName,
    this.channelLogo,
    required this.scrollController,
    required this.database,
    required this.channelId,
    required this.focusDate,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          // Channel label
          SizedBox(
            width: 120,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                channelName,
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          // Programme blocks (placeholder — populated when EPG data exists)
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Center(
                child: Text(
                  'No EPG data',
                  style: TextStyle(fontSize: 10, color: Colors.white24),
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
