import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'touchpad_engine.dart';
import 'touchpad_settings.dart';

void _log(String msg) => debugPrint('[TP] $msg');

class TouchpadSurface extends StatefulWidget {
  const TouchpadSurface({
    super.key,
    required this.engine,
    this.settings = const TouchpadSettings(),
  });

  final TouchpadEngine engine;
  final TouchpadSettings settings;

  @override
  State<TouchpadSurface> createState() => _TouchpadSurfaceState();
}

class _TouchpadSurfaceState extends State<TouchpadSurface> {
  final Map<int, Offset> _pointers = <int, Offset>{};

  DateTime? _sessionStart;
  DateTime? _lastActivity;
  double _sessionDistance = 0;
  int _sessionFingers = 0; // max simultaneous fingers seen this session
  Offset _gestureAccum = Offset.zero; // centroid travel while 3+ fingers down
  bool _scrolling = false; // a two-finger gesture is in progress
  bool _dragHeld = false;
  Timer? _longPress;
  Timer? _flushTimer;
  Offset _pendingMotion = Offset.zero;
  Offset _pendingScroll = Offset.zero;

  // Double-tap drag-lock state.
  DateTime? _lastTapTime;
  bool _doubleTapPending = false;
  Timer? _dragLockTimer;

  Size _size = Size.zero;
  Timer? _frameTimer;

  static const _tapDuration = Duration(milliseconds: 400);
  static const _longPressDuration = Duration(milliseconds: 500);
  static const _maxTapDistance = 24.0;
  static const _flushInterval = Duration(milliseconds: 16);
  static const _frameInterval = Duration(milliseconds: 33);
  static const _doubleTapWindow = Duration(milliseconds: 380);
  static const _dragLockDelay = Duration(milliseconds: 260);
  static const _gestureThreshold = 60.0;
  static const _palmLimit = 5; // >= this many simultaneous touches = palm

  /// Settings applied to synthetic gestures (cursor/scroll/multi-finger).
  TouchpadSettings get _settings => widget.settings;

  /// When the daemon reports backend=uinput it is a native multitouch
  /// touchpad: libinput does ALL gesture interpretation, so we just stream
  /// raw touch states and let the compositor behave as with a real pad.
  bool get _raw => widget.engine.wantsRawTouch;

  @override
  void initState() {
    super.initState();
    // Rate-limit motion/scroll sends: the adb-reverse transport on this phone
    // drops and delays data when flooded, so coalesce deltas and flush at a
    // modest fixed rate instead of per pointer event.
    _flushTimer = Timer.periodic(_flushInterval, (_) => _flushPending());
  }

  /// Raw uinput touchpad: libinput interprets cursor, scroll, taps, drags and
/// gestures from the touch frames alone — exactly like a hardware touchpad
/// (the compositor's tap-to-click is on). We never synthesize buttons or REL
/// motion here.
  void _flushPending() {
    if (!_raw && _pendingMotion != Offset.zero) {
      widget.engine.moveBy(_pendingMotion.dx, _pendingMotion.dy);
    }
    if (!_raw && _pendingScroll != Offset.zero) {
      widget.engine.scrollSmooth(_pendingScroll.dx, _pendingScroll.dy);
    }
    _pendingMotion = Offset.zero;
    _pendingScroll = Offset.zero;
  }

  @override
  void dispose() {
    _log('dispose drag=$_dragHeld');
    _flushTimer?.cancel();
    _frameTimer?.cancel();
    _flushPending();
    if (_dragHeld) {
      widget.engine.button(1, false);
    }
    if (_raw) {
      widget.engine.sendLine('t 0');
    }
    _longPress?.cancel();
    super.dispose();
  }

  Offset? _centroid() {
    if (_pointers.isEmpty) return null;
    var s = Offset.zero;
    for (final p in _pointers.values) {
      s += p;
    }
    return s / _pointers.length.toDouble();
  }

