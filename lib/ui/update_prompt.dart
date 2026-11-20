import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_update.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../update_channel.dart';
import '../update_installer.dart';
import 'app_scope.dart';
import 'widgets/focus_ring.dart';

var _checked = false;
const _manualCooldown = Duration(seconds: 30);
DateTime? _lastManualCheck;
AppUpdate? _lastManualUpdate;

enum _UpdateChoice { mute, skip, dismiss, download }

Future<void> runStartupChecks(BuildContext context, LocalStore store) async {
  if (_checked) return;
  _checked = true;
  final repository = AppScope.of(context).repository;
  final String current;
  final AppUpdate update;
  try {
    current = await currentAppVersion();
    if (!store.checkUpdates) return;
    final latest = await repository.checkUpdate();
    if (latest == null) return;
    if (!await _matchesUpdateSignature(latest)) return;
    update = latest;
  } catch (_) {
    return;
  }
  if (update.version == store.ignoredUpdate || !context.mounted) return;
  final choice = await _askUpdate(context, current, update, manual: false);
  switch (choice) {
    case _UpdateChoice.mute:
      await store.setCheckUpdates(false);
    case _UpdateChoice.skip:
      await store.setIgnoredUpdate(update.version);
    case _UpdateChoice.download:
      if (context.mounted) {
        await _applyUpdate(context, repository, update, store);
      }
    case _UpdateChoice.dismiss || null:
      return;
  }
}

Future<void> checkUpdateManually(BuildContext context, LocalStore store) async {
  final repository = AppScope.of(context).repository;
  final messenger = ScaffoldMessenger.of(context);
  final String current;
  final AppUpdate? update;
  try {
    current = await currentAppVersion();
    final last = _lastManualCheck;
    if (last != null && DateTime.now().difference(last) < _manualCooldown) {
      update = _lastManualUpdate;
    } else {
      update = await repository.checkUpdate();
      _lastManualCheck = DateTime.now();
      _lastManualUpdate = update;
    }
  } catch (failure) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failure is AppFailure ? '检查更新失败：$failure' : '检查更新失败，请稍后再试',
        ),
      ),
    );
    return;
  }
  if (update == null) {
    messenger.showSnackBar(const SnackBar(content: Text('已是最新版本')));
    return;
  }
  if (!await _matchesUpdateSignature(update)) {
    if (context.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('更新签名不匹配，已拒绝此次更新')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  final choice = await _askUpdate(context, current, update, manual: true);
  if (choice == _UpdateChoice.download && context.mounted) {
    await _applyUpdate(context, repository, update, store);
  }
}

Future<_UpdateChoice?> _askUpdate(
  BuildContext context,
  String current,
  AppUpdate update, {
  required bool manual,
}) {
  return showDialog<_UpdateChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 ${update.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            manual
                ? '当前版本 $current。'
                : '当前版本 $current。选「不再提醒」后可在设置 › 关于中重新打开检查更新。',
          ),
          if (update.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: Scrollbar(
                child: SingleChildScrollView(
                  child: SelectableText(
                    update.notes,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        for (final (choice, label) in [
          if (!manual) (_UpdateChoice.mute, '不再提醒'),
          if (!manual) (_UpdateChoice.skip, '忽略此版本'),
          (_UpdateChoice.dismiss, '忽略'),
        ])
          FocusRing(
            radius: 20,
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext, choice),
              child: Text(label),
            ),
          ),
        FocusRing(
          radius: 20,
          child: FilledButton(
            autofocus: true,
            onPressed: () =>
                Navigator.pop(dialogContext, _UpdateChoice.download),
            child: const Text('更新'),
          ),
        ),
      ],
    ),
  );
}

