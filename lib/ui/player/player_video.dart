import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import '../../playback_engine.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';
import 'playback_handle.dart';

class PlayerVideo extends StatelessWidget {
  const PlayerVideo({
    super.key,
    required this.handle,
    required this.player,
    this.fit = VideoFit.auto,
  });
  final PlaybackHandle handle;
  final EnginePlayer player;
  final VideoFit fit;

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        children: [
          StreamBuilder<VideoParams>(
            stream: player.stream.videoParams,
            initialData: player.state.videoParams,
            builder: (context, snapshot) => LayoutBuilder(
              builder: (context, constraints) {
                final box = constraints.biggest;
                final source = videoDisplaySize(snapshot.requireData);
                final size = source == null || !box.isFinite || box.isEmpty
                    ? box
                    : fit.size(box, source, ratio);
                final sized = ClipRect(
                  child: OverflowBox(
                    minWidth: size.width,
                    maxWidth: size.width,
                    minHeight: size.height,
                    maxHeight: size.height,
                    child: _Surface(player: player),
                  ),
                );
                final output = size * ratio;
                if (!player.isMpv ||
                    !Platform.isWindows ||
                    !output.isFinite ||
                    output.isEmpty) {
                  return sized;
                }
                return _OutputSize(
                  controller: player.mpvVideo,
                  box: output,
                  child: sized,
                );
              },
            ),
          ),
          // 预热那一路的平台视图。
          //
          // 平台视图模式下解码器必须拿到真实的画面表面才会真正开始解码，只建解码器
          // 实例不算预热。这里把它渲染成零尺寸——原生侧照样创建视图并绑定表面，
          // Flutter 侧不显示任何内容。切集时这一路已经有解码好的画面等着，直接顶上。
          _StandbySurface(handle: handle),
        ],
      ),
    );
  }
}

/// 预热那一路的平台视图。
///
/// 渲染成零尺寸：原生侧照样创建视图并把解码器绑到真实表面上，解码器因此能真正开始
/// 工作；Flutter 侧不显示任何内容，不会影响当前这一集的画面。
class _StandbySurface extends StatelessWidget {
  const _StandbySurface({required this.handle});

  final PlaybackHandle handle;

  @override
  Widget build(BuildContext context) {
    // 预热状态变化（开始预热、预热完成、切集）都要重新构建，这里跟着会话一起听。
    return ListenableBuilder(
      listenable: handle.session,
      builder: (context, _) {
        final controller = handle.session.standbyExoVideo;
        if (controller == null || !controller.value.isInitialized) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          width: 1,
          height: 1,
          // 完全透明：这一路只是让原生侧把解码器绑到真实表面上，画面不显示。
          child: Opacity(opacity: 0, child: VideoPlayer(controller)),
        );
      },
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.player});

  final EnginePlayer player;

  @override
  Widget build(BuildContext context) {
    final controller = player.exoVideo;
    if (controller != null && controller.value.isInitialized) {
      // 内核用 VideoViewType.platformView 创建，主包的 VideoPlayer widget 会按播放器状态
      // 分发到插件的 PlatformViewPlayer（PlatformViewLink + AndroidViewSurface，
      // Hybrid Composition），保留 SurfaceView 的独立 Surface 与零拷贝。
      //
      // 插件在分发时给 PlatformViewPlayer 加了带 playerId 的 key，切集时平台视图会重建，
      // 原生侧才会把新解码器绑到 Surface 上（否则复用的视图里还留着旧播放器，只剩黑屏）。
      return VideoPlayer(controller);
    }
    if (player.isMpv) {
      return Video(
        controller: player.mpvVideo,
        controls: NoVideoControls,
        fill: Colors.black,
        fit: BoxFit.fill,
        pauseUponEnteringBackgroundMode: false,
      );
    }
    return const SizedBox.expand();
  }
}

class _OutputSize extends StatefulWidget {
  const _OutputSize({
    required this.controller,
    required this.box,
    required this.child,
  });
  final VideoController controller;
  final Size box;
  final Widget child;

  @override
  State<_OutputSize> createState() => _OutputSizeState();
}

class _OutputSizeState extends State<_OutputSize> {
  @override
  void initState() {
    super.initState();
    _VideoOutput.request(widget.controller, this, widget.box);
  }

  @override
  void didUpdateWidget(_OutputSize oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _VideoOutput.release(oldWidget.controller, this);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.box != widget.box) {
      _VideoOutput.request(widget.controller, this, widget.box);
    }
  }

  @override
  void dispose() {
    _VideoOutput.release(widget.controller, this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _VideoOutput {
  _VideoOutput(this.controller) {
    _subscription = controller.player.stream.videoParams.listen(
      (_) => _schedule(),
    );
  }

  static final _outputs = <VideoController, _VideoOutput>{};

  static void request(VideoController controller, Object owner, Size box) {
    final output = _outputs[controller] ??= _VideoOutput(controller);
    output._boxes[owner] = box;
    output._schedule();
  }

  static void release(VideoController controller, Object owner) {
    final output = _outputs[controller];
    if (output == null) return;
    output._boxes.remove(owner);
    if (output._boxes.isNotEmpty) return;
    output._timer?.cancel();
    unawaited(output._subscription.cancel());
    _outputs.remove(controller);
  }

  final VideoController controller;
  final _boxes = <Object, Size>{};
  late final StreamSubscription<VideoParams> _subscription;
  Timer? _timer;

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), _apply);
  }

  void _apply() {
    final params = controller.player.state.videoParams;
    final width = params.dw ?? params.w ?? 0;
    final height = params.dh ?? params.h ?? 0;
    if (width <= 0 || height <= 0 || _boxes.isEmpty) return;
    final scale = math.min(
      1.0,
      _boxes.values
          .map((box) => math.max(box.width / width, box.height / height))
          .reduce(math.max),
    );
    unawaited(
      controller
          .setSize(
            width: math.max(1, (width * scale).round()),
            height: math.max(1, (height * scale).round()),
          )
          .catchError((Object _) {}),
    );
  }
}
