import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'app_update.dart';

/// 更新线路：一条线路同时决定「从哪里读清单」和「从哪里下安装包」。
enum UpdateChannel { auto, domestic, direct, proxy }

extension UpdateChannelInfo on UpdateChannel {
  String get label => switch (this) {
    UpdateChannel.auto => '自动线路',
    UpdateChannel.domestic => '国内',
    UpdateChannel.direct => '直连',
    UpdateChannel.proxy => '代理',
  };

  String get hint => switch (this) {
    UpdateChannel.auto => '自动选择最快的线路',
    UpdateChannel.domestic => 'GitCode 国内直连，速度最快',
    UpdateChannel.direct => 'GitHub 官方地址，海外网络或已开代理时使用',
    UpdateChannel.proxy => 'GitHub 走公共加速，直连打不开时使用',
  };

  String get value => name;
}

/// 把持久化的字符串还原成线路，未知值一律回到自动。
UpdateChannel parseUpdateChannel(String? value) => switch (value) {
  'domestic' => UpdateChannel.domestic,
  'direct' => UpdateChannel.direct,
  'proxy' => UpdateChannel.proxy,
  _ => UpdateChannel.auto,
};

/// 「用浏览器打开」的地址：国内线路给 GitCode，其余给 GitHub。
String releaseUrlOf(AppUpdate update, UpdateChannel channel) =>
    channel == UpdateChannel.domestic
    ? 'https://gitcode.com/$updateGitCodeRepo/releases/tag/${update.tag}'
    : update.url;

/// 浏览器兜底时优先给安装包直链，省得用户再去发布页里找。
String? directApkUrlOf(AppUpdate update, String abi, UpdateChannel channel) {
  final apk = update.apkFor(abi);
  if (apk == null) return null;
  final candidates = apk.candidates;
  if (candidates.isEmpty) return null;
  for (final url in candidates) {
    final host = _host(url);
    final domestic = host.endsWith('gitcode.com');
    if (channel == UpdateChannel.domestic && domestic) return url;
    if (channel != UpdateChannel.domestic && !domestic) return url;
  }
  return candidates.first;
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

const _userAgent = 'RedGuo-Updater';
const _manifestName = 'update.json';
const _gitCodeApi = 'https://api.gitcode.com/api/v5/repos/$updateGitCodeRepo';
const _gitHubApi = 'https://api.github.com/repos/$updateGitHubRepo';
const _gitHubRaw =
    'https://raw.githubusercontent.com/$updateGitHubRepo/main/redguo';

/// 公共 GitHub 加速前缀，按顺序尝试。
const _mirrorPrefixes = ['https://gh-proxy.com/', 'https://ghfast.top/'];

const _connectTimeout = Duration(seconds: 8);
const _requestTimeout = Duration(seconds: 12);
const _manifestLimit = 65536;

/// 把资源设置里的手动代理转成 HttpClient 的 findProxy 字符串。
String proxyFrom(String mode, String url) {
  if (mode != 'manual') return '';
  final text = url.trim();
  if (text.isEmpty) return '';
  // 用户常直接填 127.0.0.1:7890，缺协议时补一个再解析。
  var uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) uri = Uri.tryParse('http://$text');
  if (uri == null || uri.host.isEmpty) return '';
  if (uri.scheme.isNotEmpty && uri.scheme != 'http') return '';
  return 'PROXY ${uri.host}:${uri.hasPort ? uri.port : 80}';
}

/// 按线路读取最新版本，返回 null 表示当前已是最新。
Future<AppUpdate?> fetchLatestUpdate({
  required UpdateChannel channel,
  required int installed,
  String proxy = '',
}) async {
  switch (channel) {
    case UpdateChannel.domestic:
      return _newer(await _fromDomestic(proxy), installed);
    case UpdateChannel.direct:
      return _newer(await _fromDirect(proxy), installed);
    case UpdateChannel.proxy:
      return _newer(await _fromProxy(proxy), installed);
    case UpdateChannel.auto:
      return _auto(installed, proxy);
  }
}

AppUpdate? _newer(AppUpdate update, int installed) =>
    update.newerThan(installed) ? update : null;

