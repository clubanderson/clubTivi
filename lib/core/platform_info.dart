import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Detects the current platform type for UI adaptation.
///
/// On Android TV, there is no touchscreen and the screen is typically
/// large and landscape. We use these heuristics to decide whether to
/// show the 10-foot TV UI (sidebar nav, large focus rings, D-pad nav)
/// or the standard mobile/desktop UI.
class PlatformInfo {
  PlatformInfo._();

  static bool? _isTvOverride;

  /// Force TV mode (useful for testing on desktop with keyboard).
  static void setTvOverride(bool value) => _isTvOverride = value;

  /// True when running on Android TV (or overridden for testing).
  static bool get isTV {
    if (_isTvOverride != null) return _isTvOverride!;
    // On Android, detect TV by checking if it's a large landscape device
    // without a touchscreen. The `android.software.leanback` feature
    // presence is the canonical signal, but from Flutter/Dart we rely
    // on heuristics: non-web Android + the absence of pointer-based input.
    if (kIsWeb) return false;
    return Platform.isAndroid && _detectedAsTV;
  }

  static bool get isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS) && !isTV;

  static bool get isDesktop =>
      !kIsWeb &&
      (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  /// Cached TV detection result (set after first MediaQuery access).
  static bool _detectedAsTV = false;

  /// Call this once from a widget that has access to [MediaQuery].
  /// Detects TV by screen size + shortest side heuristic.
  static void detectFromContext(BuildContext context) {
    if (_isTvOverride != null) return;
    if (!Platform.isAndroid) return;

    final data = MediaQuery.of(context);
    final size = data.size;
    final shortest = size.shortestSide;
    // Android TV: landscape, large screen (shortest side > 500dp typically),
    // and no system touch-based padding (or device pixel ratio suggests TV).
    // Also check if no touch pointer devices are present.
    final hasNoTouch = data.navigationMode == NavigationMode.directional;
    final isLargeScreen = shortest > 500 && size.width > size.height;

    _detectedAsTV = hasNoTouch || (isLargeScreen && data.devicePixelRatio < 2.0);
  }
}
