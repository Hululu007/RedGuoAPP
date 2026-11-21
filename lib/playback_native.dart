import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'diary_service.dart';
import 'playback_engine.dart';
import 'playback_preferences.dart';

/// 原生播放内核：Android 侧常驻两个 ExoPlayer，各自终生绑定一张 SurfaceView。
///
/// 与"每集新建一个 ExoPlayer"的普通方案的区别在于「谁拥有 Surface」：
/// - 普通方案：每个播放器一个平台视图，切集换实例就换视图，Surface 重建，
///   解码器 flush 后要等下一个关键帧（短剧分片 4–10s，最坏等一整片）。
/// - 原生内核：两张 SurfaceView 常驻，切集只对调它们的可视位置，Surface 不重建。
///
/// 指令与状态走通道，画面走 `guoapp/native_video` 平台视图（见 player_video.dart）。
class NativePlayerCore implements PlaybackBackend {
  NativePlayerCore() {
    _active = this;
    _subscribe();
    // reset 同时清掉上一轮残留并解除原生侧的 released 门禁，顺带拿一次快照，
    // 避免 Widget 在第一帧读到全 0 的时长。
    _method
        .invokeMethod<Map<Object?, Object?>>('reset')
        .then((value) => _dispatch(value))
        .catchError((Object _) => null);
  }

  static const _method = MethodChannel('duanju/player');
  static const _event = EventChannel('duanju/player/events');

  static NativePlayerCore? _active;
  static StreamSubscription<dynamic>? _events;

  static void _subscribe() {
    _events ??= _event.receiveBroadcastStream().listen(
      _dispatch,
      onError: (Object _) {},
    );
  }

  static void _dispatch(Object? raw) {
    final core = _active;
    if (core == null || raw is! Map) return;
    final map = raw.cast<Object?, Object?>();
    final type = map['type'];
    if (type == 'error') {
      core._error.add('${map['message'] ?? '播放失败'}');
      return;
    }
    if (type == 'videoSize') {
      final width = (map['width'] as num?)?.toInt() ?? 0;
      final height = (map['height'] as num?)?.toInt() ?? 0;
      if (width <= 0 || height <= 0) return;
      core._width = width;
      core._height = height;
      core._videoParams.add(VideoParams(w: width, h: height));
      return;
    }
    core._applyState(map);
  }

  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _buffer = StreamController<Duration>.broadcast();
  final _rate = StreamController<double>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _videoParams = StreamController<VideoParams>.broadcast();

  TelevisionDecoder _decoder = TelevisionDecoder.optimized;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  Duration _lastBuffer = Duration.zero;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  bool _lastCompleted = false;
  double _lastRate = 1;
  double _lastVolume = 100;
  int? _width;
  int? _height;
  bool _closed = false;

  Stream<String> get error => _error.stream;
  Stream<bool> get completed => _completed.stream;
  Stream<Duration> get position => _position.stream;
  Stream<bool> get playing => _playing.stream;
  Stream<bool> get buffering => _buffering.stream;
  Stream<Duration> get duration => _duration.stream;
  Stream<Duration> get buffer => _buffer.stream;
  Stream<double> get rate => _rate.stream;
  Stream<double> get volume => _volume.stream;
  Stream<VideoParams> get videoParams => _videoParams.stream;

  @override
  late final EngineStreams stream = EngineStreams.native(this);

  @override
  EngineState get state => EngineState(
    position: _lastPosition,
    duration: _lastDuration,
    buffer: _lastBuffer,
    playing: _lastPlaying,
    buffering: _lastBuffering,
    completed: _lastCompleted,
    rate: _lastRate,
    volume: _lastVolume,
    width: _width?.toDouble(),
    height: _height?.toDouble(),
    videoParams: _width != null && _height != null
        ? VideoParams(w: _width, h: _height)
        : null,
  );