/// 自动线路：国内优先，只有拿不到新版时才继续问直连和代理，
/// 避免 GitCode 同步落后导致用户永远收不到更新。
Future<AppUpdate?> _auto(int installed, String proxy) async {
  final updates = <AppUpdate>[];
  final errors = <String>[];
  // 备选源只给 6 秒，避免国内已经答完还要陪着等 GitHub。
  for (final (name, load)
      in <(String, Future<AppUpdate> Function(String, Duration))>[
        ('国内', _fromDomestic),
        ('直连', _fromDirect),
        ('代理', _fromProxy),
      ]) {
    try {
      final update = await load(proxy, const Duration(seconds: 6));
      updates.add(update);
      if (update.newerThan(installed)) break;
    } on Object catch (error) {
      errors.add('$name：${_reason(error)}');
    }
  }
  if (updates.isEmpty) {
    throw UpdateFailure('全部线路都不可用（${errors.join('；')}）');
  }
  updates.sort((a, b) => b.versionCode.compareTo(a.versionCode));
  return _newer(updates.first, installed);
}

/// 国内线路：GitCode 最新发布接口，再从附件里取清单。
/// raw.gitcode.com 的仓库文件被 CloudWAF 拦截（418），只有附件直链可用，
/// 所以这里不做 raw 兜底，接口失败交给自动线路去问直连。
Future<AppUpdate> _fromDomestic(
  String proxy, [
  Duration timeout = _requestTimeout,
]) async {
  final client = _client(proxy);
  final stamp = _stampOf();
  try {
    final body = await _get(
      client,
      '$_gitCodeApi/releases/latest?type=latest&cachebust=$stamp',
      timeout: timeout,
    );
    final release = _releaseOf(body);
    // GitCode 用 release_status 标记最新正式版，字段缺失时按最新处理。
    final status = release['release_status'];
    if (status is String && status.isNotEmpty && status != 'latest') {
      throw const UpdateFailure('GitCode 最新发布不是正式版');
    }
    final tag = release['tag_name'] as String? ?? '';
    if (!tag.startsWith(updateTagPrefix)) {
      throw const UpdateFailure('GitCode 最新发布不属于正式版通道');
    }
    final asset = manifestAssetUrl(release);
    if (asset == null) {
      throw const UpdateFailure('GitCode 发布缺少 $_manifestName 附件');
    }
    // GitCode 附件地址带额外查询参数会 404，这里不加 cachebust。
    return _parse(await _get(client, asset, timeout: timeout), tag: tag);
  } finally {
    client.close(force: true);
  }
}

/// 直连线路：GitHub 官方接口与附件，不经任何代理。
Future<AppUpdate> _fromDirect(
  String proxy, [
  Duration timeout = _requestTimeout,
]) async {
  final client = _client(proxy);
  final stamp = _stampOf();
  try {
    try {
      final body = await _get(
        client,
        '$_gitHubApi/releases/latest?cachebust=$stamp',
        timeout: timeout,
      );
      return await _fromGitHubRelease(
        client,
        _releaseOf(body),
        '$stamp',
        '',
        timeout,
      );
    } on UpdateFailure {
      final body = await _get(
        client,
        '$_gitHubRaw/$_manifestName?cachebust=$stamp',
        timeout: timeout,
      );
      return _parse(body);
    }
  } finally {
    client.close(force: true);
  }
}

/// 代理线路：接口与附件都套公共加速前缀，代理站的接口不可用时退回 raw 清单。
Future<AppUpdate> _fromProxy(
  String proxy, [
  Duration timeout = _requestTimeout,
]) async {
  final client = _client(proxy);
  final stamp = _stampOf();
  final errors = <String>[];
  try {
    for (final prefix in _mirrorPrefixes) {
      try {
        final body = await _get(
          client,
          '$prefix$_gitHubApi/releases/latest?cachebust=$stamp',
          timeout: timeout,
        );
        return await _fromGitHubRelease(
          client,
          _releaseOf(body),
          '$stamp',
          prefix,
          timeout,
        );
      } on Object catch (error) {
        errors.add('${_host(prefix)}：${_reason(error)}');
      }
    }
    for (final prefix in _mirrorPrefixes) {
      try {
        final body = await _get(
          client,
          '$prefix$_gitHubRaw/$_manifestName?cachebust=$stamp',
          timeout: timeout,
        );
        return _parse(body);
      } on Object catch (error) {
        errors.add('${_host(prefix)}：${_reason(error)}');
      }
    }
    throw UpdateFailure('代理线路全部失败（${errors.join('；')}）');
  } finally {
    client.close(force: true);
  }
}

