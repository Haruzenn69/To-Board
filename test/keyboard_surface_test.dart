import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:touchpad/src/touchpad_engine.dart';
import 'package:touchpad/src/keyboard_surface.dart';

class _FakeEngine extends TouchpadEngine {
  @override
  bool get wantsRawTouch => false;
  final List<String> sent = <String>[];
  @override
  void sendLine(String line) => sent.add(line);
}

void main() {
  Future<void> down(WidgetTester t, int id, Offset pos) async {
    t.binding.handlePointerEvent(
        PointerDownEvent(pointer: id, position: pos));
  }

  Future<void> up(WidgetTester t, int id, Offset pos) async {
    t.binding.handlePointerEvent(
        PointerUpEvent(pointer: id, position: pos));
  }

  Future<void> cancel(WidgetTester t, int id, Offset pos) async {
    t.binding.handlePointerEvent(
        PointerCancelEvent(pointer: id, position: pos));
  }

  testWidgets('mount creates keyboard device, dispose destroys it',
      (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyboardSurface(engine: e))));
    expect(e.sent, contains('kb 1'));

    await t.pumpWidget(MaterialApp(home: const Scaffold()));
    expect(e.sent.last, 'kb 0');
  });

  testWidgets('pressing a key sends down then up', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyboardSurface(engine: e))));
    e.sent.clear();

    final a = find.text('A');
    expect(a, findsOneWidget);
    await down(t, 1, t.getCenter(a));
    await up(t, 1, t.getCenter(a));
    await t.pump();

    expect(e.sent, contains('k 30 1'));
    expect(e.sent, contains('k 30 0'));
  });

  testWidgets('hold keeps key down until release', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyboardSurface(engine: e))));
    e.sent.clear();

    final space = find.text('Space');
    await down(t, 1, t.getCenter(space));
    await t.pump();
    expect(e.sent, contains('k 57 1'));
    expect(e.sent, isNot(contains('k 57 0')));

    await up(t, 1, t.getCenter(space));
    await t.pump();
    expect(e.sent, contains('k 57 0'));
  });

  testWidgets('pointer cancel releases the key', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyboardSurface(engine: e))));
    e.sent.clear();

    final upKey = find.text('\u2191');
    expect(upKey, findsOneWidget);
    await down(t, 1, t.getCenter(upKey));
    await cancel(t, 1, t.getCenter(upKey));
    await t.pump();

    expect(e.sent, contains('k 103 1'));
    expect(e.sent, contains('k 103 0'));
  });

  testWidgets('nav cluster uses evdev codes', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyboardSurface(engine: e))));
    e.sent.clear();

    for (final (label, code) in [
      ('PgUp', 104),
      ('PgDn', 109),
      ('Home', 102),
      ('End', 107),
      ('Del', 111),
      ('PrtSc', 99),
    ]) {
      e.sent.clear();
      final key = find.text(label);
      expect(key, findsOneWidget, reason: label);
      await down(t, 1, t.getCenter(key));
      await up(t, 1, t.getCenter(key));
      await t.pump();
      expect(e.sent, contains('k $code 1'));
      expect(e.sent, contains('k $code 0'));
    }
  });

  testWidgets('unmounting releases any held keys before kb 0', (t) async {
    final e = _FakeEngine();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: KeyboardSurface(engine: e))));
    e.sent.clear();

    final shift = find.text('\u21E7');
    await down(t, 1, t.getCenter(shift.first));
    await t.pump();
    expect(e.sent, contains('k 42 1'));

    await t.pumpWidget(MaterialApp(home: const Scaffold()));
    expect(e.sent, contains('k 42 0'));
    expect(e.sent.last, 'kb 0');
  });

  testWidgets('Swch key invokes onSwitch without emitting a key event',
      (t) async {
    final e = _FakeEngine();
    bool switched = false;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: KeyboardSurface(
                engine: e, onSwitch: () => switched = true))));
    e.sent.clear();

    final swch = find.text('Swch');
    expect(swch, findsOneWidget);
    await down(t, 1, t.getCenter(swch));
    await up(t, 1, t.getCenter(swch));
    await t.pump();

    expect(switched, isTrue);
    expect(e.sent.where((s) => s.startsWith('k ')), isEmpty);
  });
}