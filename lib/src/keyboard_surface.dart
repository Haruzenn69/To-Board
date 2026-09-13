import 'package:flutter/material.dart';

import 'touchpad_engine.dart';

/// A laptop-style virtual keyboard. It drives a separate virtual keyboard
/// device on the daemon (which it creates on mount via `kb 1` and destroys on
/// dispose via `kb 0`), so the touchpad device is left untouched while typing.
class KeyboardSurface extends StatefulWidget {
  const KeyboardSurface({super.key, required this.engine, this.onSwitch});

  final TouchpadEngine engine;

  /// Invoked when the special Swch key is pressed to go back to the touchpad.
  final VoidCallback? onSwitch;

  @override
  State<KeyboardSurface> createState() => _KeyboardSurfaceState();
}

// Key definitions: (label, evdev code, flex width). Codes are Linux
// input-event-codes.h values; the daemon passes them through unchanged.
// A null code marks the special Swch key (which triggers [onSwitch]).
typedef KDef = ({String label, int? code, double flex});

KDef _d(String label, int? code, [double flex = 1]) =>
    (label: label, code: code, flex: flex);

class _KeyboardSurfaceState extends State<KeyboardSurface> {
  final Set<int> _held = <int>{};

  static final List<List<KDef>> _rows = [
    [
      _d('Esc', 1),
      _d('F1', 59), _d('F2', 60), _d('F3', 61), _d('F4', 62),
      _d('F5', 63), _d('F6', 64), _d('F7', 65), _d('F8', 66),
      _d('F9', 67), _d('F10', 68), _d('F11', 69), _d('F12', 70),
      _d('PrtSc', 99), _d('Swch', null), _d('Del', 111),
    ],
    [
      _d('`', 41), _d('1', 2), _d('2', 3), _d('3', 4), _d('4', 5),
      _d('5', 6), _d('6', 7), _d('7', 8), _d('8', 9), _d('9', 10),
      _d('0', 11), _d('-', 12), _d('=', 13),
      _d('\u232B', 14, 2.0), // Backspace
      _d('PgUp', 104),
    ],
    [
      _d('Tab', 15, 1.5),
      _d('Q', 16), _d('W', 17), _d('E', 18), _d('R', 19), _d('T', 20),
      _d('Y', 21), _d('U', 22), _d('I', 23), _d('O', 24), _d('P', 25),
      _d('[', 26), _d(']', 27),
      _d('\\', 43, 1.5),
      _d('PgDn', 109),
    ],
    [
      _d('Caps', 58, 1.75),
      _d('A', 30), _d('S', 31), _d('D', 32), _d('F', 33), _d('G', 34),
      _d('H', 35), _d('J', 36), _d('K', 37), _d('L', 38), _d(';', 39),
      _d("'", 40),
      _d('Enter', 28, 2.25),
      _d('Home', 102),
    ],
    [
      _d('\u21E7', 42, 2.25), // Shift
      _d('Z', 44), _d('X', 45), _d('C', 46), _d('V', 47), _d('B', 48),
      _d('N', 49), _d('M', 50), _d(',', 51), _d('.', 52), _d('/', 53),
      _d('\u21E7', 54, 1.75),
      _d('\u2191', 103), // Up
      _d('End', 107),
    ],
    [
      _d('Ctrl', 29, 1.25),
      _d('Win', 125, 1.25),
      _d('Alt', 56, 1.25),
      _d('Space', 57, 5.5),
      _d('Alt', 100, 1.25),
      _d('Win', 126, 1.25),
      _d('Ctrl', 97, 1.25),
      _d('\u2190', 105), // Left
      _d('\u2193', 108), // Down
      _d('\u2192', 106), // Right
    ],
  ];

  @override
  void initState() {
    super.initState();
    widget.engine.keyboardMode(true);
  }

  @override
  void dispose() {
    for (final code in _held) {
      widget.engine.key(code, false);
    }
    _held.clear();
    widget.engine.keyboardMode(false);
    super.dispose();
  }

