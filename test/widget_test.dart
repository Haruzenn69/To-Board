import 'package:flutter_test/flutter_test.dart' hide EnginePhase;

import 'package:touchpad/src/touchpad_engine.dart';

void main() {
  test('EngineState exposes backend and phase', () {
    final s = EngineState(EnginePhase.ready, backend: 'uinput');
    expect(s.phase, EnginePhase.ready);
    expect(s.backend, 'uinput');
  });

  test('EngineState default has no backend', () {
    final s = const EngineState(EnginePhase.starting);
    expect(s.phase, EnginePhase.starting);
    expect(s.backend, isNull);
  });
}