  void _beginSession() {
    _sessionStart = DateTime.now();
    _sessionDistance = 0;
    _scrolling = false;
    _sessionFingers = 0;
    _gestureAccum = Offset.zero;
  }

  // ----------------------------------------------------- raw touch frames

  Offset _normalized(Offset pos) {
    final w = _size.width;
    final h = _size.height;
    if (w <= 0 || h <= 0) return Offset.zero;
    return Offset((pos.dx / w).clamp(0.0, 1.0), (pos.dy / h).clamp(0.0, 1.0));
  }

  String _buildFrame() {
    if (_pointers.isEmpty) return 't 0';
    final entries = _pointers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final sb = StringBuffer('t ${entries.length}');
    for (final e in entries) {
      final n = _normalized(e.value);
      sb.write(' ${e.key}:${n.dx.toStringAsFixed(3)},${n.dy.toStringAsFixed(3)}');
    }
    return sb.toString();
  }

  /// Send the current full touch state, then keep re-sending while any finger
  /// is down so a lost frame self-heals and a lost PointerUp/Cancel clears.
  void _sendFrameNow() {
    if (!_raw) return;
    widget.engine.sendLine(_buildFrame());
    if (_frameTimer != null) return;
    _frameTimer = Timer.periodic(_frameInterval, (_) {
      if (_pointers.isEmpty) {
        _frameTimer?.cancel();
        _frameTimer = null;
        return;
      }
      if (_lastActivity != null &&
          DateTime.now().difference(_lastActivity!) >
              const Duration(milliseconds: 300)) {
        _pointers.clear();
        widget.engine.sendLine('t 0');
        _frameTimer?.cancel();
        _frameTimer = null;
        return;
      }
      widget.engine.sendLine(_buildFrame());
    });
  }

  void _finishPointer(int id) {
    _lastActivity = DateTime.now();
    if (id >= 0) _pointers.remove(id);
    if (_pointers.isNotEmpty) {
      if (_raw) _sendFrameNow();
      return;
    }

    // All pointers are up. Cancel the resend timer first so a stale re-frame
    // cannot be emitted before our click (a click must go out while the last
    // touch is still present, then we clear with 't 0').
    _frameTimer?.cancel();
    _frameTimer = null;

    _longPress?.cancel();
    _longPress = null;

    final dur = DateTime.now().difference(_sessionStart ?? DateTime.now());
    final quick = dur < _tapDuration;
    final still = _sessionDistance < _maxTapDistance;
    final palm = _sessionFingers >= _palmLimit;
    _log('finish-tap f=$_sessionFingers dur=${dur.inMilliseconds} '
        'quick=$quick still=$still dist=$_sessionDistance palm=$palm');

    if (_dragHeld) {
      _log('finish-released drag');
      _dragHeld = false;
      widget.engine.button(1, false);
    } else if (!palm && !_raw) {
      if (_sessionFingers >= 3 && _settings.multiFingerGestures) {
        _flushPending();
        if (_gestureAccum.distance >= _gestureThreshold) {
          _doMultiSwipe(_sessionFingers, _gestureAccum);
        } else if (quick && still && _sessionFingers == 3) {
          widget.engine.clickTap(2); // three-finger tap -> middle click
        }
        // Four-finger tap: conventionally no action.
      } else if (quick && still) {
        _flushPending();
        if (_sessionFingers == 2) {
          widget.engine.clickTap(3); // two-finger tap -> right click
        } else if (_sessionFingers == 1) {
          _lastTapTime = DateTime.now();
          widget.engine.clickTap(1);
        }
      }
    } else if (palm) {
      _log('palm: gesture ignored');
    }

    _cancelPendingDoubleTap();
    _beginSession();
    if (_raw) widget.engine.sendLine('t 0');
  }

  // --------------------------------------------------------- event handlers

