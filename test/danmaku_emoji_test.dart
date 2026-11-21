import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/danmaku_emoji.dart';

void main() {
  group('parseDanmakuSegments', () {
    test('已知代码被替换为 Unicode emoji', () {
      final segments = parseDanmakuSegments('道友们，你们爱的皇篇，又更新了[爽][爽][爽]');
      expect(segments, hasLength(4));
      expect(segments[0].text, '道友们，你们爱的皇篇，又更新了');
      expect(segments[1].emoji, danmakuEmojiTable['爽']);
      expect(danmakuSegmentsText(segments), '道友们，你们爱的皇篇，又更新了[爽][爽][爽]');
    });

    test('未知代码原样保留', () {
      final segments = parseDanmakuSegments('这是[未知词]不是表情');
      expect(segments, hasLength(1));
      expect(segments.single.text, '这是[未知词]不是表情');
      expect(danmakuSegmentsText(segments), '这是[未知词]不是表情');
    });

    test('hasDanmakuEmoji 只认收录的代码', () {
      expect(hasDanmakuEmoji('普通弹幕'), isFalse);
      expect(hasDanmakuEmoji('好[赞]'), isTrue);
      expect(hasDanmakuEmoji('好[未知词]'), isFalse);
    });
  });

  group('truncateDanmakuSegments', () {
    test('按 rune 数截断并补省略号', () {
      final segments = parseDanmakuSegments('a[赞]b[赞]c');
      final truncated = truncateDanmakuSegments(segments, 3);
      expect(danmakuSegmentsText(truncated), 'a[赞]b…');
    });

    test('长度足够时不截断', () {
      final segments = parseDanmakuSegments('abc');
      expect(danmakuSegmentsText(truncateDanmakuSegments(segments, 10)), 'abc');
    });
  });

  test('空文本没有段落', () {
    expect(parseDanmakuSegments(''), isEmpty);
  });

  group('measureDanmakuSegments', () {
    test('带 emoji 的宽度大于纯文本', () {
      final style = TextStyle(fontSize: 16);
      final textOnly = measureDanmakuSegments(
        parseDanmakuSegments('普通弹幕'),
        style,
      );
      final withEmoji = measureDanmakuSegments(
        parseDanmakuSegments('普通[赞]弹幕'),
        style,
      );
      expect(withEmoji, greaterThan(textOnly));
    });
  });

  test('映射表没有空值，emoji 可还原回其中一个代码名', () {
    expect(danmakuEmojiTable.values, everyElement(isNotEmpty));
    // 不同代码可能共用同一个 emoji（如「赞」「厉害」都是 👍），反查保留先出现的。
    final firstName = <String, String>{};
    for (final entry in danmakuEmojiTable.entries) {
      firstName.putIfAbsent(entry.value, () => entry.key);
    }
    for (final entry in danmakuEmojiTable.entries) {
      expect(
        danmakuSegmentsText([DanmakuSegment.emoji(entry.value)]),
        '[${firstName[entry.value]}]',
      );
    }
  });
}
