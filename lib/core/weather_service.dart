import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

class WeatherData {
  final String city;
  final double tempF;
  final int weatherCode;
  final String icon;
  final DateTime fetchedAt;

  WeatherData({
    required this.city,
    required this.tempF,
    required this.weatherCode,
    required this.icon,
    required this.fetchedAt,
  });
}

String _weatherCodeToIcon(int code) {
  if (code == 0) return '☀️';
  if (code >= 1 && code <= 1) return '🌤️';
  if (code == 2) return '⛅';
  if (code == 3) return '☁️';
  if (code >= 45 && code <= 48) return '🌫️';
  if (code >= 51 && code <= 67) return '🌧️';
  if (code >= 71 && code <= 77) return '❄️';
  if (code >= 80 && code <= 82) return '🌧️';
  if (code >= 95 && code <= 99) return '🌩️';
  return '🌡️';
}

class WeatherNotifier extends StateNotifier<WeatherData?> {
  WeatherNotifier() : super(null) {
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final locResp = await http.get(Uri.parse('https://ipapi.co/json/'));
      if (locResp.statusCode != 200) return;
      final loc = jsonDecode(locResp.body);
      final lat = loc['latitude'];
      final lon = loc['longitude'];
      final city = loc['city'] ?? '';

      final wxResp = await http.get(Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,weather_code'
        '&temperature_unit=fahrenheit',
      ));
      if (wxResp.statusCode != 200) return;
      final wx = jsonDecode(wxResp.body);
      final current = wx['current'];
      final temp = (current['temperature_2m'] as num).toDouble();
      final code = (current['weather_code'] as num).toInt();

      state = WeatherData(
        city: city,
        tempF: temp,
        weatherCode: code,
        icon: _weatherCodeToIcon(code),
        fetchedAt: DateTime.now(),
      );
    } catch (_) {
      // Fail silently — widget will show clock only
    }

    // Refresh every 30 minutes
    Future.delayed(const Duration(minutes: 30), _fetch);
  }
}

final weatherProvider =
    StateNotifierProvider<WeatherNotifier, WeatherData?>((ref) {
  return WeatherNotifier();
});