  void _onDown(PointerDownEvent e) {
    final now = DateTime.now();
    // Heal a stuck pointer if no event arrived for a while (e.g. a lost
    // PointerUp/Cancel from a previous gesture).
    if (_pointers.isNotEmpty &&
        _lastActivity != null &&
        now.difference(_lastActivity!) > const Duration(milliseconds: 250)) {
      _log('heal-stale pointers=${_pointers.length}');
      _pointers.clear();
    }
    _lastActivity = now;
    final first = _pointers.isEmpty;
    if (first) _beginSession();
    _pointers[e.pointer] = e.localPosition;
    _sessionFingers = math.max(_sessionFingers, _pointers.length);
    if (_raw) _sendFrameNow();
    _log('down id=${e.pointer} first=$first drag=$_dragHeld '
        'scroll=$_scrolling n=${_pointers.length}');
    if (first) {
      if (_dragHeld) return;
      // A fast second tap (within the double-tap window) arms drag-lock
      // instead of the plain long-press, like a hardware touchpad.
      final recent =
          _lastTapTime != null && now.difference(_lastTapTime!) < _doubleTapWindow;
      if (recent && _settings.dragLock) {
        _doubleTapPending = true;
        _longPress?.cancel();
        _longPress = null;
        _dragLockTimer?.cancel();
        _dragLockTimer = Timer(_dragLockDelay, _onDragLock);
        _log('arm-draglock');
      } else {
        _longPress?.cancel();
        _longPress = Timer(_longPressDuration, _onLongPress);
        _log('arm-longpress');
      }
    } else {
      _scrolling = true;
      _longPress?.cancel();
      if (_dragHeld) {
        _log('second-finger cancels drag');
        _dragHeld = false;
        widget.engine.button(1, false);
      }
      if (_pointers.length >= _palmLimit) {
        // A flat palm has landed on the pad: discard any pending intent.
        _gestureAccum = Offset.zero;
        _cancelPendingDoubleTap();
        if (_dragHeld) {
          _dragHeld = false;
          widget.engine.button(1, false);
        }
        _log('palm detected');
      }
      _log('two-finger scroll armed');
    }
  }

  void _onMove(PointerMoveEvent e) {
    _lastActivity = DateTime.now();
    final prev = _pointers[e.pointer];
    if (prev == null) return;
    final before = _centroid();
    _pointers[e.pointer] = e.localPosition;
    final after = _centroid();
    if (_raw) _sendFrameNow();

    final n = _pointers.length;

    // Double-tap drag-lock intent: moving past tap radius cancels it.
    if (_doubleTapPending && _sessionDistance > _maxTapDistance) {
      _cancelPendingDoubleTap();
    }

    // Palm: a flat hand on the pad contributes nothing.
    if (n >= _palmLimit) return;

    // 3+ fingers: no cursor motion, no scroll — only multi-finger gestures.
    if (n >= 3) {
      if (_settings.multiFingerGestures && before != null && after != null) {
        _gestureAccum += after - before;
      }
      return;
    }

    if (_scrolling) {
      // Two-finger session: keep scrolling with centroid movement.
      if (before != null && after != null) {
        final d = after - before;
        _pendingScroll += Offset(
          d.dx * _settings.scrollScale,
          (_settings.naturalScroll ? d.dy : -d.dy) * _settings.scrollScale,
        );
      }
      return;
    }

    final delta = e.localPosition - prev;
    _sessionDistance += delta.distance;
    _pendingMotion += Offset(
      delta.dx * _settings.cursorSensitivity,
      delta.dy * _settings.cursorSensitivity,
    );
  }

  void _onLongPress() {
    // Touchpad (raw) mode: libinput's tap-and-drag already handles holding.
    if (_raw) return;
    if (_pointers.length != 1 || _scrolling) return;
    if (_sessionDistance > _maxTapDistance) return;
    _dragHeld = true;
    _log('longpress fire d=$_sessionDistance');
    widget.engine.button(1, true);
  }

