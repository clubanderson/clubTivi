import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Unified input manager that normalizes events from all input sources:
/// - Physical remotes (Android TV IR/BT, Fire TV, Onn)
/// - Keyboard (desktop)
/// - Gamepad / game controller
/// - D-pad navigation
/// - Web companion remote (via WebSocket — see web_remote_server.dart)
///
/// All inputs are translated to [AppAction]s so the UI layer never
/// needs to know which device generated the event.
class InputManager {
  final Map<LogicalKeyboardKey, AppAction> _keyMap;

  InputManager({Map<LogicalKeyboardKey, AppAction>? customKeyMap})
      : _keyMap = customKeyMap ?? _defaultKeyMap;

  /// Translate a raw key event into an AppAction.
  AppAction? handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    return _keyMap[event.logicalKey];
  }

  /// Default key → action mapping covering remotes, keyboards, and D-pads.
  static final Map<LogicalKeyboardKey, AppAction> _defaultKeyMap = {
    // Navigation
    LogicalKeyboardKey.arrowUp: AppAction.navigateUp,
    LogicalKeyboardKey.arrowDown: AppAction.navigateDown,
    LogicalKeyboardKey.arrowLeft: AppAction.navigateLeft,
    LogicalKeyboardKey.arrowRight: AppAction.navigateRight,
    LogicalKeyboardKey.select: AppAction.select,
    LogicalKeyboardKey.enter: AppAction.select,
    LogicalKeyboardKey.gameButtonA: AppAction.select,

    // Back
    LogicalKeyboardKey.escape: AppAction.back,
    LogicalKeyboardKey.goBack: AppAction.back,
    LogicalKeyboardKey.gameButtonB: AppAction.back,
    LogicalKeyboardKey.backspace: AppAction.back,

    // Channel
    LogicalKeyboardKey.channelUp: AppAction.channelUp,
    LogicalKeyboardKey.channelDown: AppAction.channelDown,
    LogicalKeyboardKey.pageUp: AppAction.channelUp,
    LogicalKeyboardKey.pageDown: AppAction.channelDown,

    // Volume
    LogicalKeyboardKey.audioVolumeUp: AppAction.volumeUp,
    LogicalKeyboardKey.audioVolumeDown: AppAction.volumeDown,
    LogicalKeyboardKey.audioVolumeMute: AppAction.mute,

    // Playback
    LogicalKeyboardKey.mediaPlay: AppAction.play,
    LogicalKeyboardKey.mediaPause: AppAction.pause,
    LogicalKeyboardKey.mediaPlayPause: AppAction.playPause,
    LogicalKeyboardKey.mediaStop: AppAction.stop,
    LogicalKeyboardKey.mediaRewind: AppAction.rewind,
    LogicalKeyboardKey.mediaFastForward: AppAction.fastForward,
    LogicalKeyboardKey.space: AppAction.playPause,

    // Quick actions
    LogicalKeyboardKey.keyG: AppAction.openGuide,
    LogicalKeyboardKey.keyI: AppAction.showInfo,
    LogicalKeyboardKey.keyF: AppAction.toggleFavorite,
    LogicalKeyboardKey.keyM: AppAction.openMultiView,
    LogicalKeyboardKey.keyR: AppAction.startRecording,
    LogicalKeyboardKey.keyS: AppAction.openSettings,

    // Number keys for direct channel entry
    LogicalKeyboardKey.digit0: AppAction.digit0,
    LogicalKeyboardKey.digit1: AppAction.digit1,
    LogicalKeyboardKey.digit2: AppAction.digit2,
    LogicalKeyboardKey.digit3: AppAction.digit3,
    LogicalKeyboardKey.digit4: AppAction.digit4,
    LogicalKeyboardKey.digit5: AppAction.digit5,
    LogicalKeyboardKey.digit6: AppAction.digit6,
    LogicalKeyboardKey.digit7: AppAction.digit7,
    LogicalKeyboardKey.digit8: AppAction.digit8,
    LogicalKeyboardKey.digit9: AppAction.digit9,
    LogicalKeyboardKey.numpad0: AppAction.digit0,
    LogicalKeyboardKey.numpad1: AppAction.digit1,
    LogicalKeyboardKey.numpad2: AppAction.digit2,
    LogicalKeyboardKey.numpad3: AppAction.digit3,
    LogicalKeyboardKey.numpad4: AppAction.digit4,
    LogicalKeyboardKey.numpad5: AppAction.digit5,
    LogicalKeyboardKey.numpad6: AppAction.digit6,
    LogicalKeyboardKey.numpad7: AppAction.digit7,
    LogicalKeyboardKey.numpad8: AppAction.digit8,
    LogicalKeyboardKey.numpad9: AppAction.digit9,
  };
}

/// App-level actions (input-source agnostic).
enum AppAction {
  // Navigation
  navigateUp,
  navigateDown,
  navigateLeft,
  navigateRight,
  select,
  back,

  // Channel
  channelUp,
  channelDown,

  // Volume
  volumeUp,
  volumeDown,
  mute,

  // Playback
  play,
  pause,
  playPause,
  stop,
  rewind,
  fastForward,

  // Quick actions
  openGuide,
  showInfo,
  toggleFavorite,
  openMultiView,
  startRecording,
  openSettings,

  // Direct channel entry
  digit0, digit1, digit2, digit3, digit4,
  digit5, digit6, digit7, digit8, digit9,
}

/// Widget that intercepts all key events and dispatches AppActions.
class InputHandler extends StatelessWidget {
  final Widget child;
  final void Function(AppAction action) onAction;
  final FocusNode? focusNode;

  const InputHandler({
    super.key,
    required this.child,
    required this.onAction,
    this.focusNode,
  });

  static final _inputManager = InputManager();

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: focusNode ?? FocusNode(),
      autofocus: true,
      onKeyEvent: (event) {
        final action = _inputManager.handleKeyEvent(event);
        if (action != null) onAction(action);
      },
      child: child,
    );
  }
}

/// Riverpod provider.
final inputManagerProvider = Provider<InputManager>((ref) {
  return InputManager();
});
