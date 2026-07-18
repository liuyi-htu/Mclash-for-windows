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

  test(
    'uses the clean active profile and preserves custom tun settings',
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
      final runtime =
          loadYaml(
                await File(
                  '${temporaryDirectory.path}\\config.yaml',
                ).readAsString(),
              )
              as YamlMap;
      expect(runtime['tun']['enable'], isTrue);
      expect(runtime['tun']['stack'], 'system');
      expect(runtime['tun']['strict-route'], isTrue);
      expect(runtime['tun']['auto-route'], isTrue);
    },
  );

  test('creates and removes a managed sing-box TUN inbound', () async {
    final config = File('${temporaryDirectory.path}\\sing-box.json');
    await config.writeAsString('''
{"inbounds":[{"type":"mixed","listen_port":7890}],"outbounds":[{"type":"direct"}]}
''');
    await service.setCoreType(CoreType.singBox);
    await service.setNetworkMode(NetworkMode.tun);
    var decoded =
        jsonDecode(await config.readAsString()) as Map<String, dynamic>;
    expect(
      (decoded['inbounds'] as List).any(
        (entry) => entry is Map && entry['tag'] == 'mclash-tun',
      ),
      isTrue,
    );
    final ruleSets = (decoded['route'] as Map)['rule_set'] as List;
    expect(
      ruleSets.map((entry) => (entry as Map)['tag']),
      containsAll(<String>[
        'geoip-cn',
        'geosite-cn',
        'geosite-private',
        'geosite-category-ads-all',
        'geosite-geolocation-!cn',
      ]),
    );
    expect(
      ruleSets.every(
        (entry) =>
            entry is Map &&
            entry['type'] == 'local' &&
            entry['path'].toString().startsWith('rulesets/'),
      ),
      isTrue,
    );
    await service.setNetworkMode(NetworkMode.proxy);
    decoded = jsonDecode(await config.readAsString()) as Map<String, dynamic>;
    expect(
      (decoded['inbounds'] as List).any(
        (entry) => entry is Map && entry['tag'] == 'mclash-tun',
      ),
      isFalse,
    );
  });

  test('lists only profiles supported by the selected core', () async {
    final profiles = Directory('${temporaryDirectory.path}\\profiles');
    await profiles.create(recursive: true);
    await File(
      '${profiles.path}\\clash.yaml',
    ).writeAsString('mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n');
    await File(
      '${profiles.path}\\sing-box.json',
    ).writeAsString('{"inbounds":[],"outbounds":[{"type":"direct"}]}');
    await File('${temporaryDirectory.path}\\state.json').writeAsString(
      jsonEncode(<String, dynamic>{
        'profileNames': <String, String>{
          'clash.yaml': 'mihomo 配置',
          'sing-box.json': 'sing-box 配置',
        },
      }),
    );

    expect((await service.getConfigs()).map((item) => item.id), <String>[
      'clash.yaml',
    ]);

    await service.setCoreType(CoreType.singBox);
    expect((await service.getConfigs()).map((item) => item.id), <String>[
      'sing-box.json',
    ]);
  });
}
