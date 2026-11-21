import 'dart:async';
import 'dart:io' show Platform;

import 'playback_native.dart';
import 'playback_preferences.dart';
import 'video_params.dart';

export 'video_params.dart';

/// 底层播放内核的统一契约。
///
/// 现在只有原生双实例（[NativePlayerCore]，Kotlin 侧常驻两个 ExoPlayer）
/// 一个实现；测试用替身实现本接口即可。
abstract class PlaybackBackend {
  EngineState get state;
  EngineStreams get stream;

  Future<void> open(
    String url, {
    required Map<String, String> headers,
    required Duration? start,
    required bool play,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> setRate(double value);
  Future<void> setVolume(double value);
  Future<void> applyDecoder(TelevisionDecoder decoder);
  Future<void> dispose();
}

/// 统一的播放内核外观。UI 与会话层只面向本类，不关心底下是哪个内核。
class EnginePlayer {
  EnginePlayer._native()
    : _backend = NativePlayerCore(),
      kernel = PlaybackKernel.native;

  /// 包装任意内核实现（测试替身或自定义场景）。
  EnginePlayer.wrap(PlaybackBackend backend)
    : _backend = backend,
      kernel = PlaybackKernel.native;

  factory EnginePlayer.open() {
    if (Platform.isAndroid) return EnginePlayer._native();
    // 原生内核只在 Android 上实现。其他平台没有可用的播放后端，
    // 用一个什么都不做的替身占位，避免空指针。
    return EnginePlayer.wrap(const _EmptyBackend());
  }

  final PlaybackBackend _backend;
  final PlaybackKernel kernel;

  /// 当前内核实例，测试用来断言实例是否被互换。
  PlaybackBackend get backend => _backend;

  bool get isNative => _backend is NativePlayerCore;

  EngineState get state => _backend.state;
  EngineStreams get stream => _backend.stream;

  Future<void> open(
    String url, {
    Map<String, String> headers = const {},
    Duration? start,
    required bool play,
  }) => _backend.open(url, headers: headers, start: start, play: play);

  Future<void> play() => _backend.play();
  Future<void> pause() => _backend.pause();
  Future<void> playOrPause() => _backend.playOrPause();
  Future<void> seek(Duration position) => _backend.seek(position);
  Future<void> stop() => _backend.stop();
  Future<void> setRate(double value) => _backend.setRate(value);
  Future<void> setVolume(double value) => _backend.setVolume(value);

  Future<void> applyDecoder(TelevisionDecoder decoder) =>
      _backend.applyDecoder(decoder);

  /// 预热下一集（仅原生内核）：只 prepare，不播，占用另一路常驻 Surface。
  /// 原生侧就绪/失败才回执；非原生内核恒返回 false。
  Future<bool> preload(
    String url, {
    Map<String, String> headers = const {},
    Duration? start,
  }) async {
    final backend = _backend;
    if (backend is NativePlayerCore) {
      return await backend.preload(url, headers: headers, start: start);
    }
    return false;
  }

  /// 已下载字节数，用于估算下载速率。只有原生内核提供。
  Future<int?> bytesRead() async {
    final backend = _backend;
    return backend is NativePlayerCore ? await backend.bytesRead() : null;
  }

  /// 切到预热好的实例（仅原生内核）。false 表示没有可切的实例。
  Future<bool> swapToStandby() async {
    final backend = _backend;
    return backend is NativePlayerCore ? await backend.swap() : false;
  }

  Future<void> dispose() => _backend.dispose();
}

/// 内核无关的播放状态快照。
class EngineState {
  const EngineState({
    required this.position,
    required this.duration,
    this.buffer = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.rate = 1,
    this.volume = 1,
    this.width,
    this.height,
    VideoParams? videoParams,
  }) : videoParams = videoParams ?? const VideoParams();

  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool playing;
  final bool buffering;
  final bool completed;
  final double rate;
  final double volume;
  final double? width;
  final double? height;
  final VideoParams videoParams;

  EngineState copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffer,
    bool? playing,
    bool? buffering,
    bool? completed,
    double? rate,
    double? volume,
    double? width,
    double? height,
    VideoParams? videoParams,
  }) => EngineState(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffer: buffer ?? this.buffer,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
    width: width ?? this.width,
    height: height ?? this.height,
    videoParams: videoParams ?? this.videoParams,
  );
}

/// 内核无关的状态流，字段与各内核自己的流一一对应。
class EngineStreams {
  /// 测试用：直接给定各条流，不依赖具体内核。
  EngineStreams.forTest({
    required this.error,
    required this.completed,
    required this.position,
    required this.playing,
    required this.buffering,
    required this.duration,
    required this.buffer,
    required this.rate,
    required this.volume,
    required this.videoParams,
  });

  EngineStreams.native(NativePlayerCore core)
    : error = core.error,
      completed = core.completed,
      position = core.position,
      playing = core.playing,
      buffering = core.buffering,
      duration = core.duration,
      buffer = core.buffer,
      rate = core.rate,
      volume = core.volume,
      videoParams = core.videoParams;

  final Stream<String> error;
  final Stream<bool> completed;
  final Stream<Duration> position;
  final Stream<bool> playing;
  final Stream<bool> buffering;
  final Stream<Duration> duration;
  final Stream<Duration> buffer;
  final Stream<double> rate;
  final Stream<double> volume;
  final Stream<VideoParams> videoParams;
}

/// 非 Android 平台的占位后端：没有任何播放能力，只保证接口不空转。
class _EmptyBackend implements PlaybackBackend {
  const _EmptyBackend();

  @override
  EngineState get state => const EngineState(
    position: Duration.zero,
    duration: Duration.zero,
  );

  @override
  EngineStreams get stream => EngineStreams.forTest(
    error: const Stream.empty(),
    completed: const Stream.empty(),
    position: const Stream.empty(),
    playing: const Stream.empty(),
    buffering: const Stream.empty(),
    duration: const Stream.empty(),
    buffer: const Stream.empty(),
    rate: const Stream.empty(),
    volume: const Stream.empty(),
    videoParams: const Stream.empty(),
  );

  @override
  Future<void> open(
    String url, {
    required Map<String, String> headers,
    required Duration? start,
    required bool play,
  }) async {}

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> applyDecoder(TelevisionDecoder decoder) async {}
  @override
  Future<void> dispose() async {}
}