  void _down(int code) {
    _held.add(code);
    widget.engine.key(code, true);
  }

  void _up(int code) {
    _held.remove(code);
    widget.engine.key(code, false);
  }

  Widget _panel(Widget child) => Padding(
        padding: const EdgeInsets.all(2),
        child: child,
      );

  Widget _row(List<KDef> keys) => Row(
        children: [
          for (final k in keys)
            Expanded(
              flex: (k.flex * 100).round(),
              child: _panel(_Key(k, _down, _up, onSwitch: widget.onSwitch)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final r in _rows) Expanded(child: _row(r)),
      ],
    );
  }
}

enum _KeyCategory { normal, modifier, accent }

_KeyCategory _getCategory(KDef def) {
  if (def.label == 'Enter' || def.code == null) {
    return _KeyCategory.accent;
  }
  final l = def.label;
  // Function keys F1-F12 only (not the letter 'F')
  if (RegExp(r'^F([1-9]|1[0-2])$').hasMatch(l)) {
    return _KeyCategory.modifier;
  }
  if (l == 'Esc' ||
      l == 'PrtSc' ||
      l == 'Del' ||
      l == 'Tab' ||
      l == 'Caps' ||
      l == '\u21E7' ||
      l == 'Ctrl' ||
      l == 'Win' ||
      l == 'Alt' ||
      l == 'PgUp' ||
      l == 'PgDn' ||
      l == 'Home' ||
      l == 'End' ||
      l == '\u232B') {
    return _KeyCategory.modifier;
  }
  return _KeyCategory.normal;
}

class _Key extends StatefulWidget {
  const _Key(this.def, this.onDown, this.onUp, {this.onSwitch});

  final KDef def;
  final void Function(int code) onDown;
  final void Function(int code) onUp;
  final VoidCallback? onSwitch;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _pressed = false;

  void _finish() {
    if (!_pressed) return;
    _pressed = false;
    setState(() {});
    final code = widget.def.code;
    if (code != null) widget.onUp(code);
  } 

  @override
  Widget build(BuildContext context) {
    final cat = _getCategory(widget.def);
    final cs = Theme.of(context).colorScheme;

    // Material 3 Expressive dynamic color palette adapting to wallpaper
    final (baseColor, borderColor, textColor, pressedColor) = switch (cat) {
      _KeyCategory.accent => (
        cs.primaryContainer,
        cs.primary.withValues(alpha: 0.6),
        cs.onPrimaryContainer,
        cs.primary,
      ),
      _KeyCategory.modifier => (
        cs.surfaceContainerHigh,
        cs.outlineVariant.withValues(alpha: 0.4),
        cs.onSurfaceVariant,
        cs.secondaryContainer,
      ),
      _KeyCategory.normal => (
        cs.surfaceContainer,
        cs.outlineVariant.withValues(alpha: 0.6),
        cs.onSurface,
        cs.primaryContainer,
      ),
    };

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        _pressed = true;
        setState(() {});
        final code = widget.def.code;
        if (code == null) {
          widget.onSwitch?.call();
        } else {
          widget.onDown(code);
        }
      },
      onPointerUp: (_) => _finish(),
      onPointerCancel: (_) => _finish(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 70),
        curve: Curves.easeOutQuad,
        margin: EdgeInsets.only(
          top: _pressed ? 2.0 : 0.0,
          bottom: _pressed ? 0.0 : 2.0,
        ),
        decoration: BoxDecoration(
          color: _pressed ? pressedColor : baseColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _pressed ? cs.primary : borderColor,
            width: 1.0,
          ),
          boxShadow: _pressed
              ? [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.5),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.38),
                    offset: const Offset(0, 1.8),
                    blurRadius: 1.5,
                  ),
                ],
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                widget.def.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: cat == _KeyCategory.accent
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: textColor,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}