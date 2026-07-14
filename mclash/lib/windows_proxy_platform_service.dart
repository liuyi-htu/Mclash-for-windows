import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'proxy_platform_service.dart';

class WindowsProxyPlatformService implements ProxyPlatformService {
  WindowsProxyPlatformService({String? dataDir}) : _dataDirOverride = dataDir;

  final String? _dataDirOverride;

  String get _dataDir =>
      _dataDirOverride ??
      '${File(Platform.resolvedExecutable).parent.path}\\data';
  String get _profilesDir => '$_dataDir\\profiles';
  String get _logsDir => '$_dataDir\\logs';
  String get _statePath => '$_dataDir\\state.json';
  String get _configPath => '$_dataDir\\config.yaml';
  String get _serviceExe =>
      '${File(Platform.resolvedExecutable).parent.path}\\MclashService.exe';

  Future<void> _ensureDirectories() async {
    await Directory(_profilesDir).create(recursive: true);
    await Directory(_logsDir).create(recursive: true);
  }

  Future<Map<String, dynamic>> _readState() async {
    try {
      final decoded = jsonDecode(await File(_statePath).readAsString());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _updateState(Map<String, dynamic> changes) async {
    await _ensureDirectories();
    final state = await _readState()
      ..addAll(changes);
    final temporary = File('$_statePath.tmp');
    await temporary
        .writeAsString(const JsonEncoder.withIndent('  ').convert(state));
    await temporary.rename(_statePath);
  }

  Future<Map<String, dynamic>> _status() async {
    final result = await _runService('status-json', allowFailure: true);
    try {
      final decoded = jsonDecode(result.stdout.toString().trim());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    if (!File(_serviceExe).existsSync()) {
      throw StateError('MclashService.exe was not found next to Mclash.exe.');
    }
    throw StateError(result.stderr.toString().trim().isEmpty
        ? 'Unable to read the Windows service status.'
        : result.stderr.toString().trim());
  }

  Future<ProcessResult> _runService(String command,
      {bool allowFailure = false}) async {
    if (!await File(_serviceExe).exists()) {
      throw StateError('MclashService.exe was not found next to Mclash.exe.');
    }
    final result = await Process.run(
        _serviceExe,
        <String>[
          command,
          '--base',
          File(_serviceExe).parent.path,
          '--data-dir',
          _dataDir,
        ],
        runInShell: false);
    if (!allowFailure && result.exitCode != 0) {
      final message = result.stderr.toString().trim();
      throw StateError(
          message.isEmpty ? '$command failed (${result.exitCode}).' : message);
    }
    return result;
  }

  @override
  Future<bool> isRunning() async => (await _status())['state'] == 'running';

  @override
  Future<void> start() async {
    final status = await _status();
    if (status['installed'] != true) await _runService('install');
    await _runService('start');
  }

  @override
  Future<void> stop() => _runService('stop').then((_) {});

  @override
  Future<void> restart() => _runService('restart').then((_) {});

  @override
  Future<ConfigInfo> getConfigInfo() async {
    final state = await _readState();
    final exists = await File(_configPath).exists();
    final active = state['activeProfile']?.toString();
    final names = state['profileNames'];
    final displayName =
        names is Map && active != null ? names[active]?.toString() : null;
    return ConfigInfo(
        exists: exists,
        fileName: displayName ?? (exists ? 'config.yaml' : null));
  }

  String _profilePath(String id) {
    if (!RegExp(r'^[A-Za-z0-9._-]+\.yaml$', caseSensitive: false)
        .hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid profile id');
    }
    return '$_profilesDir\\$id';
  }

  Map<String, dynamic> _stateMap(Map<String, dynamic> state, String key) =>
      Map<String, dynamic>.from(
          state[key] is Map ? state[key] as Map : const {});

  @override
  Future<List<ConfigProfile>> getConfigs() async {
    await _ensureDirectories();
    var state = await _readState();
    var active = state['activeProfile']?.toString();
    final defaultProfile = File(_profilePath('default.yaml'));
    if (active == null &&
        await File(_configPath).exists() &&
        !await defaultProfile.exists()) {
      await File(_configPath).copy(defaultProfile.path);
      await _updateState(<String, dynamic>{
        'activeProfile': 'default.yaml',
        'profileNames': <String, dynamic>{'default.yaml': 'Default'},
      });
      state = await _readState();
      active = 'default.yaml';
    }
    final rawNames = state['profileNames'];
    final names = rawNames is Map ? rawNames : const <String, dynamic>{};
    final types = _stateMap(state, 'profileTypes');
    final urls = _stateMap(state, 'profileUrls');
    final files = await Directory(_profilesDir)
        .list()
        .where((entity) =>
            entity is File && entity.path.toLowerCase().endsWith('.yaml'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    final profiles = <ConfigProfile>[];
    for (final file in files) {
      final id = file.uri.pathSegments.last;
      if (!names.containsKey(id) && active != id) {
        continue;
      }
      final stat = await file.stat();
      profiles.add(ConfigProfile(
        id: id,
        name: names[id]?.toString() ?? id.substring(0, id.length - 5),
        type:
            types[id]?.toString() == 'subscription' ? 'subscription' : 'local',
        url: urls[id]?.toString(),
        active: active == id,
        exists: true,
        updatedAt: stat.modified.millisecondsSinceEpoch,
      ));
    }
    return profiles;
  }

  @override
  Future<List<ConfigProfile>> importConfigs() async {
    await _ensureDirectories();
    const script = r'''Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = 'Mihomo YAML (*.yaml)|*.yaml'
$dialog.Multiselect = $true
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  $dialog.FileNames | ForEach-Object { [Console]::Out.WriteLine($_) }
}''';
    final picked = await Process.run('powershell.exe', const <String>[
      '-NoProfile',
      '-STA',
      '-Command',
      script,
    ]);
    if (picked.exitCode != 0) throw StateError(picked.stderr.toString());
    final paths = const LineSplitter()
        .convert(picked.stdout.toString())
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (paths.isEmpty) return getConfigs();
    final state = await _readState();
    final names = Map<String, dynamic>.from(
        state['profileNames'] is Map ? state['profileNames'] as Map : const {});
    for (final sourcePath in paths) {
      final source = File(sourcePath);
      if (source.uri.pathSegments.last.toLowerCase().endsWith('.yaml') ==
          false) {
        throw ArgumentError('Only .yaml profiles are supported.');
      }
      var id = source.uri.pathSegments.last
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      if (!id.toLowerCase().endsWith('.yaml')) id = '$id.yaml';
      var candidate = id;
      var suffix = 2;
      while (await File(_profilePath(candidate)).exists()) {
        candidate = '${id.substring(0, id.length - 5)}-$suffix.yaml';
        suffix++;
      }
      await source.copy(_profilePath(candidate));
      names[candidate] = id.substring(0, id.length - 5);
    }
    await _updateState(<String, dynamic>{'profileNames': names});
    return getConfigs();
  }

  String _secureController(String content) {
    var result = content.replaceAll(
      RegExp(r'^\s*external-controller\s*:.*$', multiLine: true),
      'external-controller: 127.0.0.1:9090',
    );
    if (!RegExp(r'^\s*external-controller\s*:', multiLine: true)
        .hasMatch(result)) {
      result = '$result\nexternal-controller: 127.0.0.1:9090\n';
    }
    result = result.replaceAll(
        RegExp(r'^\s*secret\s*:.*$', multiLine: true), 'secret: ""');
    if (!RegExp(r'^\s*secret\s*:', multiLine: true).hasMatch(result)) {
      result = '$result\nsecret: ""\n';
    }
    return result;
  }

  @override
  Future<ConfigInfo> selectConfig(String id) async {
    final source = File(_profilePath(id));
    if (!await source.exists()) {
      throw StateError('The selected profile no longer exists.');
    }
    await File(_configPath)
        .writeAsString(_secureController(await source.readAsString()));
    await _updateState(<String, dynamic>{'activeProfile': id});
    return getConfigInfo();
  }

  @override
  Future<String> getConfigContent(String id) =>
      File(_profilePath(id)).readAsString();

  @override
  Future<List<ConfigProfile>> saveConfigContent(
      {required String id, required String content}) async {
    if (content.trim().isEmpty) {
      throw ArgumentError('Configuration cannot be empty.');
    }
    await File(_profilePath(id)).writeAsString(content);
    final state = await _readState();
    if (state['activeProfile'] == id) {
      await File(_configPath).writeAsString(_secureController(content));
    }
    return getConfigs();
  }

  @override
  Future<List<ConfigProfile>> renameConfig(
      {required String id, required String name}) async {
    if (name.trim().isEmpty) {
      throw ArgumentError('Profile name cannot be empty.');
    }
    final state = await _readState();
    final names = Map<String, dynamic>.from(
        state['profileNames'] is Map ? state['profileNames'] as Map : const {});
    names[id] = name.trim();
    await _updateState(<String, dynamic>{'profileNames': names});
    return getConfigs();
  }

  @override
  Future<List<ConfigProfile>> deleteConfig(String id) async {
    final state = await _readState();
    if (state['activeProfile'] == id) {
      throw StateError(
          'Select another profile before deleting the active profile.');
    }
    final file = File(_profilePath(id));
    if (await file.exists()) await file.delete();
    final names = Map<String, dynamic>.from(
        state['profileNames'] is Map ? state['profileNames'] as Map : const {})
      ..remove(id);
    final types = _stateMap(state, 'profileTypes')..remove(id);
    final urls = _stateMap(state, 'profileUrls')..remove(id);
    await _updateState(<String, dynamic>{
      'profileNames': names,
      'profileTypes': types,
      'profileUrls': urls,
    });
    return getConfigs();
  }

  @override
  Future<String> getStartupLog() async {
    final file = File('$_logsDir\\service.log');
    return await file.exists()
        ? file.readAsString()
        : 'No service log is available.';
  }

  @override
  Future<bool> getUsageNoticeAccepted() async =>
      (await _readState())['usageNoticeAccepted'] == true;
  @override
  Future<void> acceptUsageNotice() =>
      _updateState(<String, dynamic>{'usageNoticeAccepted': true});
  @override
  Future<bool> getDebugLoggingEnabled() async =>
      (await _readState())['debugLoggingEnabled'] == true;
  @override
  Future<void> setDebugLoggingEnabled(bool enabled) =>
      _updateState(<String, dynamic>{'debugLoggingEnabled': enabled});
  @override
  Future<void> clearDebugLogs() async {
    for (final name in const <String>['service.log', 'mihomo.log']) {
      final file = File('$_logsDir\\$name');
      if (await file.exists()) await file.writeAsString('');
    }
  }

  @override
  Future<bool> getServiceAutoStartEnabled() async {
    final result = await _runService('autostart-json');
    final decoded = jsonDecode(result.stdout.toString().trim());
    return decoded is Map<String, dynamic> && decoded['enabled'] == true;
  }

  @override
  Future<void> setServiceAutoStartEnabled(bool enabled) async {
    final status = await _status();
    if (status['installed'] != true) {
      if (!enabled) return;
      await _runService('install');
    }
    await _runService(enabled ? 'enable-autostart' : 'disable-autostart');
  }

  @override
  Future<CoreUpdateInfo> checkCoreUpdate() async {
    final result = await _runService('core-update-json');
    final decoded = jsonDecode(result.stdout.toString().trim());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid core update response.');
    }
    return CoreUpdateInfo.fromMap(decoded);
  }

  @override
  Future<void> updateCore() => _runService('update-core').then((_) {});

  Uri _subscriptionUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw ArgumentError('请输入有效的 HTTP 或 HTTPS 订阅链接。');
    }
    return uri;
  }

  bool _looksLikeMihomoConfig(String content) => RegExp(
        r'^\s*(proxies|proxy-providers|proxy-groups|rules|mixed-port|port|socks-port|redir-port|tproxy-port)\s*:',
        caseSensitive: false,
        multiLine: true,
      ).hasMatch(content);

  Future<_SubscriptionDownload> _downloadSubscription(String url) async {
    final uri = _subscriptionUri(url);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'clash.meta';
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = true;
        request.maxRedirects = 5;
        request.headers.set(HttpHeaders.acceptHeader,
            'application/yaml, text/yaml, text/plain, */*');
        request.headers.set(HttpHeaders.userAgentHeader, 'clash.meta');
        final stopwatch = Stopwatch()..start();
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 16 * 1024 * 1024) {
            throw StateError('订阅内容超过 16 MB 限制。');
          }
        }
        stopwatch.stop();
        final contentType = response.headers.contentType?.mimeType;
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
            '订阅服务器返回 HTTP ${response.statusCode}。',
            uri: uri,
          );
        }
        String content;
        try {
          content = utf8.decode(bytes);
        } on FormatException {
          throw const FormatException('订阅内容不是有效的 UTF-8 文本。');
        }
        if (content.startsWith('\uFEFF')) content = content.substring(1);
        if (content.trim().isEmpty) {
          throw StateError('订阅服务器返回了空内容。');
        }
        if (!_looksLikeMihomoConfig(content)) {
          throw StateError('订阅内容不是 Mihomo/Clash YAML 配置，请检查订阅链接类型。');
        }
        return _SubscriptionDownload(
          content: content,
          responseTimeMs: stopwatch.elapsedMilliseconds,
          statusCode: response.statusCode,
          contentType: contentType,
          contentLength: bytes.length,
        );
      })()
          .timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw StateError('连接订阅服务器超时。');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _writeSubscription(String id, String content) async {
    await _ensureDirectories();
    final target = File(_profilePath(id));
    final temporary = File('${target.path}.download');
    await temporary.writeAsString(content, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  String _newSubscriptionId() =>
      'subscription-${DateTime.now().microsecondsSinceEpoch}.yaml';

  @override
  Future<List<ConfigProfile>> addSubscription({
    required String name,
    required String url,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw ArgumentError('请输入订阅名称。');
    final cleanUrl = _subscriptionUri(url).toString();
    final download = await _downloadSubscription(cleanUrl);
    final id = _newSubscriptionId();
    await _writeSubscription(id, download.content);
    final state = await _readState();
    final names = _stateMap(state, 'profileNames')..[id] = cleanName;
    final types = _stateMap(state, 'profileTypes')..[id] = 'subscription';
    final urls = _stateMap(state, 'profileUrls')..[id] = cleanUrl;
    await _updateState(<String, dynamic>{
      'profileNames': names,
      'profileTypes': types,
      'profileUrls': urls,
    });
    return getConfigs();
  }

  @override
  Future<List<ConfigProfile>> updateSubscription({
    required String id,
    required String name,
    required String url,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) throw ArgumentError('请输入订阅名称。');
    final state = await _readState();
    if (_stateMap(state, 'profileTypes')[id] != 'subscription') {
      throw StateError('所选配置不是机场订阅。');
    }
    final cleanUrl = _subscriptionUri(url).toString();
    final download = await _downloadSubscription(cleanUrl);
    await _writeSubscription(id, download.content);
    final names = _stateMap(state, 'profileNames')..[id] = cleanName;
    final urls = _stateMap(state, 'profileUrls')..[id] = cleanUrl;
    await _updateState(<String, dynamic>{
      'profileNames': names,
      'profileUrls': urls,
    });
    if (state['activeProfile'] == id) {
      await File(_configPath)
          .writeAsString(_secureController(download.content), flush: true);
    }
    return getConfigs();
  }

  @override
  Future<List<ConfigProfile>> refreshSubscription(String id) async {
    final state = await _readState();
    if (_stateMap(state, 'profileTypes')[id] != 'subscription') {
      throw StateError('所选配置不是机场订阅。');
    }
    final url = _stateMap(state, 'profileUrls')[id]?.toString();
    if (url == null || url.isEmpty) throw StateError('订阅链接不存在。');
    final download = await _downloadSubscription(url);
    await _writeSubscription(id, download.content);
    if (state['activeProfile'] == id) {
      await File(_configPath)
          .writeAsString(_secureController(download.content), flush: true);
    }
    return getConfigs();
  }

  @override
  Future<SubscriptionUrlTestResult> testSubscriptionUrl(String id) async {
    final state = await _readState();
    final url = _stateMap(state, 'profileUrls')[id]?.toString();
    if (url == null || url.isEmpty) throw StateError('订阅链接不存在。');
    try {
      final result = await _downloadSubscription(url);
      return SubscriptionUrlTestResult(
        success: true,
        responseTimeMs: result.responseTimeMs,
        statusCode: result.statusCode,
        contentLength: result.contentLength,
        contentType: result.contentType,
        message: '订阅链接有效，内容为 Mihomo/Clash YAML 配置。',
      );
    } catch (error) {
      return SubscriptionUrlTestResult(
        success: false,
        message: error.toString().replaceFirst('Bad state: ', ''),
      );
    }
  }
}

class _SubscriptionDownload {
  const _SubscriptionDownload({
    required this.content,
    required this.responseTimeMs,
    required this.statusCode,
    required this.contentLength,
    required this.contentType,
  });

  final String content;
  final int responseTimeMs;
  final int statusCode;
  final int contentLength;
  final String? contentType;
}
