import 'dart:io';

import 'package:flutter/services.dart';

/// HEIC/HEIF 封面的兼容转码。
///
/// 少数源站的海报是 HEIC，Flutter 的图片解码器不认，界面上只剩占位图。
/// Android 侧用系统 `ImageDecoder`（API 28+）转成 JPEG，走 `duanju/cover` 通道，
/// 不引入任何原生库；其余平台直接返回 null，调用方退回原图。
class CoverCompat {
  static const _channel = MethodChannel('duanju/cover');

  /// 已经转好的路径，避免列表反复触发同一次跨通道调用。
  static final _converted = <String, String>{};

  static Future<String?> convert(String path) async {
    if (!Platform.isAndroid || path.isEmpty) return null;
    final known = _converted[path];
    if (known != null) return known;
    try {
      final result = await _channel.invokeMethod<String>('convert', {
        'path': path,
      });
      if (result == null || result.isEmpty) return null;
      _converted[path] = result;
      if (_converted.length > 512) _converted.remove(_converted.keys.first);
      return result;
    } catch (_) {
      // 通道不可用（纯 Dart 测试）或系统解不了这个文件：交给调用方显示原图。
      return null;
    }
  }
}
