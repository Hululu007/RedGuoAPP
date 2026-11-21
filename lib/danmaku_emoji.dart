import 'package:flutter/widgets.dart';

/// 平台弹幕代码 → Unicode emoji。
///
/// 渲染走系统自带的彩色 emoji 字体（Android 的 Noto Color Emoji），不占任何
/// APK 资源——原来的 50 张内置 PNG 已移除。未收录的代码原样保留，不会丢内容。
const Map<String, String> danmakuEmojiTable = {
  // 原内置 PNG 对应的码点，显示效果与之前一致
  '爽': '😌',
  '偷笑': '🤭',
  '没看够': '🥺',
  '笑': '😄',
  '笑哭': '😂',
  '尬笑': '😅',
  '奸笑': '😼',
  '捂脸': '🤦',
  '爱慕': '😍',
  '飞吻': '😘',
  '鼓掌': '👏',
  '赞': '👍',
  '送花': '💐',
  '震惊': '😱',
  '思考': '🤔',
  '抓狂': '😩',
  '怒': '😠',
  '害羞': '😊',
  '哭': '😢',
  '快哭了': '🥹',
  '求爆更': '🙏',
  'OK': '👌',
  '什么': '❓',
  '流泪': '😭',
  '大笑': '😆',
  '微笑': '🙂',
  '坏笑': '😈',
  '白眼': '🙄',
  '疑问': '❔',
  '闭嘴': '🤐',
  '色': '😛',
  '调皮': '😜',
  '难过': '😔',
  '馋': '🤤',
  '晕': '😵',
  '流汗': '😓',
  '生病': '🤒',
  '睡着': '😴',
  '狗头': '🐶',
  '比心': '🤟',
  '火': '🔥',
  '加油': '💪',
  '抱抱': '🤗',
  '吃瓜': '🍉',
  '无语': '😐',
  '666': '👌',
  '爱心': '❤️',
  '拳头': '👊',
  '狂笑': '🤣',
  '惊喜': '🤩',
  // 线上弹幕流量里出现、上表没覆盖的代码
  'doge': '🐶',
  '灵光一闪': '💡',
  '滑稽': '🤪',
  '看': '👀',
  'what': '😲',
  '星星眼': '🤩',
  '打脸': '🤚',
  '憨笑': '😁',
  '呲牙': '😁',
  '酷拽': '😎',
  '黑脸': '🌚',
  '得意': '😌',
  '小鼓掌': '👏',
  '酷': '😎',
  '生气': '😠',
  '发怒': '😡',
  '咒骂': '🤬',
  '泣不成声': '😭',
  '泪奔': '😭',
  '大哭': '😭',
  '困': '😪',
  '衰': '😩',
  '擦汗': '😓',
  '抠鼻': '😤',
  '惊讶': '😮',
  '耶': '✌️',
  '鲜花': '🌹',
  '玫瑰': '🌹',
  '胜利': '✌️',
  '厉害': '👍',
  '叹气': '😮‍💨',
  '柠檬': '🍋',
  '尴尬': '😅',
  '绝望': '😩',
  '暗中观察': '🕵️',
  '心碎': '💔',
  '礼物': '🎁',
  '可爱': '🥰',
  '拜托': '🙏',
  '厉害了我的哥': '😲',
  '盯': '👀',
};

/// emoji → 代码名，用于把段落还原回「[代码]」纯文本（复制、日志用）。
/// 不同代码可能映射同一个 emoji（如「赞」「厉害」都是 👍），保留先出现的那个。
final Map<String, String> _emojiNames = () {
  final reversed = <String, String>{};
  for (final entry in danmakuEmojiTable.entries) {
    reversed.putIfAbsent(entry.value, () => entry.key);
  }
  return reversed;
}();

final RegExp danmakuEmojiPattern = RegExp(r'\[([^\[\]\s]{1,8})\]');

class DanmakuSegment {
  const DanmakuSegment.text(this.text) : emoji = null;
  const DanmakuSegment.emoji(this.emoji) : text = null;

  final String? text;
  final String? emoji;

  bool get isEmoji => emoji != null;

  @override
  bool operator ==(Object other) =>
      other is DanmakuSegment && other.text == text && other.emoji == emoji;

  @override
  int get hashCode => Object.hash(text, emoji);

  @override
  String toString() => isEmoji ? 'emoji($emoji)' : 'text($text)';
}

String? danmakuEmojiFor(String name) => danmakuEmojiTable[name];

bool hasDanmakuEmoji(String text) {
  for (final match in danmakuEmojiPattern.allMatches(text)) {
    if (danmakuEmojiTable.containsKey(match.group(1))) return true;
  }
  return false;
}

List<DanmakuSegment> parseDanmakuSegments(String text) {
  if (text.isEmpty) return const [];
  final segments = <DanmakuSegment>[];
  var cursor = 0;
  for (final match in danmakuEmojiPattern.allMatches(text)) {
    final emoji = danmakuEmojiTable[match.group(1)!];
    if (emoji == null) continue;
    if (match.start > cursor) {
      segments.add(DanmakuSegment.text(text.substring(cursor, match.start)));
    }
    segments.add(DanmakuSegment.emoji(emoji));
    cursor = match.end;
  }
  if (cursor < text.length) {
    segments.add(DanmakuSegment.text(text.substring(cursor)));
  }
  return segments.isEmpty ? [DanmakuSegment.text(text)] : segments;
}

List<DanmakuSegment> truncateDanmakuSegments(
  List<DanmakuSegment> segments,
  int maxRunes,
) {
  if (maxRunes <= 0) return const [];
  final kept = <DanmakuSegment>[];
  var used = 0;
  var truncated = false;
  for (final segment in segments) {
    if (used >= maxRunes) {
      truncated = true;
      break;
    }
    final text = segment.text;
    if (text == null) {
      kept.add(segment);
      used++;
      continue;
    }
    final runes = text.runes.toList();
    final room = maxRunes - used;
    if (runes.length <= room) {
      kept.add(segment);
      used += runes.length;
      continue;
    }
    kept.add(DanmakuSegment.text(String.fromCharCodes(runes.take(room))));
    used = maxRunes;
    truncated = true;
    break;
  }
  if (truncated) {
    final last = kept.isEmpty ? null : kept.last;
    if (last != null && last.text != null) {
      kept[kept.length - 1] = DanmakuSegment.text('${last.text}…');
    } else {
      kept.add(const DanmakuSegment.text('…'));
    }
  }
  return kept;
}

/// emoji 已经是普通文本，测量不再需要占位符：直接拼出富文本排一遍。
double measureDanmakuSegments(
  List<DanmakuSegment> segments,
  TextStyle style, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final spans = <InlineSpan>[];
  for (final segment in segments) {
    final text = segment.text ?? segment.emoji;
    if (text == null || text.isEmpty) continue;
    spans.add(TextSpan(text: text, style: style));
  }
  if (spans.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(style: style, children: spans),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  );
  painter.layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

String danmakuSegmentsText(List<DanmakuSegment> segments) {
  final buffer = StringBuffer();
  for (final segment in segments) {
    final text = segment.text;
    if (text != null) {
      buffer.write(text);
      continue;
    }
    final name = _emojiNames[segment.emoji];
    buffer.write(name != null ? '[$name]' : segment.emoji!);
  }
  return buffer.toString();
}
