import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum EnginePhase { starting, ready, lost }

class EngineState {
  final EnginePhase phase;
  final String? backend;
  final String? message;

  const EngineState(this.phase, {this.backend, this.message});
}

/// Abstraction over the two ways the app talks to the input daemon:
/// a local helper subprocess (desktop) or a TCP connection (phone / remote).
abstract class InputTransport {
  Stream<EngineState> get states;
  Future<void> start();
  Future<void> stop();
  void send(String line);
  void dispose();
}

// ---------------------------------------------------------------------------
// Local: spawns the native "touchpad-helper" binary and speaks over stdin.
// ---------------------------------------------------------------------------

class _LocalProcessTransport implements InputTransport {
  _LocalProcessTransport({this._helperPath});

  final String? _helperPath;
  final StreamController<EngineState> _states =
      StreamController<EngineState>.broadcast();
  Process? _proc;
  bool _running = false;

  @override
  Stream<EngineState> get states => _states.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _run();
  }

  @override
  Future<void> stop() async {
    _running = false;
    final p = _proc;
    _proc = null;
    if (p != null) {
      try {
        p.stdin.writeln('quit');
      } catch (_) {}
      p.kill();
      await p.exitCode;
    }
  }

  Future<void> _run() async {
    while (_running) {
      final path = await _resolveHelper();
      if (path == null) {
        _emit(EnginePhase.lost, message: 'helper not found');
        break;
      }
      Process? p;
      try {
        p = await Process.start(path, const []);
      } catch (e) {
        _emit(EnginePhase.lost, message: 'spawn failed: ${e.toString()}');
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      if (!_running) {
        p.kill();
        return;
      }
      _proc = p;
      _emit(EnginePhase.starting);
      p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine);
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (l) => debugPrint('[helper] $l'));
      final code = await p.exitCode;
      if (_proc == p) {
        _proc = null;
        _emit(EnginePhase.lost, message: 'exited ($code)');
      }
      if (_running) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<String?> _resolveHelper() async {
    if (_helperPath != null && await _executable(_helperPath)) {
      return _helperPath;
    }
    // Windows binaries use a .exe suffix; on POSIX keep the plain name.
    final exeSuffix = Platform.isWindows ? '.exe' : '';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$exeDir/touchpad-helper$exeSuffix',
      '$exeDir/lib/touchpad-helper$exeSuffix',
      '$cwd/native/touchpad-helper$exeSuffix',
      '$cwd/native/build/touchpad-helper$exeSuffix',
    ];
    for (final c in candidates) {
      if (await _executable(c)) return c;
    }
    return null;
  }

  static Future<bool> _executable(String path) async {
    final f = File(path);
    if (!await f.exists()) return false;
    // Windows has no `test -x`; any existing file may be spawned.
    if (Platform.isWindows) return true;
    return Process.run('test', ['-x', path]).then((r) => r.exitCode == 0);
  }

  void _onLine(String line) {
    if (line.startsWith('state ')) {
      final rest = line.substring(6);
      if (rest == 'connecting') {
        _emit(EnginePhase.starting);
      } else if (rest.startsWith('ready ')) {
        _emit(EnginePhase.ready, backend: _parseBackend(rest));
      } else if (rest.startsWith('lost ')) {
        _emit(EnginePhase.lost, message: rest.substring(5));
      }
    }
  }

  void _emit(EnginePhase phase, {String? backend, String? message}) {
    if (!_states.isClosed) {
      _states.add(EngineState(phase, backend: backend, message: message));
    }
  }

  @override
  void send(String line) {
    final p = _proc;
    if (p == null) return;
    try {
      p.stdin.writeln(line);
    } catch (_) {}
  }

  @override
  void dispose() {
    _running = false;
    _states.close();
  }
}

// ---------------------------------------------------------------------------
// Remote: TCP client to a daemon (desktop running `touchpad-helper --listen`).
// With USB: `adb reverse tcp:PORT tcp:PORT` then connect to 127.0.0.1:PORT.
// ---------------------------------------------------------------------------

class _SocketTransport implements InputTransport {
  _SocketTransport({required this.host, required this.port}) {
    assert(host.isNotEmpty);
    assert(port > 0 && port < 65536);
  }

  final String host;
  final int port;
  final StreamController<EngineState> _states =
      StreamController<EngineState>.broadcast();
  Socket? _socket;
  bool _running = false;

