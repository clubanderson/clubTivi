import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const weatherZipKey = 'weather_zipcode';
const weatherCityKey = 'weather_city_name';

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

/// Geocode a US zip code via Open-Meteo's geocoding API.
/// Returns {lat, lon, city} or null on failure.
Future<Map<String, dynamic>?> geocodeZipcode(String zip) async {
  try {
    final resp = await http.get(Uri.parse(
      'https://geocoding-api.open-meteo.com/v1/search?name=$zip&count=1&language=en&format=json',
    ));
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body);
    final results = data['results'] as List?;
    if (results == null || results.isEmpty) return null;
    final r = results[0];
    return {
      'lat': r['latitude'],
      'lon': r['longitude'],
      'city': r['name'] ?? zip,
    };
  } catch (_) {
    return null;
  }
}

class WeatherNotifier extends StateNotifier<WeatherData?> {
  WeatherNotifier() : super(null) {
    _fetch();
  }

  /// Force a refresh (called after user changes location in settings).
  void refresh() => _fetch();

  Future<void> _fetch() async {
    try {
      double? lat;
      double? lon;
      String city = '';

      // Check if user has set a zipcode in preferences
      final prefs = await SharedPreferences.getInstance();
      final savedZip = prefs.getString(weatherZipKey);

      if (savedZip != null && savedZip.isNotEmpty) {
        final geo = await geocodeZipcode(savedZip);
        if (geo != null) {
          lat = (geo['lat'] as num).toDouble();
          lon = (geo['lon'] as num).toDouble();
          city = prefs.getString(weatherCityKey) ?? geo['city'] as String;
        }
      }

      // Fallback to IP-based geolocation
      if (lat == null || lon == null) {
        final locResp = await http.get(Uri.parse('https://ipapi.co/json/'));
        if (locResp.statusCode != 200) return;
        final loc = jsonDecode(locResp.body);
        lat = (loc['latitude'] as num).toDouble();
        lon = (loc['longitude'] as num).toDouble();
        city = loc['city'] ?? '';

        // Prefill the saved zipcode/city for settings UI
        final detectedZip = loc['postal'] ?? '';
        if (detectedZip.isNotEmpty && (savedZip == null || savedZip.isEmpty)) {
          await prefs.setString(weatherZipKey, detectedZip);
          await prefs.setString(weatherCityKey, city);
        }
      }

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
