import 'dart:convert';
import 'dart:io';

typedef RegistryProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class WindowsSystemProxyManager {
  WindowsSystemProxyManager({
    required this.backupPath,
    RegistryProcessRunner? processRunner,
  }) : _processRunner = processRunner ?? _defaultProcessRunner;

  static const internetSettingsKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const managedValues = <String>[
    'ProxyEnable',
    'ProxyServer',
    'ProxyOverride',
  ];

  final String backupPath;
  final RegistryProcessRunner _processRunner;

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments, runInShell: false);

  Future<void> enable({required int port, required String bypass}) async {
    await _backupIfNeeded();
    await _writeValue('ProxyServer', 'REG_SZ', '127.0.0.1:$port');
    await _writeValue('ProxyOverride', 'REG_SZ', bypass);
    await _writeValue('ProxyEnable', 'REG_DWORD', '1');
  }

  Future<void> restore() async {
    final backup = File(backupPath);
    if (!await backup.exists()) {
      // A repeated stop/sync must not disable a proxy that was already restored
      // or that belongs to another application.
      return;
    }

    final decoded = jsonDecode(await backup.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid system proxy backup.');
    }
    for (final name in managedValues) {
      final saved = decoded[name];
      if (saved == null) {
        await _deleteValue(name);
        continue;
      }
      if (saved is! Map || saved['type'] is! String || saved['data'] is! String) {
        throw const FormatException('Invalid system proxy backup value.');
      }
      await _writeValue(
        name,
        saved['type'] as String,
        saved['data'] as String,
      );
    }
    await backup.delete();
  }

  Future<void> _backupIfNeeded() async {
    final backup = File(backupPath);
    if (await backup.exists()) {
      // Do not replace the real pre-Mclash settings when start/sync is called
      // more than once while Mclash already owns the system proxy.
      jsonDecode(await backup.readAsString());
      return;
    }

    final values = <String, dynamic>{};
    for (final name in managedValues) {
      final value = await _readValue(name);
      values[name] = value?.toJson();
    }
    await backup.parent.create(recursive: true);
    final temporary = File('${backup.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(values),
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    await temporary.rename(backup.path);
  }

  Future<_RegistryValue?> _readValue(String name) async {
    final result = await _processRunner('reg.exe', <String>[
      'query',
      internetSettingsKey,
      '/v',
      name,
    ]);
    if (result.exitCode != 0) return null;
    final pattern = RegExp(
      '^\\s+${RegExp.escape(name)}\\s+(REG_[A-Z0-9_]+)\\s*(.*)\\s*\$',
      caseSensitive: false,
      multiLine: true,
    );
    final match = pattern.firstMatch(result.stdout.toString());
    if (match == null) {
      throw StateError('Unable to parse Windows proxy setting $name.');
    }
    return _RegistryValue(
      type: match.group(1)!.toUpperCase(),
      data: match.group(2)!.trimRight(),
    );
  }

  Future<void> _writeValue(String name, String type, String data) async {
    final result = await _processRunner('reg.exe', <String>[
      'add',
      internetSettingsKey,
      '/v',
      name,
      '/t',
      type,
      '/d',
      data,
      '/f',
    ]);
    if (result.exitCode != 0) {
      final message = result.stderr.toString().trim();
      throw StateError(message.isEmpty ? '更新 Windows 系统代理失败。' : message);
    }
  }

  Future<void> _deleteValue(String name) async {
    final result = await _processRunner('reg.exe', <String>[
      'delete',
      internetSettingsKey,
      '/v',
      name,
      '/f',
    ]);
    // reg.exe returns 1 when the value is already absent, which is the desired
    // restored state.
    if (result.exitCode != 0 && result.exitCode != 1) {
      final message = result.stderr.toString().trim();
      throw StateError(message.isEmpty ? '恢复 Windows 系统代理失败。' : message);
    }
  }
}

class _RegistryValue {
  const _RegistryValue({required this.type, required this.data});

  final String type;
  final String data;

  Map<String, String> toJson() => <String, String>{
    'type': type,
    'data': data,
  };
}
