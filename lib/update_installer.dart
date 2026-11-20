import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_update.dart';
import 'core_bridge.dart';
import 'diary_service.dart';
import 'update_channel.dart';

const _channel = MethodChannel('duanju/device');
const _userAgent = 'guoapp-updater';

/// 应用内更新：按清单里给的地址下载安装包，校验完整后交给系统安装程序。
class UpdateDownload {
  UpdateDownload({
    required this.update,
    required this.abi,
    this.proxy = '',
    this.channel = UpdateChannel.auto,
  });

  final AppUpdate update;
  final String abi;
  final String proxy;
  final UpdateChannel channel;

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

  /// 读取当前安装包签名证书的 SHA-256 指纹；读取失败时拒绝更新。
  static Future<String> signingCertificateSha256() async {
    if (!Platform.isAndroid) {
      throw AppFailure('当前平台无法读取 Android 应用签名');
    }
    try {
      final value = await _channel
          .invokeMethod<String>('appSigningCertSha256')
          .timeout(const Duration(seconds: 5));
      final normalized = (value ?? '').replaceAll(':', '').trim().toLowerCase();
      if (normalized.length != 64 ||
          !RegExp(r'^[0-9a-f]{64}').hasMatch(normalized)) {
        throw AppFailure('无法读取当前应用签名证书');
      }
      return normalized;
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw AppFailure('无法读取当前应用签名证书');
    }
  }

  /// 启用手动代理时沿用设置里的地址，让下载和检查更新走同一条线路。
  static Future<String> proxyOf(AppRepository repository) async {
    try {
      final settings = await repository.resourceSettings();
      return proxyFrom(settings.proxyMode, settings.proxyUrl);
    } catch (_) {
      return '';
    }
  }

  Future<File> run({void Function()? onProgress}) async {
    final apk = update.apkFor(abi);
    if (apk == null) throw AppFailure('更新清单里没有可用的安装包');
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..userAgent = _userAgent;
    if (proxy.isNotEmpty) client.findProxy = (_) => proxy;
    try {
      final directory = Directory(
        path.join((await getTemporaryDirectory()).path, 'updates'),
      );
      if (!await directory.exists()) await directory.create(recursive: true);
      final errors = <String>[];
      for (final url in _candidates(apk)) {
        final uri = Uri.tryParse(url);
        if (uri == null || uri.host.isEmpty) continue;
        try {
          location = uri;
          DiaryService.add('[更新] 下载 ${update.version}：$uri');
          final target = await _download(
            client,
            uri,
            apk,
            directory,
            onProgress,
          );
          file = target;
          DiaryService.add(
            '[更新] 下载完成 ${update.version}，'
            '${(target.lengthSync() / 1048576).toStringAsFixed(1)} MB',
          );
          return target;
        } on UpdateCancelled {
          rethrow;
        } on Object catch (error) {
          errors.add('${_host(url)}：${_reason(error)}');
          received = 0;
        }
      }
      throw AppFailure(
        errors.isEmpty ? '没有可用的安装包地址' : '下载失败（${errors.join('；')}）',
      );
    } finally {
      client.close(force: true);
      _client = null;
    }
  }

  /// 线路只影响尝试顺序：选了国内就先试 GitCode，选了代理就先试加速前缀。
  List<String> _candidates(AppUpdateApk apk) {
    final all = apk.candidates;
    if (all.length < 2) return all;
    final preferred = <String>[];
    final rest = <String>[];
    for (final url in all) {
      (_preferred(url) ? preferred : rest).add(url);
    }
    return [...preferred, ...rest];
  }

  bool _preferred(String url) {
    final host = _host(url);
    return switch (channel) {
      // 自动线路同样国内优先，取不到再退直连与代理。
      UpdateChannel.auto ||
      UpdateChannel.domestic => host.endsWith('gitcode.com'),
      UpdateChannel.proxy => _isMirror(host),
      UpdateChannel.direct => host == 'github.com',
    };
  }

  static bool _isMirror(String host) =>
      const {'gh-proxy.com', 'ghfast.top'}.contains(host);

  Future<File> _download(
    HttpClient client,
    Uri uri,
    AppUpdateApk apk,
    Directory directory,
    void Function()? onProgress,
  ) async {
    final safe = update.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '-');
    final target = File(path.join(directory.path, 'update-$safe-$abi.apk'));
    final partial = File('${target.path}.part');
    if (await target.exists()) await target.delete();
    if (await partial.exists()) await partial.delete();

    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AppFailure('HTTP ${response.statusCode}');
    }
    total = response.contentLength > 0 ? response.contentLength : apk.size;
    received = 0;
    final sink = partial.openWrite();
    try {
      // 事件间隔超时：连上了但一直不给数据也要能换源。
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (_cancelled) throw const UpdateCancelled();
        sink.add(chunk);
        received += chunk.length;
        if (apk.size > 0 && received > apk.size) {
          throw AppFailure('安装包长度异常');
        }
        onProgress?.call();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (_cancelled) throw const UpdateCancelled();
    await _verify(partial, apk);
    await partial.rename(target.path);
    return target;
  }

  /// 长度和 SHA256 都要对上，避免装到半个包或别人的包。
  Future<void> _verify(File file, AppUpdateApk apk) async {
    if (apk.size > 0 && await file.length() != apk.size) {
      await file.delete().catchError((Object _) => file);
      throw AppFailure('安装包长度不匹配，请重试');
    }
    if (apk.sha256.length == 64) {
      final digest = await sha256.bind(file.openRead()).first;
      if ('$digest' != apk.sha256) {
        await file.delete().catchError((Object _) => file);
        throw AppFailure('安装包校验未通过，请重试');
      }
    }
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

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;

  static String _reason(Object error) => switch (error) {
    AppFailure(:final message) => message,
    TimeoutException() => '超时',
    _ => '$error',
  };
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();

  @override
  String toString() => '已取消下载';
}
