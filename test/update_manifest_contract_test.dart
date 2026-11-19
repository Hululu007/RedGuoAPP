import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/app_update.dart';
import 'package:duanju_app/update_channel.dart';

/// 契约测试：夹具由 `.github/workflows/android-release.yml` 的「生成更新清单」
/// 步骤真实产出，服务端改字段会在这里先失败，不用等发版才发现装不上。
void main() {
  final raw = File('test/fixtures/update_release.json').readAsStringSync();
  final data = jsonDecode(raw) as Map<String, dynamic>;
  const tag = 'redguo-v1.0.3-2026112001';

  test('清单能被客户端完整解析', () {
    final update = AppUpdate.fromJson(data, tag: tag);
    expect(update, isNotNull);
    expect(update!.version, '1.0.3');
    expect(update.versionCode, 2026112001);
    expect(update.tag, tag);
    expect(update.notes, contains('新增更新线路选择'));
    expect(update.apks, hasLength(2));
  });

  test('双架构各自取到自己的包', () {
    final update = AppUpdate.fromJson(data, tag: tag)!;
    final arm64 = update.apkFor('arm64-v8a');
    final arm32 = update.apkFor('armeabi-v7a');
    expect(arm64!.name, 'RedGuo-1.0.3-v8a.apk');
    expect(arm32!.name, 'RedGuo-1.0.3-v7a.apk');
    expect(arm64.size, greaterThan(0));
    expect(arm64.sha256, hasLength(64));
  });

  test('候选地址是 GitHub → GitCode → 代理', () {
    final update = AppUpdate.fromJson(data, tag: tag)!;
    final urls = update.apkFor('arm64-v8a')!.candidates;
    expect(urls.first, contains('github.com/xycvip/AppDownload'));
    expect(urls[1], contains('gitcode.com/xycvip/redguo'));
    expect(
      urls
          .skip(2)
          .every(
            (url) => url.contains('gh-proxy.com') || url.contains('ghfast.top'),
          ),
      isTrue,
      reason: '镜像必须是已知加速前缀，实际：${urls.skip(2).toList()}',
    );
  });

  test('清单标签与发布接口不一致时拒绝', () {
    expect(AppUpdate.fromJson(data, tag: 'redguo-v9.9.9-2099010100'), isNull);
  });

  test('GitCode 接口响应能定位到 update.json 附件', () {
    final release =
        jsonDecode(
              File('test/fixtures/gitcode_release.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final url = manifestAssetUrl(release);
    expect(url, isNotNull);
    // 源码包（type=source）不能被当成清单。
    expect(url, contains('/releases/download/'));
    expect(url, endsWith('/update.json'));
  });

  test('包名不匹配时拒绝', () {
    final other = Map<String, dynamic>.from(data)
      ..['packageName'] = 'com.x.other';
    expect(AppUpdate.fromJson(other, tag: tag), isNull);
  });
}
