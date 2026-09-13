import 'package:flutter/foundation.dart';

/// Gesture settings for the (synthetic-mode) touchpad. On the uinput backend
/// these are irrelevant: libinput interprets the raw frames like a hardware
/// touchpad and the app streams touches untouched.
@immutable
class TouchpadSettings {
  const TouchpadSettings({
    this.cursorSensitivity = 2.2,
    this.scrollScale = 1.0,
    this.naturalScroll = true,
    this.multiFingerGestures = true,
    this.dragLock = true,
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

  TouchpadSettings copyWith({
    double? cursorSensitivity,
    double? scrollScale,
    bool? naturalScroll,
    bool? multiFingerGestures,
    bool? dragLock,
  }) {
    return TouchpadSettings(
      cursorSensitivity: cursorSensitivity ?? this.cursorSensitivity,
      scrollScale: scrollScale ?? this.scrollScale,
      naturalScroll: naturalScroll ?? this.naturalScroll,
      multiFingerGestures: multiFingerGestures ?? this.multiFingerGestures,
      dragLock: dragLock ?? this.dragLock,
    );
  }
}