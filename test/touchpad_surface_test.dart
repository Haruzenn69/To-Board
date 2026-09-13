import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:touchpad/src/touchpad_engine.dart';
import 'package:touchpad/src/touchpad_settings.dart';
import 'package:touchpad/src/touchpad_surface.dart';

class _FakeEngine extends TouchpadEngine {
  _FakeEngine({this.raw = false});
  final bool raw;

  @override
  bool get wantsRawTouch => raw;

  final List<String> sent = <String>[];

  @override
  void sendLine(String line) => sent.add(line);
}

void main() {
  Future<void> down(WidgetTester t, int id, Offset pos) async {
    t.binding.handlePointerEvent(
        PointerDownEvent(pointer: id, position: pos));
  }

  Future<void> move(WidgetTester t, int id, Offset pos) async {
    t.binding.handlePointerEvent(
        PointerMoveEvent(pointer: id, position: pos, delta: Offset.zero));
  }

  Future<void> up(WidgetTester t, int id, Offset pos) async {
    t.binding.handlePointerEvent(
        PointerUpEvent(pointer: id, position: pos));
  }

  testWidgets('single quick tap sends left click', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await t.pump(const Duration(milliseconds: 100));
    await up(t, 1, const Offset(200, 300));

    expect(e.sent.where((l) => l.startsWith('c ')), contains('c 1'));
  });

  testWidgets('two-finger quick tap sends right click', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(220, 300));
    await t.pump(const Duration(milliseconds: 100));
    await up(t, 1, const Offset(200, 300));
    await up(t, 2, const Offset(220, 300));

    expect(e.sent.where((l) => l.startsWith('c ')), contains('c 3'));
  });

  testWidgets('single finger drag sends motion', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await move(t, 1, const Offset(220, 315));
    await t.pump(const Duration(milliseconds: 32));
    await up(t, 1, const Offset(220, 315));

    expect(e.sent.where((l) => l.startsWith('m ')), isNotEmpty);
  });

  testWidgets('two-finger drag sends scroll and no motion', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(220, 300));
    await move(t, 1, const Offset(200, 250));
    await move(t, 2, const Offset(220, 250));
    await t.pump(const Duration(milliseconds: 32));
    await up(t, 1, const Offset(200, 250));
    await up(t, 2, const Offset(220, 250));

    expect(e.sent.where((l) => l.startsWith('s ')), isNotEmpty);
    expect(e.sent.where((l) => l.startsWith('m ')), isEmpty);
  });

  testWidgets('tap twice in a row still clicks (no stuck state)', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    for (var i = 0; i < 2; i++) {
      await down(t, 10 + i, Offset(200 + i * 10, 300));
      await t.pump(const Duration(milliseconds: 50));
      await up(t, 10 + i, Offset(200 + i * 10, 300));
    }

    final clicks = e.sent.where((l) => l.startsWith('c ')).toList();
    expect(clicks, ['c 1', 'c 1']);
  });

  testWidgets('raw mode sends touch frame on down and empty on up', (t) async {
    final e = _FakeEngine(raw: true);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    expect(e.sent.any((l) => l.startsWith('t 1 1:0.')), isTrue);
    await t.pump(const Duration(milliseconds: 100));
    await up(t, 1, const Offset(200, 300));
    final upFrame = e.sent.last;
    // Pure streaming: taps are left to libinput's tap-to-click.
    expect(e.sent.where((l) => l.startsWith('c ')), isEmpty);
    expect(upFrame == 't 0', isTrue);
  });

  testWidgets('raw mode reports two fingers in one frame', (t) async {
    final e = _FakeEngine(raw: true);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(220, 300));
    final frames = e.sent.where((l) => l.startsWith('t 2 ')).toList();
    expect(frames, isNotEmpty);
    expect(frames.last, contains(' 1:'));
    expect(frames.last, contains(' 2:'));
  });

  testWidgets('raw mode: two-finger tap emits no button, no m/s', (t) async {
    final e = _FakeEngine(raw: true);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(220, 300));
    await t.pump(const Duration(milliseconds: 100));
    await up(t, 1, const Offset(200, 300));
    await up(t, 2, const Offset(220, 300));

    expect(e.sent.last, 't 0');
    expect(e.sent.where((l) => l.startsWith('c ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('b ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('s ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('m ')), isEmpty);
  });

  testWidgets('raw mode: cursor moves only via frames, never m/', (t) async {
    final e = _FakeEngine(raw: true);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await move(t, 1, const Offset(220, 315));
    await t.pump(const Duration(milliseconds: 32));
    await up(t, 1, const Offset(220, 315));

    expect(e.sent.where((l) => l.startsWith('t 1 ')), isNotEmpty);
    expect(e.sent.where((l) => l.startsWith('m ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('s ')), isEmpty);
  });

  testWidgets('raw mode: hold emits no synthetic button press', (t) async {
    final e = _FakeEngine(raw: true);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await t.pump(const Duration(milliseconds: 600));
    await move(t, 1, const Offset(230, 330));
    await t.pump(const Duration(milliseconds: 32));
    await up(t, 1, const Offset(230, 330));

    expect(e.sent.where((l) => l.startsWith('b ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('c ')), isEmpty);
    expect(e.sent.last, 't 0');
  });

  testWidgets('three-finger quick tap sends middle click', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(220, 300));
    await down(t, 3, const Offset(240, 300));
    await t.pump(const Duration(milliseconds: 100));
    await up(t, 1, const Offset(200, 300));
    await up(t, 2, const Offset(220, 300));
    await up(t, 3, const Offset(240, 300));

    expect(e.sent.where((l) => l.startsWith('c ')), contains('c 2'));
    expect(e.sent.where((l) => l.startsWith('m ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('s ')), isEmpty);
  });

  testWidgets('three-finger swipe up sends task-view chord',
      (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 400));
    await down(t, 2, const Offset(220, 400));
    await down(t, 3, const Offset(240, 400));
    // Move all three fingers up by 40px in two rounds: centroid travels 80px.
    for (final y in <double>[360, 320]) {
      await move(t, 1, Offset(200, y));
      await move(t, 2, Offset(220, y));
      await move(t, 3, Offset(240, y));
    }
    await up(t, 1, const Offset(200, 320));
    await up(t, 2, const Offset(220, 320));
    await up(t, 3, const Offset(240, 320));

    final chords = e.sent.where((l) => l.startsWith('ch ')).toList();
    expect(chords, ['ch 125,15']);
  });

  testWidgets(
      'three-finger swipe works even when a finger lands/lifts late',
      (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 400));
    await down(t, 2, const Offset(220, 400));
    // Second finger first, then the third joins already mid-motion.
    await move(t, 1, const Offset(200, 360));
    await move(t, 2, const Offset(220, 360));
    await down(t, 3, const Offset(240, 360));
    // All three move up; the third finger lifts before the swipe ends but
    // the gesture vector keeps accumulating.
    for (final y in <double>[330, 300, 270]) {
      if (y == 270) await up(t, 3, const Offset(240, 270));
      await move(t, 1, Offset(200, y));
      await move(t, 2, Offset(220, y));
    }
    await up(t, 1, const Offset(200, 270));
    await up(t, 2, const Offset(220, 270));

    expect(e.sent.where((l) => l.startsWith('ch ')), contains('ch 125,15'));
    expect(e.sent.where((l) => l.startsWith('m ')).any((l) => l != 'm 0.00 0.00'),
        isFalse);
  });

  testWidgets('four-finger quick tap does nothing', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(220, 300));
    await down(t, 3, const Offset(240, 300));
    await down(t, 4, const Offset(260, 300));
    await t.pump(const Duration(milliseconds: 100));
    for (var i = 1; i <= 4; i++) {
      await up(t, i, Offset(180 + i * 20, 300));
    }

    expect(e.sent.where((l) => l.startsWith('c ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('b ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('k ')), isEmpty);
  });

  testWidgets('five-finger palm is ignored', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(210, 300));
    await down(t, 3, const Offset(220, 300));
    await down(t, 4, const Offset(230, 300));
    await down(t, 5, const Offset(240, 300));
    await t.pump(const Duration(milliseconds: 100));
    for (var i = 1; i <= 5; i++) {
      await up(t, i, Offset(190 + i * 10, 300));
    }

    expect(e.sent.where((l) => l.startsWith('c ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('b ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('k ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('s ')), isEmpty);
    expect(e.sent.where((l) => l.startsWith('m ')), isEmpty);
  });

  testWidgets('double-tap-and-hold starts a drag-lock', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: TouchpadSurface(engine: e))));

    await down(t, 1, const Offset(200, 300));
    await t.pump(const Duration(milliseconds: 50));
    await up(t, 1, const Offset(200, 300));

    // Second fast tap, held still past the drag-lock delay.
    await down(t, 2, const Offset(205, 302));
    await t.pump(const Duration(milliseconds: 300));
    expect(e.sent.where((l) => l.startsWith('b ')), contains('b 1 1'));

    await move(t, 2, const Offset(220, 320));
    await t.pump(const Duration(milliseconds: 32));
    await up(t, 2, const Offset(220, 320));
    expect(e.sent.where((l) => l.startsWith('b ')), contains('b 1 0'));
  });

  testWidgets('natural scroll off inverts the scroll Y axis', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TouchpadSurface(
      engine: e,
      settings: const TouchpadSettings(naturalScroll: false),
    ))));

    await down(t, 1, const Offset(200, 300));
    await down(t, 2, const Offset(220, 300));
    await move(t, 1, const Offset(200, 330));
    await move(t, 2, const Offset(220, 330));
    await t.pump(const Duration(milliseconds: 32));
    await up(t, 1, const Offset(200, 330));
    await up(t, 2, const Offset(220, 330));

    expect(e.sent.where((l) => l.startsWith('s 0.00 -30.00')), isNotEmpty);
  });

  testWidgets('cursor sensitivity scales motion deltas', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TouchpadSurface(
      engine: e,
      settings: const TouchpadSettings(cursorSensitivity: 4.0),
    ))));

    await down(t, 1, const Offset(200, 300));
    await move(t, 1, const Offset(220, 315));
    await t.pump(const Duration(milliseconds: 32));
    await up(t, 1, const Offset(220, 315));

    expect(e.sent.where((l) => l.startsWith('m 80.00 60.00')), isNotEmpty);
  });
}