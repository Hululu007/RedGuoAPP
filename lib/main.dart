import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_device.dart';
import 'core_bridge.dart';
import 'diary_service.dart';
import 'local_files.dart';
import 'local_store.dart';
import 'ui/app.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  final device = await AppDevice.detect();
  final rendering =
      ', 渲染: ${await AppDevice.compatibleRendering() ? 'skia' : 'impeller'}';
  DiaryService.add(
    '[App] 应用启动，版本: ${device.version}, '
    '平台: ${Platform.operatingSystem}$rendering',
  );
  runApp(AppBootstrap(device: device));
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.device = const AppDevice()});
  final AppDevice device;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  LocalStore? store;
  Object? error;
  late AppDevice device = widget.device;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    DiaryService.add('[App] 生命周期：${state.name}');
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshDevice());
    }
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: device);
    if (!mounted ||
        (device.television == detected.television &&
            device.version == detected.version)) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _initialize() async {
    setState(() => error = null);
    try {
      final preferences = await SharedPreferences.getInstance();
      await _refreshDevice();
      await repository.initialize();
      final support = await getApplicationSupportDirectory();
      final local = await LocalStore.open(
        preferences,
        LocalFiles(Directory(path.join(support.path, 'store'))),
      );
      // 手机端一次性把播放手势/样式偏好翻新成新版默认（竖屏样式开、上下滑
      // 切集开、亮度/音量滑动关）。电视设备与手动切到电视界面的不动。
      if (!device.television && local.displayMode != 'television') {
        try {
          await local.upgradePhonePlaybackDefaults();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        store = local;
        repository.access = local;
      });
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    }
  }

  @override
  Widget build(BuildContext context) => DuanjuApp(
    repository: repository,
    store: store,
    bootstrapError: error?.toString(),
    onRetry: _initialize,
    television: device.television,
    version: device.version,
  );
}
