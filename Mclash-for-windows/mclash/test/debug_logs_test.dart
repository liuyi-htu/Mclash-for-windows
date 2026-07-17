import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mclash/windows_proxy_platform_service.dart';

void main() {
  late Directory temporaryDirectory;
  late WindowsProxyPlatformService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'mclash-debug-logs-',
    );
    service = WindowsProxyPlatformService(dataDir: temporaryDirectory.path);
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('lists and reads each supported log independently', () async {
    final logs = await service.getDebugLogs();
    expect(logs.map((log) => log.id),
        <String>['service.log', 'mihomo.log', 'sing-box.log']);
    expect(logs.first.displayName, 'Mclash.log');

    final directory = Directory('${temporaryDirectory.path}\\logs');
    await directory.create(recursive: true);
    await File('${directory.path}\\service.log').writeAsString('service entry');
    await File('${directory.path}\\mihomo.log').writeAsString('mihomo entry');

    expect(await service.getDebugLogContent('service.log'), 'service entry');
    expect(await service.getDebugLogContent('mihomo.log'), 'mihomo entry');
  });

  test(
    'rejects unknown log names and clears logs plus startup error',
    () async {
      final directory = Directory('${temporaryDirectory.path}\\logs');
      await directory.create(recursive: true);
      await File(
        '${directory.path}\\service.log',
      ).writeAsString('service entry');
      await File('${directory.path}\\mihomo.log').writeAsString('mihomo entry');
      await File('${temporaryDirectory.path}\\state.json').writeAsString(
        jsonEncode(<String, dynamic>{'message': 'startup failed'}),
      );

      await expectLater(
        service.getDebugLogContent('..\\config.yaml'),
        throwsArgumentError,
      );
      await service.clearDebugLogs();

      expect(
        await File('${directory.path}\\service.log').readAsString(),
        isEmpty,
      );
      expect(
        await File('${directory.path}\\mihomo.log').readAsString(),
        isEmpty,
      );
      final state = jsonDecode(
        await File(
          '${temporaryDirectory.path}\\state.json',
        ).readAsString(),
      ) as Map<String, dynamic>;
      expect(state['message'], isEmpty);
    },
  );
}
