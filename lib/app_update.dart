import 'package:package_info_plus/package_info_plus.dart';

/// 安装包标识：包名与发布仓库，客户端所有地址都由它们推导。
const updatePackageName = 'com.x.redguoapp';
const updateGitHubRepo = 'xycvip/AppDownload';
const updateGitCodeRepo = 'xycvip/redguo';
const updateTagPrefix = 'redguo-';

/// 更新清单里单个处理器的安装包。
class AppUpdateApk {
  const AppUpdateApk({
    required this.abi,
    required this.name,
    required this.size,
    required this.sha256,
    required this.url,
    this.mirrors = const [],
  });

  final String abi;
  final String name;
  final int size;
  final String sha256;
  final String url;
  final List<String> mirrors;

  /// 清单里的候选地址：主地址在前，镜像在后。
  List<String> get candidates => [
    for (final item in [url, ...mirrors])
      if (item.isNotEmpty) item,
  ];

  static AppUpdateApk? fromJson(Object? data) {
    if (data is! Map) return null;
    final abi = data['abi'];
    final url = data['url'];
    if (abi is! String || abi.isEmpty || url is! String || url.isEmpty) {
      return null;
    }
    final name = data['name'];
    return AppUpdateApk(
      abi: abi,
      name: name is String && name.isNotEmpty
          ? name
          : Uri.parse(url).pathSegments.last,
      size: _intValue(data['size']),
      sha256: (data['sha256'] as String? ?? '').toLowerCase(),
      url: url,
      mirrors: [
        for (final item in data['mirrors'] as List? ?? const [])
          if (item is String && item.isNotEmpty) item,
      ],
    );
  }
}

class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.versionCode,
    required this.tag,
    required this.url,
    required this.signingCertSha256,
    this.notes = '',
    this.apks = const [],
  });

  /// 对外显示的版本名，如 1.0.3。
  final String version;
  final int versionCode;
  final String tag;

  /// 发布页地址，仅用于「用浏览器打开」。
  final String url;
  /// 正式发布 APK 的签名证书 SHA-256（64 位十六进制）。
  final String signingCertSha256;
  final String notes;
  final List<AppUpdateApk> apks;

  bool newerThan(int installed) => versionCode > installed;

  /// 按设备架构取安装包，清单缺少对应架构时退回第一个。
  AppUpdateApk? apkFor(String abi) {
    if (apks.isEmpty) return null;
    for (final apk in apks) {
      if (apk.abi == abi) return apk;
    }
    return apks.first;
  }

  /// 解析 update.json；标签必须与发布接口返回的一致，避免拿到别人的清单。
  static AppUpdate? fromJson(Map<String, dynamic> data, {required String tag}) {
    final schema = _intValue(data['schema']);
    if (schema != 0 && schema != 1) return null;
    final package = data['packageName'];
    if (package is String &&
        package.isNotEmpty &&
        package != updatePackageName) {
      return null;
    }
    // 从发布接口拿到 tag 时以它为准；直接读仓库清单时用清单里自带的 tag。
    final manifestTag = data['tag'];
    final effectiveTag = tag.isNotEmpty
        ? tag
        : (manifestTag is String ? manifestTag.trim() : '');
    if (effectiveTag.isEmpty) return null;
    if (tag.isNotEmpty &&
        manifestTag is String &&
        manifestTag.isNotEmpty &&
        manifestTag != tag) {
      return null;
    }

    final cert = data['signingCertSha256'];
    if (cert is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}
      for (final item in items) {
        final apk = AppUpdateApk.fromJson(item);
        if (apk != null) apks.add(apk);
      }
    }
    if (apks.isEmpty) {
      // 兼容只写单个 apk 的旧清单。
      final single = AppUpdateApk.fromJson(data['apk']);
      if (single != null) apks.add(single);
    }
    if (apks.isEmpty) return null;

    final versionName = (data['versionName'] as String? ?? '').trim();
    final version = (data['version'] as String? ?? '').trim();
    final name = versionName.isNotEmpty
        ? versionName
        : version.split('+').first;
    var code = _intValue(data['versionCode']);
    if (code <= 0 && version.contains('+')) {
      code = int.tryParse(version.split('+').last) ?? 0;
    }
    if (code <= 0) return null;

    return AppUpdate(
      version: name,
      versionCode: code,
      tag: effectiveTag,
      url: 'https://github.com/$updateGitHubRepo/releases/tag/$effectiveTag',
      signingCertSha256: cert.trim().toLowerCase(),
      notes: _clip(data['notes'] as String? ?? ''),
      apks: apks,
    );
  }

  /// 更新说明只留摘要，太长会拖慢弹窗。
  static String _clip(String text) {
    final trimmed = text.trim();
    return trimmed.length <= 2000 ? trimmed : '${trimmed.substring(0, 2000)}…';
  }
}

/// 当前安装的版本名，用于界面展示。
Future<String> currentAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
}

/// 当前安装的内部版本号，用于判断是否需要更新。
Future<int> currentVersionCode() async {
  final info = await PackageInfo.fromPlatform();
  return int.tryParse(info.buildNumber.trim()) ?? 0;
}

int _intValue(Object? value) => switch (value) {
  final int number => number,
  final double number => number.toInt(),
  final String text => int.tryParse(text.trim()) ?? 0,
  _ => 0,
};
).hasMatch(cert.trim())) {
      return null;
    }

    final apks = <AppUpdateApk>[];
    if (data['apks'] case final List items) {
      for (final item in items) {
        final apk = AppUpdateApk.fromJson(item);
        if (apk != null) apks.add(apk);
      }
    }
    if (apks.isEmpty) {
      // 兼容只写单个 apk 的旧清单。
      final single = AppUpdateApk.fromJson(data['apk']);
      if (single != null) apks.add(single);
    }
    if (apks.isEmpty) return null;

    final versionName = (data['versionName'] as String? ?? '').trim();
    final version = (data['version'] as String? ?? '').trim();
    final name = versionName.isNotEmpty
        ? versionName
        : version.split('+').first;
    var code = _intValue(data['versionCode']);
    if (code <= 0 && version.contains('+')) {
      code = int.tryParse(version.split('+').last) ?? 0;
    }
    if (code <= 0) return null;

    return AppUpdate(
      version: name,
      versionCode: code,
      tag: effectiveTag,
      url: 'https://github.com/$updateGitHubRepo/releases/tag/$effectiveTag',
      notes: _clip(data['notes'] as String? ?? ''),
      apks: apks,
    );
  }

  /// 更新说明只留摘要，太长会拖慢弹窗。
  static String _clip(String text) {
    final trimmed = text.trim();
    return trimmed.length <= 2000 ? trimmed : '${trimmed.substring(0, 2000)}…';
  }
}

/// 当前安装的版本名，用于界面展示。
Future<String> currentAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
}

/// 当前安装的内部版本号，用于判断是否需要更新。
Future<int> currentVersionCode() async {
  final info = await PackageInfo.fromPlatform();
  return int.tryParse(info.buildNumber.trim()) ?? 0;
}

int _intValue(Object? value) => switch (value) {
  final int number => number,
  final double number => number.toInt(),
  final String text => int.tryParse(text.trim()) ?? 0,
  _ => 0,
};