/// Android 在应用内下载并交给系统安装程序，其余平台仍然打开发布页。
Future<void> _applyUpdate(
  BuildContext context,
  AppRepository repository,
  AppUpdate update,
  LocalStore store,
) async {
  if (!Platform.isAndroid) {
    final channel = parseUpdateChannel(store.updateChannel);
    return _openRelease(context, releaseUrlOf(update, channel));
  }
  final channel = parseUpdateChannel(store.updateChannel);
  final file = await showDialog<File>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDownloadDialog(
      repository: repository,
      update: update,
      channel: channel,
    ),
  );
  if (file == null || !context.mounted) return;
  await _installPackage(context, file);
}

Future<bool> _matchesUpdateSignature(AppUpdate update) async {
  if (!Platform.isAndroid) return true;
  try {
    if (update.signingCertSha256.isEmpty) return false;
    final installed = await UpdateDownload.signingCertificateSha256();
    return installed == update.signingCertSha256;
  } catch (_) {
    return false;
  }
}

Future<void> _installPackage(BuildContext context, File file) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final status = await UpdateDownload.install(file.path);
    if (!context.mounted) return;
    switch (status) {
      case 'opened':
        messenger.showSnackBar(
          const SnackBar(content: Text('已交给系统安装程序，按提示完成安装')),
        );
      case 'permission':
        messenger.showSnackBar(
          const SnackBar(content: Text('请在系统设置里允许「红果剧场」安装应用，再点一次更新')),
        );
      default:
        messenger.showSnackBar(
          const SnackBar(content: Text('未能启动安装程序，可改用浏览器下载')),
        );
    }
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error is AppFailure ? error.message : '未能启动安装程序，可改用浏览器下载',
        ),
      ),
    );
  }
}

Future<void> _openRelease(BuildContext context, String url) async {
  final opened = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
  if (opened) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开浏览器，链接已复制')));
  }
}

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({
    required this.repository,
    required this.update,
    required this.channel,
  });

  final AppRepository repository;
  final AppUpdate update;
  final UpdateChannel channel;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  UpdateDownload? _download;
  String _abi = '';
  String _stage = '正在查找安装包';
  String? _error;
  double _progress = 0;
  int _lastPercent = -1;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final proxy = await UpdateDownload.proxyOf(widget.repository);
      final abi = _abi = await UpdateDownload.deviceAbi();
      if (!mounted) return;
      final download = _download = UpdateDownload(
        update: widget.update,
        abi: abi,
        proxy: proxy,
        channel: widget.channel,
      );
      final file = await download.run(
        onProgress: () {
          final percent = (download.progress * 100).floor();
          if (!mounted || percent == _lastPercent) return;
          _lastPercent = percent;
          setState(() {
            _stage = '正在下载安装包';
            _progress = download.progress;
          });
        },
      );
      if (!mounted) return;
      Navigator.pop(context, file);
    } catch (error) {
      if (!mounted) return;
      if (error is UpdateCancelled) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _error = error is AppFailure ? error.message : '下载失败，请稍后重试';
      });
    }
  }

  void _cancel() {
    _download?.cancel();
    Navigator.pop(context);
  }

  Future<void> _fallback() async {
    final url =
        directApkUrlOf(widget.update, _abi, widget.channel) ??
        releaseUrlOf(widget.update, widget.channel);
    Navigator.pop(context);
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!opened) await Clipboard.setData(ClipboardData(text: url));
  }

  @override
  Widget build(BuildContext context) {
    final total = _download?.total ?? 0;
    final received = _download?.received ?? 0;
    return AlertDialog(
      title: Text('更新到 ${widget.update.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error == null) ...[
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 12),
          ],
          Text(_error ?? _stage, style: Theme.of(context).textTheme.bodyMedium),
          if (_error == null && total > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${(received / 1048576).toStringAsFixed(1)} / '
              '${(total / 1048576).toStringAsFixed(1)} MB',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: _error == null
          ? [
              FocusRing(
                radius: 20,
                child: TextButton(onPressed: _cancel, child: const Text('取消')),
              ),
            ]
          : [
              FocusRing(
                radius: 20,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ),
              FocusRing(
                radius: 20,
                child: FilledButton(
                  onPressed: _fallback,
                  child: const Text('用浏览器下载'),
                ),
              ),
            ],
    );
  }
}
