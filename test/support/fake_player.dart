import 'dart:async';

import 'package:duanju_app/playback_engine.dart';
import 'package:duanju_app/playback_preferences.dart';

/// 记录一次 open 调用，测试用 `.uri` / `.start` 断言。
class OpenedMedia {
  OpenedMedia(this.url, this.start);

  final String url;
  final Duration? start;

  Uri get uri => Uri.parse(url);
}

/// 测试用的内核替身。实现 [PlaybackBackend] 而不是 media_kit 的 Player，
/// 这样去掉 mpv 之后测试仍能驱动会话层的预热、互换与恢复逻辑。
class FakePlayer implements PlaybackBackend {
  EngineState _state = const EngineState(
    position: Duration.zero,
    duration: Duration.zero,
  );

  final opened = <OpenedMedia>[];
  final rates = <double>[];
  final seeks = <Duration>[];
  var stops = 0;
  var disposed = false;

  /// 挂起 [open]，模拟播放器正在初始化。
  Completer<void>? openGate;

  final _playing = StreamController<bool>.broadcast(sync: true);
  final _completed = StreamController<bool>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _duration = StreamController<Duration>.broadcast(sync: true);
  final _videoParams = StreamController<VideoParams>.broadcast(sync: true);
  final _error = StreamController<String>.broadcast(sync: true);
  final _buffering = StreamController<bool>.broadcast(sync: true);

  @override
  EngineState get state => _state;

  set state(EngineState value) => _state = value;

  @override
  late final EngineStreams stream = EngineStreams.forTest(
    error: _error.stream,
    completed: _completed.stream,
    position: _position.stream,
    playing: _playing.stream,
    buffering: _buffering.stream,
    duration: _duration.stream,
    buffer: const Stream.empty(),
    rate: const Stream.empty(),
    volume: const Stream.empty(),
    videoParams: _videoParams.stream,
  );

  void progress(Duration position, {Duration? duration}) {
    _state = _state.copyWith(
      position: position,
      duration: duration ?? _state.duration,
    );
    if (duration != null) _duration.add(duration);
    _position.add(position);
  }

  void finish() {
    _state = _state.copyWith(
      position: _state.duration,
      completed: true,
      playing: false,
    );
    _completed.add(true);
  }

  void fail(String message) => _error.add(message);

  void buffer(bool buffering) {
    _state = _state.copyWith(buffering: buffering);
    _buffering.add(buffering);
  }

  void resize(int width, int height) =>
      _videoParams.add(VideoParams(w: width, h: height));

  @override
  Future<void> open(
    String url, {
    required Map<String, String> headers,
    required Duration? start,
    required bool play,
  }) async {
    opened.add(OpenedMedia(url, start));
    _state = _state.copyWith(
      playing: play,
      completed: false,
      position: start ?? Duration.zero,
    );
    _playing.add(play);
    final gate = openGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    _state = _state.copyWith(playing: false, position: Duration.zero);
  }

  @override
  Future<void> play() async {
    _state = _state.copyWith(playing: true);
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    _state = _state.copyWith(playing: false);
    _playing.add(false);
  }

  @override
  Future<void> playOrPause() => _state.playing ? pause() : play();

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _state = _state.copyWith(position: position);
  }

  @override
  Future<void> setRate(double value) async {
    rates.add(value);
    _state = _state.copyWith(rate: value);
  }

  @override
  Future<void> setVolume(double value) async {
    _state = _state.copyWith(volume: value);
  }

  @override
  Future<void> applyDecoder(TelevisionDecoder decoder) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
