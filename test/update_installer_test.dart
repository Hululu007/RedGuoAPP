import 'package:duanju_app/update_installer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('发布页解析', () {
    test('从 Release 标签页取出仓库与标签', () {
      final ref = releaseRef(
        Uri.parse(
          'https://github.com/Xanerix/guoapp/releases/tag/app-v2.0.2-114',
        ),
      );
      expect(ref, isNotNull);
      expect(ref!.owner, 'Xanerix');
      expect(ref.repo, 'guoapp');
      expect(ref.tag, 'app-v2.0.2-114');
    });

    test('非发布页返回空', () {
      expect(releaseRef(Uri.parse('https://example.com/download')), isNull);
      expect(
        releaseRef(Uri.parse('https://github.com/Xanerix/guoapp')),
        isNull,
      );
      expect(
        releaseRef(Uri.parse('https://github.com/Xanerix/guoapp/releases')),
        isNull,
      );
    });

    test('短版本去掉构建号', () {
      expect(shortVersion('2.0.2+114'), '2.0.2');
      expect(shortVersion('2.0.2'), '2.0.2');
    });
  });

  group('安装包链接', () {
    final base = Uri.parse(
      'https://github.com/Xanerix/guoapp/releases/expanded_assets/app-v2.0.2-114',
    );

    test('按当前架构挑选安装包', () {
      const html = '''
        <a href="/Xanerix/guoapp/releases/download/app-v2.0.2-114/guoapp-2.0.2%2B114-arm64-v8a.apk">arm64</a>
        <a href="/Xanerix/guoapp/releases/download/app-v2.0.2-114/guoapp-2.0.2%2B114-armeabi-v7a.apk">arm</a>
      ''';
      final uri = apkUriIn(html, base: base, abi: 'armeabi-v7a');
      expect(uri, isNotNull);
      expect(uri!.path, endsWith('-armeabi-v7a.apk'));
      expect(uri.host, 'github.com');
    });

    test('只有一个安装包且架构不明时仍然采用', () {
      const html =
          '<a href="/Xanerix/guoapp/releases/download/app-v2.0.2-114/guoapp-2.0.2.apk">apk</a>';
      final uri = apkUriIn(html, base: base, abi: 'arm64-v8a');
      expect(uri, isNotNull);
      expect(uri!.path, endsWith('guoapp-2.0.2.apk'));
    });

    test('多个安装包但没有匹配架构时放弃', () {
      const html = '''
        <a href="/Xanerix/guoapp/releases/download/app-v2.0.2-114/guoapp-2.0.2-arm64-v8a.apk">arm64</a>
        <a href="/Xanerix/guoapp/releases/download/app-v2.0.2-114/guoapp-2.0.2-x86_64.apk">x64</a>
      ''';
      expect(apkUriIn(html, base: base, abi: 'armeabi-v7a'), isNull);
    });

    test('页面里没有安装包时返回空', () {
      expect(apkUriIn('<html></html>', base: base, abi: 'arm64-v8a'), isNull);
    });
  });
}
