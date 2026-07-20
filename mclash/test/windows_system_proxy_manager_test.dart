import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mclash/windows_system_proxy_manager.dart';

void main() {
  late Directory temporaryDirectory;
  late File backup;
  late List<List<String>> commands;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'mclash-system-proxy-',
    );
    backup = File('${temporaryDirectory.path}\\proxy-backup.json');
    commands = <List<String>>[];
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  ProcessResult result(int exitCode, [String stdout = '', String stderr = '']) =>
      ProcessResult(1, exitCode, stdout, stderr);

  test('backs up existing values once and restores them', () async {
    final original = <String, (String, String)>{
      'ProxyEnable': ('REG_DWORD', '0x1'),
      'ProxyServer': ('REG_SZ', 'proxy.example:8080'),
      'ProxyOverride': ('REG_SZ', '<local>;intranet.example'),
    };
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments,
    ) async {
      commands.add(List<String>.from(arguments));
      if (arguments.first == 'query') {
        final name = arguments.last;
        final value = original[name]!;
        return result(0, '    $name    ${value.$1}    ${value.$2}\r\n');
      }
      return result(0);
    }

    final manager = WindowsSystemProxyManager(
      backupPath: backup.path,
      processRunner: runner,
    );
    await manager.enable(port: 7890, bypass: '<local>;192.168.*');
    await manager.enable(port: 7891, bypass: '<local>;10.*');

    expect(commands.where((item) => item.first == 'query'), hasLength(3));
    expect(await backup.exists(), isTrue);
    await manager.restore();

    expect(await backup.exists(), isFalse);
    for (final entry in original.entries) {
      expect(
        commands,
        contains(
          equals(<String>[
            'add',
            WindowsSystemProxyManager.internetSettingsKey,
            '/v',
            entry.key,
            '/t',
            entry.value.$1,
            '/d',
            entry.value.$2,
            '/f',
          ]),
        ),
      );
    }
  });

  test('removes registry values that did not originally exist', () async {
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments,
    ) async {
      commands.add(List<String>.from(arguments));
      if (arguments.first == 'query') return result(1);
      return result(0);
    }

    final manager = WindowsSystemProxyManager(
      backupPath: backup.path,
      processRunner: runner,
    );
    await manager.enable(port: 7890, bypass: '<local>');
    expect(jsonDecode(await backup.readAsString()), <String, dynamic>{
      'ProxyEnable': null,
      'ProxyServer': null,
      'ProxyOverride': null,
    });

    await manager.restore();
    expect(commands.where((item) => item.first == 'delete'), hasLength(3));
  });

  test('does not change the registry when no backup exists', () async {
    Future<ProcessResult> runner(
      String executable,
      List<String> arguments,
    ) async {
      commands.add(List<String>.from(arguments));
      return result(0);
    }

    final manager = WindowsSystemProxyManager(
      backupPath: backup.path,
      processRunner: runner,
    );
    await manager.restore();

    expect(commands, isEmpty);
  });
}
