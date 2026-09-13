import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:touchpad/src/touchpad_engine.dart' as tp;

/// Regression: the daemon announces `state ready backend=uinput`; the engine
/// must set wantsRawTouch ONLY for the real backend name (after the `=`) and
/// not for the whole "backend=uinput" token.
void main() {
  Future<tp.TouchpadEngine> connectAndAnnounce(
    String stateLine,
    Completer<tp.EngineState> saw,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      s.write('$stateLine\n');
    });
    final e = tp.TouchpadEngine(host: server.address.address, port: server.port);
    e.states.listen((s) {
      if (s.phase == tp.EnginePhase.ready && !saw.isCompleted) {
        saw.complete(s);
      }
    }, onError: (_) {});
    // Do not await start(): its socket loop only returns when the peer closes.
    unawaited(e.start());
    return e;
  }

  test('uinput backend enables raw touch mode', () async {
    final saw = Completer<tp.EngineState>();
    final e = await connectAndAnnounce('state ready backend=uinput', saw);

    final s = await saw.future.timeout(const Duration(seconds: 5));
    expect(s.phase, tp.EnginePhase.ready);
    expect(s.backend, 'uinput');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(e.wantsRawTouch, isTrue);

    await e.stop();
  });

  test('x11 backend stays in synthetic mode', () async {
    final saw = Completer<tp.EngineState>();
    final e = await connectAndAnnounce('state ready backend=x11', saw);

    final s = await saw.future.timeout(const Duration(seconds: 5));
    expect(s.backend, 'x11');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(e.wantsRawTouch, isFalse);

    await e.stop();
  });
}