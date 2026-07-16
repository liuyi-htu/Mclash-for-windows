import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mclash/models.dart';
import 'package:mclash/windows_proxy_platform_service.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory temporaryDirectory;
  late WindowsProxyPlatformService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'mclash-network-mode-',
    );
    service = WindowsProxyPlatformService(dataDir: temporaryDirectory.path);
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('defaults to proxy mode and switches both directions', () async {
    final config = File('${temporaryDirectory.path}\\config.yaml');
    await config.writeAsString('mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n');

    expect(await service.getNetworkMode(), NetworkMode.proxy);

    await service.setNetworkMode(NetworkMode.tun);
    expect(await service.getNetworkMode(), NetworkMode.tun);
    var yaml = loadYaml(await config.readAsString()) as YamlMap;
    expect(yaml['tun']['enable'], isTrue);
    expect(yaml['tun']['stack'], 'mixed');
    expect(yaml['tun']['auto-route'], isTrue);
    expect(yaml['tun']['auto-detect-interface'], isTrue);

    await service.setNetworkMode(NetworkMode.proxy);
    expect(await service.getNetworkMode(), NetworkMode.proxy);
    yaml = loadYaml(await config.readAsString()) as YamlMap;
    expect(yaml['tun']['enable'], isFalse);
  });

  test('uses the clean active profile and preserves custom tun settings',
      () async {
    final profiles = Directory('${temporaryDirectory.path}\\profiles');
    await profiles.create(recursive: true);
    final profile = File('${profiles.path}\\work.yaml');
    const source = '''
mixed-port: 7890
tun:
  enable: false
  stack: system
  strict-route: true
rules:
  - MATCH,DIRECT
''';
    await profile.writeAsString(source);
    await File('${temporaryDirectory.path}\\state.json').writeAsString(
      jsonEncode(<String, dynamic>{'activeProfile': 'work.yaml'}),
    );

    await service.setNetworkMode(NetworkMode.tun);

    expect(await profile.readAsString(), source);
    final runtime = loadYaml(
      await File('${temporaryDirectory.path}\\config.yaml').readAsString(),
    ) as YamlMap;
    expect(runtime['tun']['enable'], isTrue);
    expect(runtime['tun']['stack'], 'system');
    expect(runtime['tun']['strict-route'], isTrue);
    expect(runtime['tun']['auto-route'], isTrue);
  });
}