  /// Double-tap drag-lock: second fast tap held still long enough becomes a
  /// drag, exactly like a hardware touchpad's tap-and-drag.
  void _onDragLock() {
    _dragLockTimer = null;
    if (_raw || !_doubleTapPending || _dragHeld) return;
    if (_pointers.length != 1 || _scrolling) {
      _cancelPendingDoubleTap();
      return;
    }
    if (_sessionDistance > _maxTapDistance) {
      _cancelPendingDoubleTap();
      return;
    }
    _doubleTapPending = false;
    _dragHeld = true;
    _log('drag-lock fire d=$_sessionDistance');
    widget.engine.button(1, true);
  }

  void _cancelPendingDoubleTap() {
    _doubleTapPending = false;
    _dragLockTimer?.cancel();
    _dragLockTimer = null;
  }

  /// Translate a 3/4-finger swipe into the conventional key chords. The
  /// codes are evdev values passed through by the daemon, so they work on
  /// every backend (SendInput maps them on Windows).
  void _doMultiSwipe(int fingers, Offset delta) {
    final absX = delta.dx.abs();
    final absY = delta.dy.abs();
    _log('swipe f=$fingers d=${delta.dx.toStringAsFixed(1)},'
        '${delta.dy.toStringAsFixed(1)}');
    if (absY > absX) {
      if (delta.dy < 0) {
        // Swipe up: task view.
        _chord(const [125, 15]); // Super + Tab
      } else {
        // Swipe down: show desktop.
        _chord(const [125, 32]); // Super + d
      }
    } else {
      if (delta.dx < 0) {
        _chord(const [56, 15]); // Alt + Tab: next window
      } else {
        _chord(const [56, 42, 15]); // Alt + Shift + Tab: previous window
      }
    }
  }

  void _chord(Iterable<int> codes) => widget.engine.chord(codes);

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _log('panzoom-start');
    if (_raw) {
      _pointers.clear();
      _sendFrameNow();
      return;
    }
    _pointers.clear();
    _scrolling = true;
    _longPress?.cancel();
    _cancelPendingDoubleTap();
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    _pendingScroll += Offset(
      e.panDelta.dx * _settings.scrollScale,
      (_settings.naturalScroll ? e.panDelta.dy : -e.panDelta.dy) *
          _settings.scrollScale,
    );
  }

  void _onPanZoomEnd(PointerPanZoomEndEvent e) {
    _log('panzoom-end');
    _pointers.clear();
    _scrolling = false;
    _longPress?.cancel();
    _cancelPendingDoubleTap();
    _flushPending();
    widget.engine.scrollStop();
  }

  void _onUp(PointerUpEvent e) {
    _log('up id=${e.pointer} area=${e.localPosition}');
    _finishPointer(e.pointer);
  }

  void _onCancel(PointerCancelEvent e) {
    _log('cancel id=${e.pointer}');
    if (_raw) {
      _finishPointer(e.pointer);
      return;
    }
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) {
      _scrolling = false;
    }
    if (_pointers.isEmpty) {
      _longPress?.cancel();
      _longPress = null;
      _cancelPendingDoubleTap();
      if (_dragHeld) {
        _dragHeld = false;
        widget.engine.button(1, false);
      }
      _beginSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      _size = constraints.biggest;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        onPointerPanZoomStart: _onPanZoomStart,
        onPointerPanZoomUpdate: _onPanZoomUpdate,
        onPointerPanZoomEnd: _onPanZoomEnd,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                cs.surfaceContainerHigh,
                cs.surfaceContainerLowest,
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.5),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            children: [
              // Subtle Material 3 trackpad center watermark & hint
              Center(
                child: Opacity(
                  opacity: 0.12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.touch_app_rounded,
                        size: 42,
                        color: cs.primary,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Multitouch Trackpad',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                          color: cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Subtle bottom click zone divider
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Container(
                    width: 1,
                    height: 16,
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}