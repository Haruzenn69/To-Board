import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'src/host_scanner.dart';
import 'src/keyboard_surface.dart';
import 'src/settings_store.dart';
import 'src/touchpad_engine.dart';
import 'src/touchpad_settings.dart';
import 'src/touchpad_surface.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const TouchpadApp());
}

class TouchpadApp extends StatelessWidget {
  const TouchpadApp({super.key});

  static final _defaultDarkColorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF877AA9),
    brightness: Brightness.dark,
  );

  /// dynamic_color 2.1.0 hands back a `material_ui` [mui.ColorScheme]; map it
  /// onto Flutter's [ColorScheme] so ThemeData and widgets can consume it.
  static ColorScheme _toFlutterScheme(mui.ColorScheme s) => ColorScheme(
        brightness: s.brightness,
        primary: s.primary,
        onPrimary: s.onPrimary,
        primaryContainer: s.primaryContainer,
        onPrimaryContainer: s.onPrimaryContainer,
        primaryFixed: s.primaryFixed,
        primaryFixedDim: s.primaryFixedDim,
        onPrimaryFixed: s.onPrimaryFixed,
        onPrimaryFixedVariant: s.onPrimaryFixedVariant,
        secondary: s.secondary,
        onSecondary: s.onSecondary,
        secondaryContainer: s.secondaryContainer,
        onSecondaryContainer: s.onSecondaryContainer,
        secondaryFixed: s.secondaryFixed,
        secondaryFixedDim: s.secondaryFixedDim,
        onSecondaryFixed: s.onSecondaryFixed,
        onSecondaryFixedVariant: s.onSecondaryFixedVariant,
        tertiary: s.tertiary,
        onTertiary: s.onTertiary,
        tertiaryContainer: s.tertiaryContainer,
        onTertiaryContainer: s.onTertiaryContainer,
        tertiaryFixed: s.tertiaryFixed,
        tertiaryFixedDim: s.tertiaryFixedDim,
        onTertiaryFixed: s.onTertiaryFixed,
        onTertiaryFixedVariant: s.onTertiaryFixedVariant,
        error: s.error,
        onError: s.onError,
        errorContainer: s.errorContainer,
        onErrorContainer: s.onErrorContainer,
        surface: s.surface,
        onSurface: s.onSurface,
        surfaceDim: s.surfaceDim,
        surfaceBright: s.surfaceBright,
        surfaceContainerLowest: s.surfaceContainerLowest,
        surfaceContainerLow: s.surfaceContainerLow,
        surfaceContainer: s.surfaceContainer,
        surfaceContainerHigh: s.surfaceContainerHigh,
        surfaceContainerHighest: s.surfaceContainerHighest,
        onSurfaceVariant: s.onSurfaceVariant,
        outline: s.outline,
        outlineVariant: s.outlineVariant,
        shadow: s.shadow,
        scrim: s.scrim,
        inverseSurface: s.inverseSurface,
        onInverseSurface: s.onInverseSurface,
        inversePrimary: s.inversePrimary,
        surfaceTint: s.surfaceTint,
      );

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (mui.ColorScheme? lightDynamic, mui.ColorScheme? darkDynamic) {
        final ColorScheme darkScheme = darkDynamic == null
            ? _defaultDarkColorScheme
            : _toFlutterScheme(darkDynamic);

        return MaterialApp(
          title: 'Touchpad',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: darkScheme,
            scaffoldBackgroundColor: darkScheme.surface,
            useMaterial3: true,
          ),
          home: const TouchpadHome(),
        ) as Widget;
      },
    );
  }
}

class TouchpadHome extends StatefulWidget {
  const TouchpadHome({super.key});

  @override
  State<TouchpadHome> createState() => _TouchpadHomeState();
}

class _TouchpadHomeState extends State<TouchpadHome> {
  late final TouchpadEngine _engine;

  final bool _isAndroid = Platform.isAndroid;

  EngineState _state = const EngineState(EnginePhase.starting);

  bool _keyboardMode = false;

