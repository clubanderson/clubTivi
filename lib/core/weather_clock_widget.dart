import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'weather_service.dart';

class WeatherClockWidget extends ConsumerStatefulWidget {
  const WeatherClockWidget({super.key});

  @override
  ConsumerState<WeatherClockWidget> createState() => _WeatherClockWidgetState();
}

class _WeatherClockWidgetState extends ConsumerState<WeatherClockWidget> {
  late Timer _timer;
  String _timeString = '';

  @override
  void initState() {
    super.initState();
    _updateTime();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _updateTime());
  }

  void _updateTime() {
    setState(() {
      _timeString = DateFormat('h:mm a').format(DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final weather = ref.watch(weatherProvider);
    const style = TextStyle(color: Colors.white70, fontSize: 12);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (weather != null) ...[
            Text(
              '${weather.icon} ${weather.tempF.round()}°F ${weather.city}',
              style: style,
            ),
            const SizedBox(width: 8),
            Text('|', style: style.copyWith(color: Colors.white24)),
            const SizedBox(width: 8),
          ],
          Text(_timeString, style: style),
        ],
      ),
    );
  }
}