  @override
  Stream<EngineState> get states => _states.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _run();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _socket?.destroy();
    _socket = null;
  }

  Future<void> _run() async {
    while (_running) {
      Socket? sock;
      try {
        sock = await Socket.connect(host, port,
            timeout: const Duration(seconds: 4));
      } catch (_) {
        _emit(EnginePhase.lost, message: 'cannot reach $host:$port');
        if (_running) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        continue;
      }
      if (!_running) {
        sock.destroy();
        return;
      }
      _socket = sock;
      _emit(EnginePhase.starting);
      final sub = utf8.decoder
          .bind(sock)
          .transform(const LineSplitter())
          .listen(_onLine, onError: (Object e) {
        _emit(EnginePhase.lost, message: 'read error');
      });
      await sock.done.then((_) {}, onError: (_) {});
      await sub.cancel();
      if (_socket == sock) {
        _socket = null;
      }
      _emit(EnginePhase.lost, message: 'connection closed');
      if (_running) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

void _onLine(String line) {
    if (line.startsWith('state ')) {
      final rest = line.substring(6);
      if (rest == 'connecting') {
        _emit(EnginePhase.starting);
      } else if (rest.startsWith('ready ')) {
        _emit(EnginePhase.ready, backend: _parseBackend(rest));
      } else if (rest.startsWith('lost ')) {
        _emit(EnginePhase.lost, message: rest.substring(5));
      }
    }
  }

  void _emit(EnginePhase phase, {String? backend, String? message}) {
    if (!_states.isClosed) {
      _states.add(EngineState(phase, backend: backend, message: message));
    }
  }

  @override
  void send(String line) {
    final s = _socket;
    if (s == null) return;
    try {
      s.write(line);
      s.write('\n');
      s.flush();
    } catch (_) {}
  }

  @override
  void dispose() {
    _running = false;
    _states.close();
  }
}

// ---------------------------------------------------------------------------
// Engine facade: pick a transport and expose the touchpad protocol.
// ---------------------------------------------------------------------------

/// "ready backend=uinput" -> "uinput"
String? _parseBackend(String rest) {
  final payload = rest.substring('ready '.length).trim();
  return payload.startsWith('backend=')
      ? payload.substring('backend='.length)
      : payload;
}

class TouchpadEngine {
  TouchpadEngine({this._helperPath, this.host, this.port});

  final String? _helperPath;

  /// When set (and [port] is set), talk to a remote daemon over TCP.
  String? host;
  int? port;

  final StreamController<EngineState> _states =
      StreamController<EngineState>.broadcast();
  InputTransport? _transport;
  StreamSubscription<EngineState>? _sub;
  EnginePhase _phase = EnginePhase.starting;
  bool _rawTouchpad = false;

  bool get remote => host != null && port != null;
  EnginePhase get phase => _phase;
  bool get isReady => _phase == EnginePhase.ready;

  /// True once the daemon announced a uinput touchpad: the app then streams
  /// raw touch frames instead of synthetic gesture commands.
  bool get wantsRawTouch => _rawTouchpad;
  Stream<EngineState> get states => _states.stream;

  Future<void> start() async {
    final t = remote
        ? _SocketTransport(host: host!, port: port!)
        : _LocalProcessTransport(helperPath: _helperPath);
    _transport = t;
    _sub = t.states.listen(_onState);
    await t.start();
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> stop() async {
    final t = _transport;
    _transport = null;
    await _sub?.cancel();
    _sub = null;
    if (t != null) {
      await t.stop();
    }
    _phase = EnginePhase.starting;
  }

  void _onState(EngineState s) {
    _phase = s.phase;
    if (s.phase == EnginePhase.ready) {
      _rawTouchpad = s.backend == 'uinput';
    }
    if (!_states.isClosed) {
      _states.add(s);
    }
  }

  void sendLine(String line) => _transport?.send(line);

  String _f(double v) => v.toStringAsFixed(2);

  void moveBy(double dx, double dy) => sendLine('m ${_f(dx)} ${_f(dy)}');

  void button(int btn, bool down) => sendLine('b $btn ${down ? 1 : 0}');

  void click(int btn) {
    button(btn, true);
    button(btn, false);
  }

  /// Single-command click (press+release inside the daemon). Prefer this over
  /// [click]: it survives lossy transports that drop half of a two-packet pair.
  void clickTap(int btn) => sendLine('c $btn');

  /// Smooth scroll delta, in logical pixels on the pad surface.
  void scrollSmooth(double dx, double dy) =>
      sendLine('s ${_f(dx)} ${_f(dy)}');

  void scrollDiscrete(int dx, int dy) => sendLine('d $dx $dy');

  void scrollStop() => sendLine('q');

  void key(int code, bool down) => sendLine('k $code ${down ? 1 : 0}');

  /// Tap a key chord (e.g. Alt+Tab) as a single atomic daemon-side burst:
  /// presses and releases are bundled in one 'ch' line so a lost packet can
  /// never leave a modifier stuck. Used by multi-finger swipe gestures.
  void chord(Iterable<int> codes) {
    sendLine('ch ${codes.join(',')}');
  }

  /// Create (true) or destroy (false) the separate virtual keyboard device.
  void keyboardMode(bool on) => sendLine('kb ${on ? 1 : 0}');

  void dispose() {
    _states.close();
  }
}

/// Modifier keys sent over the protocol (mapped to evdev codes natively).
const kModifierCtrl = 1;
const kModifierShift = 2;
const kModifierAlt = 3;
const kModifierSuper = 4;