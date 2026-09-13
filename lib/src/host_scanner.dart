import 'dart:async';
import 'dart:io';

/// LAN/hotspot discovery: find the laptop running `touchpad-helper --listen
/// 4321 --host 0.0.0.0` without knowing its address. The phone (or the hotspot
/// phone this app may run on) derives candidate subnets from its own local
/// IPs plus the well-known Android tethering ranges, then probes each host on
/// the daemon port. Closed ports refuse fast, so the scan stays quick.
Future<List<String>> scanForDaemon({
  int port = 4321,
  Duration probeTimeout = const Duration(milliseconds: 180),
  Set<String>? extraSubnets,
}) async {
  final subnets = <String>{...?extraSubnets};

  try {
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final i in interfaces) {
      for (final addr in i.addresses) {
        if (addr.isLoopback) continue;
        final ip = addr.address;
        if (_isPrivateV4(ip)) {
          subnets.add('${_prefix24(ip)}.0');
        }
      }
    }
  } catch (_) {}

  // Common Android tethering defaults if no local candidate was visible.
  if (subnets.isEmpty) {
    subnets.addAll(const <String>[
      '192.168.43.0',
      '192.168.44.0',
      '192.168.49.0',
      '192.168.52.0',
    ]);
  }

  final hosts = <String>[];
  for (final subnet in subnets) {
    final prefix = subnet.substring(0, subnet.lastIndexOf('.'));
    for (var host = 1; host <= 254; host++) {
      hosts.add('$prefix.$host');
    }
  }

  final hits = <String>{};
  await _probeAll(hosts, port, probeTimeout, hits);
  return hits.toList()..sort();
}

bool _isPrivateV4(String ip) {
  if (ip.startsWith('192.168.')) return true;
  if (ip.startsWith('10.')) return true;
  if (ip.startsWith('172.')) {
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final b = int.tryParse(parts[1]);
    return b != null && b >= 16 && b <= 31;
  }
  return false;
}

String _prefix24(String ip) {
  final parts = ip.split('.');
  return '${parts[0]}.${parts[1]}.${parts[2]}';
}

Future<void> _probeAll(List<String> hosts, int port, Duration timeout,
    Set<String> hits) async {
  const concurrency = 40;
  final queue = List<String>.from(hosts);
  final workers = <Future<void>>[];

  Future<void> worker() async {
    while (true) {
      final String? next;
      if (queue.isNotEmpty) {
        next = queue.removeLast();
      } else {
        next = null;
      }
      if (next == null) return;
      try {
        final s = await Socket.connect(next, port, timeout: timeout);
        s.destroy();
        hits.add(next);
      } catch (_) {}
    }
  }

  final n = concurrency < queue.length ? concurrency : queue.length;
  for (var i = 0; i < n; i++) {
    workers.add(worker());
  }
  await Future.wait(workers);
}