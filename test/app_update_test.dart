import 'package:duanju_app/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

final _sha = 'a' * 64;

Map<String, dynamic> manifest({String tag = 'redguo-v1.0.3-2026112001'}) => {
  'schema': 1,
  'packageName': 'com.x.redguoapp',
  'signingCertSha256': _sha,
  'version': '1.0.3+2026112001',
  'versionCode': 2026112001,
  'versionName': '1.0.3',
  'tag': tag,
  'notes': '修复 TV 端图标耳朵贴边',
  'apks': [
    {
      'abi': 'armeabi-v7a',
      'name': 'RedGuo-1.0.3-v7a.apk',
      'size': 24000000,
      'sha256': _sha,
      'url':
          'https://github.com/xycvip/AppDownload/releases/download/$tag/a.apk',
      'mirrors': [
        'https://gitcode.com/xycvip/redguo/releases/download/$tag/a.apk',
      ],
    },
    {
      'abi': 'arm64-v8a',
      'name': 'RedGuo-1.0.3-v8a.apk',
      'size': 26000000,
      'sha256': _sha,
      'url':
          'https://github.com/xycvip/AppDownload/releases/download/$tag/b.apk',
    },
  ],
};

void main() {
  test('解析双架构清单', () {
    final update = AppUpdate.fromJson(
      manifest(),
      tag: 'redguo-v1.0.3-2026112001',
    );
    expect(update, isNotNull);
    expect(update!.version, '1.0.3');
    expect(update.versionCode, 2026112001);
    expect(update.notes, '修复 TV 端图标耳朵贴边');
    expect(update.apks.length, 2);
  });

  test('标签与发布接口不一致时拒绝', () {
    expect(
      AppUpdate.fromJson(manifest(), tag: 'redguo-v1.0.4-2026112002'),
      isNull,
    );
  });

  test('包名不一致时拒绝', () {
    final data = manifest()..['packageName'] = 'com.example.other';
    expect(AppUpdate.fromJson(data, tag: 'redguo-v1.0.3-2026112001'), isNull);
  });

  test('按架构选出安装包，缺失时退回第一个', () {
    final update = AppUpdate.fromJson(
      manifest(),
      tag: 'redguo-v1.0.3-2026112001',
    )!;
    expect(update.apkFor('arm64-v8a')!.name, 'RedGuo-1.0.3-v8a.apk');
    expect(update.apkFor('armeabi-v7a')!.name, 'RedGuo-1.0.3-v7a.apk');
    expect(update.apkFor('x86_64')!.name, 'RedGuo-1.0.3-v7a.apk');
  });

  test('内部版本号决定是否需要更新', () {
    final update = AppUpdate.fromJson(
      manifest(),
      tag: 'redguo-v1.0.3-2026112001',
    )!;
    expect(update.newerThan(2026111901), isTrue);
    expect(update.newerThan(2026112001), isFalse);
  });

  test('更新说明超长时截断', () {
    final data = manifest()..['notes'] = 'x' * 3000;
    final update = AppUpdate.fromJson(data, tag: 'redguo-v1.0.3-2026112001')!;
    expect(update.notes.length, 2001);
    expect(update.notes, endsWith('…'));
  });

  test('候选地址先主后镜像', () {
    final update = AppUpdate.fromJson(
      manifest(),
      tag: 'redguo-v1.0.3-2026112001',
    )!;
    final apk = update.apkFor('armeabi-v7a')!;
    expect(apk.candidates.first, contains('github.com'));
    expect(apk.candidates.last, contains('gitcode.com'));
  });
}