  TouchpadSettings _settings = const TouchpadSettings();

  @override
  void initState() {
    super.initState();
    // Phone talks to the daemon on the laptop. Default: localhost over
    // `adb reverse tcp:4321 tcp:4321`. If a serverHost was saved (LAN/hotspot
    // mode) the phone connects directly to the laptop's LAN address instead.
    _engine = TouchpadEngine(
      host: _isAndroid ? '127.0.0.1' : null,
      port: _isAndroid ? 4321 : null,
    );
    _engine.states.listen(_onState);
    _restoreSettingsAndConnect();
  }

  Future<void> _restoreSettingsAndConnect() async {
    final saved = await SettingsStore.load();
    if (!mounted) return;
    setState(() => _settings = saved);
    if (_isAndroid && saved.serverHost.isNotEmpty) {
      _engine.host = saved.serverHost;
    }
    await _engine.start();
  }

  void _onState(EngineState s) {
    if (mounted) setState(() => _state = s);
  }

  Future<void> _openSettings() async {
    final cs = Theme.of(context).colorScheme;
    final updated = await showModalBottomSheet<TouchpadSettings>(
      context: context,
      backgroundColor: cs.surfaceContainerLow,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _SettingsSheet(initial: _settings),
    );
    if (updated == null || !mounted) return;
    final hostChanged = updated.serverHost != _settings.serverHost;
    setState(() {
      _settings = updated;
      if (_isAndroid) {
        _engine.host = updated.serverHost.isEmpty
            ? '127.0.0.1'
            : updated.serverHost;
      }
    });
    SettingsStore.save(updated);
    if (hostChanged) await _engine.restart();
  }

