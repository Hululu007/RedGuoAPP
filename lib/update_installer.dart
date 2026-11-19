import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_update.dart';
import 'core_bridge.dart';
import 'diary_service.dart';

const _channel = MethodChannel('duanju/device');
const _userAgent = 'guoapp-updater';

/// GitHub Release 地址里的仓库与标签；不是发布页时返回 null。
({String owner, String repo, String tag})? releaseRef(Uri release) {
  if (!release.hasScheme) return null;
  final segments = release.pathSegments;
  if (segments.length < 5 ||
      segments[2] != 'releases' ||
      segments[3] != 'tag') {
    return null;
  }
  final owner = segments[0];
  final repo = segments[1];
  final tag = segments[4];
  if (owner.isEmpty || repo.isEmpty || tag.isEmpty) return null;
  return (owner: owner, repo: repo, tag: tag);
}

/// 从发布页 HTML 里挑出安装包地址，优先匹配当前设备的架构。
Uri? apkUriIn(String html, {required Uri base, required String abi}) {
  final links = <Uri>[];
  for (final match in RegExp(
    r'''href="([^"]+?\.apk)(?:\?[^"]*)?"''',
    caseSensitive: false,
  ).allMatches(html)) {
    final raw = match.group(1);
    if (raw == null) continue;
    final uri = Uri.tryParse(raw);
    if (uri == null) continue;
    final absolute = uri.hasScheme ? uri : base.resolveUri(uri);
    if (!links.contains(absolute)) links.add(absolute);
  }
  if (links.isEmpty) return null;
  final suffix = '-$abi.apk'.toLowerCase();
  for (final uri in links) {
    if (uri.path.toLowerCase().endsWith(suffix)) return uri;
  }
  return links.length == 1 ? links.first : null;
}

/// 把版本号换算成安装包文件名里用的短版本（去掉构建号）。
String shortVersion(String version) => version.split('+').first;

/// 应用内更新：定位安装包、下载到缓存目录，再交给系统安装程序。
class UpdateDownload {
  UpdateDownload({required this.update, required this.abi, this.proxy = ''});

  final AppUpdate update;
  final String abi;
  final String proxy;

  HttpClient? _client;
  bool _cancelled = false;
  int received = 0;
  int total = 0;

  Uri? location;
  File? file;

  double get progress => total > 0 ? (received / total).clamp(0, 1) : 0;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  /// 当前设备的主架构，优先问原生（能识别 32 位安装包在 64 位设备上的情况）。
  static Future<String> deviceAbi() async {
    if (!Platform.isAndroid) return '';
    try {
      final data = await _channel
          .invokeMapMethod<String, dynamic>('deviceInfo')
          .timeout(const Duration(seconds: 2));
      final abi = data?['abi'];
      if (abi is String && abi.isNotEmpty) return abi;
    } catch (_) {}
    return switch (Abi.current()) {
      Abi.androidArm64 => 'arm64-v8a',
      Abi.androidArm => 'armeabi-v7a',
      Abi.androidX64 => 'x86_64',
      Abi.androidIA32 => 'x86',
      _ => '',
    };
  }

  /// 启用手动代理时沿用设置里的地址，让下载和检查更新走同一条线路。
  static Future<String> proxyOf(AppRepository repository) async {
    try {
      final settings = await repository.resourceSettings();
      if (settings.proxyMode != 'manual') return '';
      final uri = Uri.tryParse(settings.proxyUrl.trim());
      if (uri == null || uri.host.isEmpty) return '';
      if (uri.scheme.isNotEmpty && uri.scheme != 'http') return '';
      final port = uri.hasPort ? uri.port : 80;
      return 'PROXY ${uri.host}:$port';
    } catch (_) {
      return '';
    }
  }

  Future<File> run({void Function()? onProgress}) async {
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = _userAgent;
    if (proxy.isNotEmpty) client.findProxy = (_) => proxy;
    try {
      final directory = Directory(
        path.join((await getTemporaryDirectory()).path, 'updates'),
      );
      if (!await directory.exists()) await directory.create(recursive: true);
      final uri = location = await _locate(client);
      DiaryService.add('[更新] 下载 ${update.version}：$uri');
      final target = await _download(client, uri, directory, onProgress);
      file = target;
      DiaryService.add(
        '[更新] 下载完成 ${update.version}，${(target.lengthSync() / 1048576).toStringAsFixed(1)} MB',
      );
      return target;
    } catch (error) {
      if (_cancelled) throw const UpdateCancelled();
      rethrow;
    } finally {
      client.close(force: true);
      _client = null;
    }
  }

  Future<Uri> _locate(HttpClient client) async {
    final release = Uri.tryParse(update.url.trim());
    if (release == null || release.host.isEmpty) {
      throw AppFailure('更新地址无效');
    }
    if (release.path.toLowerCase().endsWith('.apk')) return release;
    final ref = releaseRef(release);
    if (ref == null) throw AppFailure('这个更新地址不支持应用内下载');

    final names = <String>{
      'guoapp-${update.version}-$abi.apk',
      'guoapp-${shortVersion(update.version)}-$abi.apk',
    };
    for (final name in names) {
      final uri = Uri.parse(
        '${release.origin}/${ref.owner}/${ref.repo}/releases/download/'
        '${Uri.encodeComponent(ref.tag)}/${Uri.encodeComponent(name)}',
      );
      if (await _probe(client, uri)) return uri;
    }

    for (final url in [
      '${release.origin}/${ref.owner}/${ref.repo}/releases/expanded_assets/${ref.tag}',
      '${release.origin}/${ref.owner}/${ref.repo}/releases/tag/${ref.tag}',
    ]) {
      final page = Uri.parse(url);
      final html = await _read(client, page);
      if (html == null) continue;
      final uri = apkUriIn(html, base: page, abi: abi);
      if (uri != null) return uri;
    }
    throw AppFailure('没有找到适用于当前设备的安装包');
  }

  Future<bool> _probe(HttpClient client, Uri uri) async {
    try {
      final request = await client.headUrl(uri);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _read(HttpClient client, Uri uri) async {
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 1 << 20) break;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Future<File> _download(
    HttpClient client,
    Uri uri,
    Directory directory,
    void Function()? onProgress,
  ) async {
    final safe = update.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '-');
    final target = File(path.join(directory.path, 'update-$safe-$abi.apk'));
    for (final stale in directory.listSync().whereType<File>()) {
      if (stale.path == target.path) continue;
      if (!stale.path.toLowerCase().endsWith('.apk')) continue;
      await stale.delete().catchError((Object _) => stale);
    }
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AppFailure('下载失败：HTTP ${response.statusCode}');
    }
    total = response.contentLength;
    received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in response) {
        if (_cancelled) throw const UpdateCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (_cancelled) throw const UpdateCancelled();
    if (total > 0 && received != total) {
      await target.delete().catchError((Object _) => target);
      throw AppFailure('安装包下载不完整，请重试');
    }
    if (await target.length() <= 0) {
      throw AppFailure('安装包内容为空，请重试');
    }
    return target;
  }

  /// 交出安装包，交给系统安装程序。
  static Future<String> install(String file) async {
    if (!Platform.isAndroid) throw AppFailure('当前平台不支持应用内安装');
    try {
      return await _channel.invokeMethod<String>('installUpdate', {
            'path': file,
          }) ??
          '';
    } on PlatformException catch (error) {
      throw AppFailure(error.message ?? '无法启动安装程序');
    }
  }
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();

  @override
  String toString() => '已取消下载';
}
