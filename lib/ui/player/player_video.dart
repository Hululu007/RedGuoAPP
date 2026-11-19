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