  void _applyState(Map<Object?, Object?> map) {
    if (_closed) return;
    Duration of(String key) =>
        Duration(milliseconds: (map[key] as num?)?.toInt() ?? 0);

    final position = of('position');
    final duration = of('duration');
    final buffer = of('buffer');
    final playing = map['playing'] == true;
    final buffering = map['buffering'] == true;
    final completed = map['completed'] == true;
    final rate = (map['rate'] as num?)?.toDouble() ?? _lastRate;
    final volume = (map['volume'] as num?)?.toDouble() ?? _lastVolume;

    if (position != _lastPosition) {
      _lastPosition = position;
      _position.add(position);
    }
    if (duration != _lastDuration && duration > Duration.zero) {
      _lastDuration = duration;
      _duration.add(duration);
    }
    if (buffer != _lastBuffer) {
      _lastBuffer = buffer;
      _buffer.add(buffer);
    }
    if (playing != _lastPlaying) {
      _lastPlaying = playing;
      _playing.add(playing);
    }
    if (buffering != _lastBuffering) {
      _lastBuffering = buffering;
      _buffering.add(buffering);
    }
    if (completed != _lastCompleted) {
      _lastCompleted = completed;
      _completed.add(completed);
    }
    if (rate != _lastRate) {
      _lastRate = rate;
      _rate.add(rate);
    }
    if (volume != _lastVolume) {
      _lastVolume = volume;
      _volume.add(volume);
    }
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (_closed || !Platform.isAndroid) return null;
    try {
      return await _method.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      if (!_closed) _error.add(error.message ?? error.code);
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> open(
    String url, {
    required Map<String, String> headers,
    required Duration? start,
    required bool play,
  }) async {
    await _call<void>('open', {
      'url': url,
      'headers': headers,
      'startMs': start?.inMilliseconds ?? 0,
      'play': play,
    });
  }

  /// 预热下一集：只 prepare，不播。画面落在另一张已经绑好的 SurfaceView 上。
  ///
  /// 原生侧等备用实例就绪（true）/出错或超时（false）才回执，调用方可以
  /// 直接把它当作"可以切换"的信号，不需要轮询。
  Future<bool> preload(
    String url, {
    required Map<String, String> headers,
    Duration? start,
  }) async {
    return await _call<bool>('preload', {
      'url': url,
      'headers': headers,
      'startMs': start?.inMilliseconds ?? 0,
    }) ?? false;
  }

  /// 切到预热好的那一集。返回 false 表示没有可切的实例，调用方应回退到完整打开。
  Future<bool> swap() async => await _call<bool>('swap') ?? false;

  /// 当前播放器已读取的字节数，用于估算下载速率。
  Future<int?> bytesRead() async => await _call<int>('bytesRead');

  @override
  Future<void> play() => _call<void>('play');

  @override
  Future<void> pause() => _call<void>('pause');

  @override
  Future<void> playOrPause() async => _lastPlaying ? pause() : play();

  @override
  Future<void> seek(Duration position) =>
      _call<void>('seek', {'ms': position.inMilliseconds});

  @override
  Future<void> stop() => _call<void>('stop');

  @override
  Future<void> setRate(double value) =>
      _call<void>('setRate', {'value': value});

  @override
  Future<void> setVolume(double value) =>
      _call<void>('setVolume', {'value': (value / 100).clamp(0.0, 1.0)});

  @override
  Future<void> applyDecoder(TelevisionDecoder decoder) async {
    _decoder = decoder;
    await _call<void>('setDecoder', {'mode': decoder.name});
  }

  TelevisionDecoder get decoder => _decoder;

  @override
  Future<void> dispose() async {
    // 先让原生侧停掉两个 ExoPlayer，再置 _closed：_call 在 _closed 为 true 时
    // 会直接返回，先置位的话 release 永远发不出去，退出播放页后声音还在响。
    if (identical(_active, this)) _active = null;
    DiaryService.add('[Play] 释放原生播放内核');
    await _call<void>('release');
    _closed = true;
    await _error.close();
    await _completed.close();
    await _position.close();
    await _playing.close();
    await _buffering.close();
    await _duration.close();
    await _buffer.close();
    await _rate.close();
    await _volume.close();
    await _videoParams.close();
  }
}
