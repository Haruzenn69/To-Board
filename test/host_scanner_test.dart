import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:touchpad/src/host_scanner.dart';

void main() {
  test('scanForDaemon finds a listening socket on the subnet', () async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(() => server.close());
    server.listen((_) {}); // accept + hold the connection open

    final results = await scanForDaemon(
      port: server.port,
      probeTimeout: const Duration(milliseconds: 500),
      extraSubnets: const {'127.0.0.0'},
    );

    expect(results, contains('127.0.0.1'));
  });

  test('scanForDaemon ignores closed ports', () async {
    final results = await scanForDaemon(
      port: 9,
      probeTimeout: const Duration(milliseconds: 120),
      extraSubnets: const {'127.0.0.0'},
    );
    expect(results, isEmpty);
  });
}