/// 从 GitHub 发布接口的响应里找到清单附件并下载。
Future<AppUpdate> _fromGitHubRelease(
  HttpClient client,
  Map<String, dynamic> release,
  String stamp,
  String prefix,
  Duration timeout,
) async {
  if (release['draft'] == true || release['prerelease'] == true) {
    throw const UpdateFailure('最新发布不是正式版');
  }
  final tag = release['tag_name'] as String? ?? '';
  if (!tag.startsWith(updateTagPrefix)) {
    throw const UpdateFailure('最新发布不属于正式版通道');
  }
  final asset = manifestAssetUrl(release);
  if (asset == null) {
    throw const UpdateFailure('发布缺少 $_manifestName 附件');
  }
  return _parse(
    await _get(client, '$prefix${_withStamp(asset, stamp)}', timeout: timeout),
    tag: tag,
  );
}

HttpClient _client(String proxy) {
  final client = HttpClient()
    ..connectionTimeout = _connectTimeout
    ..userAgent = _userAgent;
  if (proxy.isNotEmpty) client.findProxy = (_) => proxy;
  return client;
}

Future<String> _get(
  HttpClient client,
  String url, {
  Duration timeout = _requestTimeout,
}) async {
  final host = _host(url);
  try {
    return await _read(client, url, host).timeout(timeout);
  } on TimeoutException {
    throw UpdateFailure('请求超时（$host）');
  } on SocketException {
    throw UpdateFailure('连接失败（$host）');
  } on HandshakeException {
    throw UpdateFailure('安全连接失败（$host）');
  }
}

Future<String> _read(HttpClient client, String url, String host) async {
  final request = await client.getUrl(Uri.parse(url));
  request.headers.set(
    HttpHeaders.acceptHeader,
    'application/json, text/plain, */*',
  );
  request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw UpdateFailure('HTTP ${response.statusCode}（$host）');
  }
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in response) {
    buffer.add(chunk);
    if (buffer.length > _manifestLimit) {
      throw UpdateFailure('清单过大（$host）');
    }
  }
  return utf8.decode(buffer.takeBytes(), allowMalformed: true);
}

Map<String, dynamic> _releaseOf(String body) {
  final Object? data;
  try {
    data = jsonDecode(body);
  } on FormatException {
    throw const UpdateFailure('发布接口返回的不是 JSON');
  }
  if (data is! Map<String, dynamic>) {
    throw const UpdateFailure('发布接口返回格式错误');
  }
  return data;
}

/// 清单附件的下载地址，GitCode 要求附件类型为 attach。
/// 公开给测试：GitCode 的 assets 里还混着 source 源码包，必须只认 attach。
@visibleForTesting
String? manifestAssetUrl(Map<String, dynamic> release) {
  for (final asset in release['assets'] as List? ?? const []) {
    if (asset is! Map) continue;
    if (asset['name'] != _manifestName) continue;
    final type = asset['type'];
    if (type is String && type.isNotEmpty && type != 'attach') continue;
    final url = asset['browser_download_url'];
    if (url is String && url.isNotEmpty) return url;
  }
  return null;
}

AppUpdate _parse(String body, {String tag = ''}) {
  final Object? data;
  try {
    data = jsonDecode(body);
  } on FormatException {
    throw const UpdateFailure('更新清单不是 JSON');
  }
  if (data is! Map<String, dynamic>) {
    throw const UpdateFailure('更新清单格式错误');
  }
  final update = AppUpdate.fromJson(data, tag: tag);
  if (update == null) {
    throw const UpdateFailure('更新清单与当前应用不匹配');
  }
  return update;
}

int _stampOf() => DateTime.now().millisecondsSinceEpoch;

String _withStamp(String url, String stamp) =>
    url.contains('?') ? '$url&cachebust=$stamp' : '$url?cachebust=$stamp';

String _host(String url) => Uri.tryParse(url)?.host ?? url;

String _reason(Object error) => switch (error) {
  UpdateFailure(:final message) => message,
  TimeoutException() => '超时',
  _ => '$error',
};
