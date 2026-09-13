import 'package:flutter/foundation.dart';

/// Gesture + connection settings. On the uinput backend the gesture knobs are
/// irrelevant: libinput interprets the raw frames like a hardware touchpad
/// and the app streams touches untouched.
@immutable
class TouchpadSettings {
  const TouchpadSettings({
    this.cursorSensitivity = 2.2,
    this.scrollScale = 1.0,
    this.naturalScroll = true,
    this.multiFingerGestures = true,
    this.dragLock = true,
    this.serverHost = '',
  });

  /// Cursor movement multiplier (1.0 = finger distance travels cursor distance).
  final double cursorSensitivity;

  /// Scroll speed multiplier applied to two-finger deltas.
  final double scrollScale;

  /// When true, two-finger content follows the fingers (finger down scrolls
  /// content down). When false the Y axis is inverted (mouse-wheel style).
  final bool naturalScroll;

  /// Enable 3/4-finger gestures: 3-finger tap (middle click) and swipes
  /// (task view / show desktop / app switch via key chords).
  final bool multiFingerGestures;

  /// Enable double-tap-and-hold drag-lock.
  final bool dragLock;

  /// Daemon address spoken by the remote (phone) transport.
  ///
  /// Empty = legacy `adb reverse tcp:4321` loopback. A filled value (e.g.
  /// `192.168.43.23`) switches the phone to LAN/hotspot mode: it connects
  /// straight to the laptop's daemon over the hotspot, no adb needed.
  final String serverHost;

  TouchpadSettings copyWith({
    double? cursorSensitivity,
    double? scrollScale,
    bool? naturalScroll,
    bool? multiFingerGestures,
    bool? dragLock,
    String? serverHost,
  }) {
    return TouchpadSettings(
      cursorSensitivity: cursorSensitivity ?? this.cursorSensitivity,
      scrollScale: scrollScale ?? this.scrollScale,
      naturalScroll: naturalScroll ?? this.naturalScroll,
      multiFingerGestures: multiFingerGestures ?? this.multiFingerGestures,
      dragLock: dragLock ?? this.dragLock,
      serverHost: serverHost ?? this.serverHost,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'cursorSensitivity': cursorSensitivity,
        'scrollScale': scrollScale,
        'naturalScroll': naturalScroll,
        'multiFingerGestures': multiFingerGestures,
        'dragLock': dragLock,
        'serverHost': serverHost,
      };

  static TouchpadSettings fromJson(Map<String, Object?> json) {
    return TouchpadSettings(
      cursorSensitivity:
          (json['cursorSensitivity'] as num?)?.toDouble() ?? 2.2,
      scrollScale: (json['scrollScale'] as num?)?.toDouble() ?? 1.0,
      naturalScroll: json['naturalScroll'] as bool? ?? true,
      multiFingerGestures: json['multiFingerGestures'] as bool? ?? true,
      dragLock: json['dragLock'] as bool? ?? true,
      serverHost: json['serverHost'] as String? ?? '',
    );
  }
}