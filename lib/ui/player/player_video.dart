import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../playback_engine.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';

class PlayerVideo extends StatelessWidget {
  const PlayerVideo({super.key, required this.player, this.fit = VideoFit.auto});
  final EnginePlayer player;
  final VideoFit fit;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return ColoredBox(
      color: Colors.black,
      child: StreamBuilder<VideoParams>(
        stream: player.stream.videoParams,
        initialData: player.state.videoParams,
        builder: (context, snapshot) => LayoutBuilder(
          builder: (context, constraints) {
            final box = constraints.biggest;
            final source = videoDisplaySize(snapshot.requireData);
            final size = source == null || !box.isFinite || box.isEmpty
                ? box
                : fit.size(box, source, ratio);
            return ClipRect(
              child: OverflowBox(
                minWidth: size.width,
                maxWidth: size.width,
                minHeight: size.height,
                maxHeight: size.height,
                child: const _NativeSurface(),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 原生内核的画面：交给 `guoapp/native_video` 平台视图。
///
/// 视图里那两张 SurfaceView 从创建到销毁一直存在，各自终生绑一个 ExoPlayer；
/// 切集时原生侧只对调它们的 translationX，所以这里不会因为换集而重建。
///
/// 必须用 `PlatformViewLink` + [PlatformViewsService.initExpensiveAndroidView]：
/// 这是唯一强制 Hybrid Composition 的入口（`AndroidView` 默认走 TLHC/虚拟显示，
/// 把平台视图画进纹理，SurfaceView 的独立图层不参与纹理合成，结果就是有声音没画面）。
class _NativeSurface extends StatelessWidget {
  const _NativeSurface();

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.expand();
    return PlatformViewLink(
      viewType: 'guoapp/native_video',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
      onCreatePlatformView: (params) =>
          PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: 'guoapp/native_video',
              layoutDirection: Directionality.of(context),
              creationParams: const <String, Object?>{},
              creationParamsCodec: const StandardMessageCodec(),
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create(),
    );
  }
}
