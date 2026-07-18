import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mclash/models.dart';
import 'package:mclash/windows_proxy_platform_service.dart';

void main() {
  late Directory dataDir;
  late WindowsProxyPlatformService service;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('mclash-core-state-');
    await Directory(
      '${dataDir.path}${Platform.pathSeparator}profiles',
    ).create(recursive: true);
    service = WindowsProxyPlatformService(dataDir: dataDir.path);
  });

  tearDown(() async {
    await dataDir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> readState() async {
    final file = File('${dataDir.path}${Platform.pathSeparator}state.json');
    return Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
  }

  test('remembers the active profile for each core', () async {
    final separator = Platform.pathSeparator;
    await File(
      '${dataDir.path}${separator}profiles${separator}home.yaml',
    ).writeAsString('mixed-port: 7890\nproxies: []\n');
    await File(
      '${dataDir.path}${separator}profiles${separator}box.json',
    ).writeAsString('{"inbounds": []}\n');
    await File('${dataDir.path}${separator}state.json').writeAsString(
      jsonEncode(<String, dynamic>{
        'coreType': 'mihomo',
        'activeProfile': 'home.yaml',
        'profileNames': <String, dynamic>{
          'home.yaml': 'Home',
          'box.json': 'Box',
        },
      }),
    );

    await service.setCoreType(CoreType.singBox);
    var state = await readState();
    expect(state['activeMihomoProfile'], 'home.yaml');
    expect(state['activeProfile'], isNull);

    await service.selectConfig('box.json');
    await service.setCoreType(CoreType.mihomo);
    state = await readState();
    expect(state['activeProfile'], 'home.yaml');

    await service.setCoreType(CoreType.singBox);
    state = await readState();
    expect(state['activeProfile'], 'box.json');
  });

  test('changing only network mode keeps the current profile', () async {
    final separator = Platform.pathSeparator;
    await File(
      '${dataDir.path}${separator}profiles${separator}selected.yaml',
    ).writeAsString('mixed-port: 7890\nproxies: []\n');
    await File('${dataDir.path}${separator}state.json').writeAsString(
      jsonEncode(<String, dynamic>{
        'coreType': 'mihomo',
        'activeProfile': 'selected.yaml',
        'activeMihomoProfile': 'older.yaml',
      }),
    );

    await service.setCoreType(CoreType.mihomo);

    final state = await readState();
    expect(state['activeProfile'], 'selected.yaml');
    expect(state['activeMihomoProfile'], 'selected.yaml');
  });
}