  @override
  void dispose() {
    _engine.stop();
    _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (dotColor, label) = switch (_state.phase) {
      EnginePhase.ready => (const Color(0xFF00E676), 'Connected · ${_state.backend ?? ''}'),
      EnginePhase.starting => (const Color(0xFFFFB74D), 'Connecting…'),
      EnginePhase.lost => (const Color(0xFFFF5252), 'Disconnected'),
    };

    return Scaffold(
      backgroundColor: cs.surface,
      body: Column(
        children: [
          // Expressive top status & controls bar
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, top: 8, bottom: 0),
              child: Row(
                children: [
                  // Material 3 Expressive Status Pill
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: dotColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: dotColor.withValues(alpha: 0.28),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: dotColor.withValues(alpha: 0.6),
                                blurRadius: 6,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                            color: dotColor == const Color(0xFF00E676)
                                ? cs.primary
                                : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (_state.phase == EnginePhase.lost && _isAndroid) ...[
                    FilledButton.tonal(
                      onPressed: () => _engine.restart(),
                      style: FilledButton.styleFrom(
                        backgroundColor: cs.errorContainer,
                        foregroundColor: cs.onErrorContainer,
                        side: BorderSide(color: cs.error.withValues(alpha: 0.4), width: 1.2),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        minimumSize: const Size(0, 36),
                        shape: const StadiumBorder(),
                      ),
                      child: const Text(
                        'Retry',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Touchpad gesture settings
                  IconButton(
                    tooltip: 'Touchpad settings',
                    onPressed: _openSettings,
                    icon: Icon(
                      Icons.tune_rounded,
                      size: 18,
                      color: cs.onSurfaceVariant,
                    ),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Material 3 Expressive Mode Switch Button
                  FilledButton.tonalIcon(
                    key: const Key('mode-toggle'),
                    onPressed: () => setState(() => _keyboardMode = !_keyboardMode),
                    icon: Icon(
                      _keyboardMode ? Icons.touch_app_rounded : Icons.keyboard_rounded,
                      size: 17,
                    ),
                    label: Text(
                      _keyboardMode ? 'Touchpad' : 'Keyboard',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.secondaryContainer,
                      foregroundColor: cs.onSecondaryContainer,
                      side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6), width: 1.2),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      minimumSize: const Size(0, 36),
                      shape: const StadiumBorder(),
                      elevation: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Active surface: either the touchpad or the virtual keyboard.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: _keyboardMode
                  ? KeyboardSurface(
                      engine: _engine,
                      onSwitch: () => setState(() => _keyboardMode = false),
                    )
                  : TouchpadSurface(engine: _engine, settings: _settings),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom-sheet editor for gesture settings. Edits mutate a local copy and
/// the whole sheet pops with the resulting [TouchpadSettings].
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial});

  final TouchpadSettings initial;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late TouchpadSettings _s = widget.initial;

  void _done() => Navigator.of(context).pop(_s);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'Touchpad settings',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  TextButton(onPressed: _done, child: const Text('Done')),
                ],
              ),
              _Slider('Cursor sensitivity', _s.cursorSensitivity, 0.5, 6.0,
                  0.1, '%.1fx',
                  (v) => setState(() => _s = _s.copyWith(cursorSensitivity: v))),
              _Slider('Scroll speed', _s.scrollScale, 0.25, 3.0, 0.25, '%.2fx',
                  (v) => setState(() => _s = _s.copyWith(scrollScale: v))),
              _Switch('Natural scroll', _s.naturalScroll, 'Content follows the '
                  'fingers (finger down scrolls down)',
                  (v) => setState(() => _s = _s.copyWith(naturalScroll: v))),
              _Switch('3-finger gestures', _s.multiFingerGestures,
                  'Tap = middle click · swipe = task view / app switch',
                  (v) =>
                      setState(() => _s = _s.copyWith(multiFingerGestures: v))),
              _Switch('Double-tap drag', _s.dragLock,
                  'Double-tap and hold to drag',
                  (v) => setState(() => _s = _s.copyWith(dragLock: v))),
              const SizedBox(height: 8),
              _HostField(
                initial: _s.serverHost,
                onChanged: (v) => setState(() => _s = _s.copyWith(serverHost: v)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HostField extends StatefulWidget {
  const _HostField({required this.initial, required this.onChanged});

  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_HostField> createState() => _HostFieldState();
}

class _HostFieldState extends State<_HostField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  bool _scanning = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final t0 = DateTime.now();
    final hits = await scanForDaemon();
    if (!mounted) return;
    setState(() => _scanning = false);
    final elapsed = DateTime.now().difference(t0).inSeconds;
    if (hits.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No laptop found (scanned '
              '${elapsed}s). Is touchpad-helper running with --host 0.0.0.0 '
              'and port 4321 open in Windows Firewall?'),
        ),
      );
      return;
    }
    if (hits.length == 1) {
      _apply(hits.first);
      return;
    }
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Found laptops', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (final h in hits)
              ListTile(
                title: Text(h),
                onTap: () => Navigator.of(ctx).pop(h),
              ),
          ],
        ),
      ),
    );
    if (pick != null) _apply(pick);
  }

  void _apply(String host) {
    _c.text = host;
    widget.onChanged(host);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Daemon (laptop IP)',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _c,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Blank = adb reverse (USB)',
                  border: const OutlineInputBorder(),
                ),
                onChanged: widget.onChanged,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              child: OutlinedButton.icon(
                onPressed: _scanning ? null : _scan,
                icon: _scanning
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.primary),
                      )
                    : const Icon(Icons.search, size: 16),
                label: const Text('Scan'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Connect via hotspot/LAN. Empty uses a USB-connected phone via adb reverse.',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider(this.label, this.value, this.min, this.max, this.divisions,
      this.format, this.onChanged);

  final String label;
  final double value;
  final double min;
  final double max;
  final double divisions;
  final String format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: Text(label,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / divisions).round(),
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            format.replaceFirst('%', value.toStringAsFixed(2)),
            textAlign: TextAlign.right,
            style: TextStyle(
                fontSize: 12, color: cs.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch(this.label, this.value, this.subtitle, this.onChanged);

  final String label;
  final bool value;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      value: value,
      onChanged: onChanged,
    );
  }
}