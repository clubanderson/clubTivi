import 'package:flutter/material.dart';
import 'player_service.dart';

/// Badges showing stream technical info: resolution, aspect ratio, audio, codec.
class StreamInfoBadges extends StatefulWidget {
  final PlayerService playerService;
  const StreamInfoBadges({super.key, required this.playerService});

  @override
  State<StreamInfoBadges> createState() => _StreamInfoBadgesState();
}

class _StreamInfoBadgesState extends State<StreamInfoBadges> {
  String? _resolution;
  String? _aspect;
  String? _audioChannels;
  String? _videoCodec;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant StreamInfoBadges old) {
    super.didUpdateWidget(old);
    _refresh();
  }

  Future<void> _refresh() async {
    final ps = widget.playerService;
    final w = await ps.getMpvProperty('video-params/w');
    final h = await ps.getMpvProperty('video-params/h');
    final aspect = await ps.getMpvProperty('video-params/aspect');
    final aCh = await ps.getMpvProperty('audio-params/channel-count');
    final codec = await ps.getMpvProperty('video-codec');
    if (!mounted) return;
    setState(() {
      if (w != null && h != null) {
        final height = int.tryParse(h) ?? 0;
        if (height >= 2160) {
          _resolution = '4K';
        } else if (height > 0) {
          _resolution = '${height}p';
        }
      } else {
        _resolution = null;
      }
      if (aspect != null) {
        final a = double.tryParse(aspect);
        if (a != null && a > 0) {
          if ((a - 16 / 9).abs() < 0.05) {
            _aspect = '16:9';
          } else if ((a - 4 / 3).abs() < 0.05) {
            _aspect = '4:3';
          } else if ((a - 21 / 9).abs() < 0.1) {
            _aspect = '21:9';
          } else {
            _aspect = a.toStringAsFixed(2);
          }
        }
      } else {
        _aspect = null;
      }
      if (aCh != null) {
        final count = int.tryParse(aCh) ?? 0;
        if (count == 2) {
          _audioChannels = '2.0';
        } else if (count == 6) {
          _audioChannels = '5.1';
        } else if (count == 8) {
          _audioChannels = '7.1';
        } else if (count == 1) {
          _audioChannels = 'Mono';
        } else if (count > 0) {
          _audioChannels = '${count}ch';
        }
      } else {
        _audioChannels = null;
      }
      if (codec != null && codec.isNotEmpty) {
        _videoCodec = codec.replaceAll(RegExp(r'^--'), '').split(' ').first;
      } else {
        _videoCodec = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final badges = <String>[
      if (_resolution != null) _resolution!,
      if (_aspect != null) _aspect!,
      if (_audioChannels != null) _audioChannels!,
      if (_videoCodec != null) _videoCodec!,
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: badges
          .map((b) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white24, width: 0.5),
                ),
                child: Text(b,
                    style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600)),
              ))
          .toList(),
    );
  }
}
