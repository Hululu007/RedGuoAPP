import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/focus_ring.dart';

enum AboutNoticeSection { statement, license, components }

class AboutNoticeView extends StatefulWidget {
  const AboutNoticeView({super.key, required this.section});

  final AboutNoticeSection section;

  @override
  State<AboutNoticeView> createState() => _AboutNoticeViewState();
}

class _AboutNoticeViewState extends State<AboutNoticeView> {
  final _scroll = ScrollController();
  var _focused = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(KeyEvent event) {
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -120.0,
      LogicalKeyboardKey.arrowDown => 120.0,
      _ => null,
    };
    if (event is KeyUpEvent || step == null || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final position = _scroll.position;
    if (step < 0 && position.pixels <= 0) return KeyEventResult.ignored;
    _scroll.animateTo(
      (position.pixels + step).clamp(0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (_, event) => _onKey(event),
        child: Material(
          color: colors.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: focusVisible(_focused)
                ? BorderSide(color: colors.onSurface, width: 2)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: SelectionArea(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 26),
              children: switch (widget.section) {
                AboutNoticeSection.statement => _statementContent(context),
                AboutNoticeSection.license => _licenseContent(context),
                AboutNoticeSection.components => _componentsContent(context),
              },
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _statementContent(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.8);
    final number = theme.textTheme.labelMedium?.copyWith(
      color: colors.primary,
      fontWeight: FontWeight.w700,
      letterSpacing: .5,
    );
    return [
      for (final (index, text) in _statement.indexed) ...[
        if (index > 0) const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('${index + 1}'.padLeft(2, '0'), style: number),
              ),
            ),
            Expanded(child: Text(text, style: body)),
          ],
        ),
      ],
    ];
  }

  List<Widget> _licenseContent(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.8);
    return [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: .42),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(_license, style: body),
      ),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.description_outlined,
            size: 16,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '完整的许可证文本见仓库根目录的 LICENSE 文件。',
              style: body?.copyWith(
                fontSize: (body.fontSize ?? 14) - 1,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _componentsContent(BuildContext context) {
    final total = _componentGroups.fold<int>(
      0,
      (sum, group) => sum + group.$2.length,
    );
    return [
      Text(
        '本应用使用以下 $total 个开源组件，各组件的许可证以其源码仓库与随附的许可文件为准。',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          height: 1.7,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      for (final (title, items) in _componentGroups) ...[
        const SizedBox(height: 22),
        _GroupHeader(title),
        const SizedBox(height: 2),
        for (final (index, item) in items.indexed)
          _ComponentRow(
            name: item.$1,
            license: item.$2,
            role: item.$3,
            divider: index != items.length - 1,
          ),
      ],
    ];
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: colors.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: .5,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Divider(
            height: 1,
            thickness: 1,
            color: colors.outlineVariant.withValues(alpha: .35),
          ),
        ),
      ],
    );
  }
}

class _ComponentRow extends StatelessWidget {
  const _ComponentRow({
    required this.name,
    required this.license,
    required this.role,
    required this.divider,
  });

  final String name;
  final String license;
  final String role;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: body?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _LicenseChip(license),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 1),
                child: Text(
                  role,
                  style: body?.copyWith(
                    fontSize: (body.fontSize ?? 14) - 1.5,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (divider)
          Divider(
            height: 1,
            thickness: 1,
            color: colors.outlineVariant.withValues(alpha: .28),
          ),
      ],
    );
  }
}

class _LicenseChip extends StatelessWidget {
  const _LicenseChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: colors.onSecondaryContainer,
          fontWeight: FontWeight.w600,
          letterSpacing: .2,
          height: 1.35,
        ),
      ),
    );
  }
}

const _statement = [
  '本应用是开源软件，框架与模块商店中的站源模块代码公开，仅供个人学习与技术研究，不收费，不提供任何付费服务。',
  '本应用与各站源的运营方无任何关联，未获得其授权或认可；文中提到的名称和商标归各自权利人所有。',
  '本应用本身不存储、不上传、不分发任何影视内容，所有内容均来自第三方站点，版权归原权利人所有；应用不解除源站 VIP 或其他授权限制。',
  '通过本应用观看的内容仅供试看和个人学习交流，请勿用于商业用途；如喜欢相关作品，请支持正版。',
  '站源内容（包括其中的广告、链接、二维码、联系方式等）均由第三方提供，请自行鉴别真伪，切勿轻信其中的充值、投资、博彩、兼职等信息；由此造成的任何财产损失，作者不承担任何责任。',
  '使用者应遵守所在地法律法规及各站点的服务条款，不得将本应用用于违法或商业用途；因使用本应用产生的一切后果由使用者自行承担。',
  '本应用按「现状」提供，不对可用性、稳定性或适用性作任何保证，作者不承担由此造成的任何直接或间接损失。',
  '观看记录、追剧和偏好设置只保存在本设备，不发送任何统计数据。',
];

const _license =
    '本软件由上游作者 Xanerix 基于原作者 fish2018 的开源项目重建后改编，遵循 GNU General Public License v3.0（GPL-3.0）发布：你可以自由使用、学习、修改和再分发，再分发时须同样以 GPL-3.0 开源并保留版权声明。';

/// 组件清单：分组名 → [(组件名, 许可证, 用途)]
const List<(String, List<(String, String, String)>)> _componentGroups = [
  (
    '框架与原生核心',
    [
      ('Flutter', 'BSD-3-Clause', '应用框架、渲染引擎与本地化'),
      ('Go 标准库', 'BSD-3-Clause', '原生核心、本地流服务与模块运行时'),
      ('goja / tls-client / fhttp', 'MIT', '站源脚本引擎、TLS 指纹请求'),
      ('golang.org/x', 'BSD-3-Clause', '网络、系统调用与文本处理'),
      ('ffi', 'BSD-3-Clause', 'Dart 与 Go 原生核心的绑定'),
    ],
  ),
  (
    '播放内核',
    [
      ('ExoPlayer（Media3）', 'Apache-2.0', '视频解码与渲染内核'),
    ],
  ),
  (
    '平台与插件',
    [
      ('AndroidX / Jetpack', 'Apache-2.0', 'Android 平台基础库'),
      ('shared_preferences', 'BSD-3-Clause', '键值设置存储'),
      ('path / path_provider', 'BSD-3-Clause', '路径与目录访问'),
      ('file_picker', 'MIT', '文件选择'),
    ],
  ),
  (
    '界面与工具',
    [
      ('dynamic_color', 'Apache-2.0', '跟随系统取色'),
      ('package_info_plus', 'BSD-3-Clause', '读取版本信息'),
      ('crypto', 'BSD-3-Clause', '哈希校验'),
      ('url_launcher', 'BSD-3-Clause', '打开外部链接'),
      ('lpinyin', 'BSD-2-Clause', '拼音检索'),
    ],
  ),
];
