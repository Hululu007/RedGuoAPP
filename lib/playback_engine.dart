import 'dart:async';
import 'dart:io' show Platform;

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import 'app_device.dart';
import 'diary_service.dart';
import 'playback_preferences.dart';

/// 统一的播放内核外观：对外暴露与 media_kit 一致的子集 API，
/// MPV 与 ExoPlayer 两个内核互不感知，UI 与会话层只面向本类。
class EnginePlayer {
  EnginePlayer._mpv(Player player) : _mpv = player, _exo = null {
    kernel = PlaybackKernel.mpv;
  }

  EnginePlayer._exo() : _mpv = null, _exo = _ExoCore() {
    kernel = PlaybackKernel.exo;
  }

  factory EnginePlayer.open({required PlaybackKernel kernel}) {
    if (kernel == PlaybackKernel.exo && Platform.isAndroid) {
      return EnginePlayer._exo();
    }
    return EnginePlayer.wrap(
      Player(
        configuration: const PlayerConfiguration(
          bufferSize: 32 * 1024 * 1024,
          logLevel: MPVLogLevel.error,
        ),
      ),
    );
  }
  /// 包装一个已有的 media_kit 播放器（测试或自定义场景使用）。
  factory EnginePlayer.wrap(Player player) => EnginePlayer._mpv(player);

  final Player? _mpv;
  final _ExoCore? _exo;
  VideoController? _video;
  /// MPV 本次是否临时改用软解。硬解起不来时的临时降级，不影响后续剧集。
  bool _mpvSoftwareOnly = false;
  /// MPV 的硬解方式。
  ///
  /// 默认不指定，交给 media_kit 用平台默认（Android 上是 auto-safe，会自动挑选
  /// 设备上真正可用的硬解后端）。硬指定某一个反而不稳——组合不合适时 mpv 会直接
  /// 报「Could not open codec.」，然后一路退到软解。
  String? _mpvHwdec;
  late final PlaybackKernel kernel;

  /// 当前应使用的 MPV 硬解方式。null 表示用平台默认。
  String? get mpvHwdec => _mpvSoftwareOnly ? 'no' : _mpvHwdec;

  /// 设置 MPV 的硬解方式。null 表示用平台默认（自动挑选）。
  void setMpvHwdec(String? value) {
    if (_mpvHwdec == value) return;
    _mpvHwdec = value;
    _video = null;
  }

  bool get isMpv => _mpv != null;
  bool get isExo => _exo != null;

  /// 底层 media_kit 播放器（MPV 内核），测试与诊断使用。
  Player? get mpvPlayer => _mpv;

  /// MPV 专属能力；Exo 内核返回 null，调用方据此跳过。
  NativePlayer? get platform => _mpv?.platform is NativePlayer
      ? _mpv!.platform as NativePlayer
      : null;

  /// 视频输出控制器（MPV 内核）。按需创建，避免无渲染层的测试环境依赖
  /// WidgetsBinding。
  ///
  /// hwdec 统一由这里决定（见 [mpvHwdec]），和播放层的 setProperty 用同一个值：
  /// 视频输出创建时 media_kit 会按配置重新设置 hwdec，两边不一致的话以这里为准，
  /// 「解码方式 › 软件解码」这类偏好就会被盖回去。
  ///
  /// 真正需要零拷贝时用 ExoPlayer：它走原生 SurfaceView 直通，画面不经过 CPU。
  VideoController get mpvVideo =>
      _video ??= VideoController(
        _mpv!,
        configuration: VideoControllerConfiguration(hwdec: mpvHwdec),
      );

  /// MPV 硬解降级：本次播放关掉硬件解码，改用系统软解。
  ///
  /// 只影响当前这一次尝试，不改全局配置——硬件解码在个别片源上会起不来，但换个
  /// 剧集往往又能用，永久关掉会让后面的剧集一直软解。
  /// vo 与 hwdec 都是视频输出创建时的属性，运行时改不动，要靠重建输出控制器。
  Future<void> downgradeMpvHwdec() async {
    if (!isMpv) return;
    _mpvSoftwareOnly = true;
    final platform = this.platform;
    if (platform != null) {
      try {
        await platform.setProperty('hwdec', 'no');
      } catch (_) {
        // 切不动就按原流程走。
      }
    }
    _video = null;
  }
  /// 恢复硬件解码。上一集硬解起不来而临时降级过软解时，换集后调用这个。
  Future<void> restoreMpvHwdec() async {
    if (!isMpv || !_mpvSoftwareOnly) return;
    _mpvSoftwareOnly = false;
    final platform = this.platform;
    if (platform != null) {
      try {
        await platform.setProperty('hwdec', _mpvHwdec ?? 'auto-safe');
      } catch (_) {
        // 切不动就按原流程走。
      }
    }
    _video = null;
  }

  VideoPlayerController? get exoVideo => _exo?.controller;

  EngineState get state => _mpv != null
      ? EngineState.of(_mpv!.state)
      : _exo?.state ??
        const EngineState(position: Duration.zero, duration: Duration.zero);

  EngineStreams get stream => _mpv != null
      ? EngineStreams._of(_mpv!.stream)
      : EngineStreams._exo(_exo!);

  Future<void> open(
    String url, {
    Map<String, String> headers = const {},
    Duration? start,
    required bool play,
  }) async {
    final mpv = _mpv;
    if (mpv != null) {
      return mpv.open(
        Media(url, httpHeaders: headers, start: start),
        play: play,
      );
    }
    return _exo!.open(url, headers: headers, start: start, play: play);
  }

  Future<void> play() async {
    if (_mpv != null) return _mpv!.play();
    return _exo?.play();
  }

  Future<void> pause() async {
    if (_mpv != null) return _mpv!.pause();
    return _exo?.pause();
  }

  Future<void> playOrPause() async {
    if (_mpv != null) return _mpv!.playOrPause();
    return _exo?.playOrPause();
  }

  Future<void> seek(Duration position) async {
    if (_mpv != null) return _mpv!.seek(position);
    return _exo?.seek(position);
  }

  Future<void> stop() async {
    if (_mpv != null) return _mpv!.stop();
    return _exo?.stop();
  }

  Future<void> setRate(double value) async {
    if (_mpv != null) return _mpv!.setRate(value);
    return _exo?.setRate(value);
  }

  Future<void> setVolume(double value) async {
    if (_mpv != null) return _mpv!.setVolume(value);
    return _exo?.setVolume(value);
  }

  /// Exo 内核没有 MPV 式的软硬解属性：选软件解码时让原生只用系统软解，
  /// 其余情况保持硬解优先、失败自动回退软解。
  Future<void> applyDecoder(TelevisionDecoder decoder) async {
    final exo = _exo;
    if (exo == null) return;
    await exo.applyDecoder(decoder);
    // 这里只说明「期望」用哪种解码方式，真正用了哪个解码器由播放诊断日记里的
    // 「实际使用解码器」一行给出（硬解初始化失败时 ExoPlayer 会静默回退软解）。
    DiaryService.add(
      '[Video] 解码方式设定：${switch (decoder) {
        TelevisionDecoder.software => '只用系统软解',
        TelevisionDecoder.hardware => '优先硬解',
        _ => '优先硬解，初始化失败时回退系统软解',
      }}',
    );
  }

  Future<void> dispose() async {
    if (_mpv != null) return _mpv!.dispose();
    return _exo?.dispose();
  }
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

  factory EngineState.of(PlayerState state) => EngineState(
    position: state.position,
    duration: state.duration,
    buffer: state.buffer,
    playing: state.playing,
    buffering: state.buffering,
    completed: state.completed,
    rate: state.rate,
    volume: state.volume,
    width: state.width?.toDouble(),
    height: state.height?.toDouble(),
    videoParams: state.videoParams,
  );

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
}

/// 内核无关的状态流，成员与 media_kit 的 Streams 保持同名。
class EngineStreams {
  EngineStreams._of(PlayerStream stream)
    : error = stream.error,
      completed = stream.completed,
      position = stream.position,
      playing = stream.playing,
      buffering = stream.buffering,
      duration = stream.duration,
      buffer = stream.buffer,
      rate = stream.rate,
      volume = stream.volume,
      videoParams = stream.videoParams;

  EngineStreams._exo(_ExoCore core)
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

/// 基于 video_player（Android 上为 ExoPlayer/Media3）的内核实现。
class _ExoCore {
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

  VideoPlayerController? _controller;
  TelevisionDecoder _decoder = TelevisionDecoder.optimized;
  VideoParams? _lastParams;
  Duration _lastBuffer = Duration.zero;
  Duration _lastPosition = Duration.zero;
  Duration? _lastDuration;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  double _lastRate = 1;
  double _lastVolume = 1;
  double _pendingRate = 1;
  double _pendingVolume = 100;
  bool _closed = false;

  VideoPlayerController? get controller => _controller;

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

  EngineState get state {
    final value = _controller?.value;
    if (value == null || !value.isInitialized) {
      return const EngineState(
        position: Duration.zero,
        duration: Duration.zero,
        rate: 1,
        volume: 1,
      );
    }
    final size = value.size;
    final params = size == null
        ? null
        : VideoParams(w: size.width.round(), h: size.height.round());
    return EngineState(
      position: value.position,
      duration: value.duration,
      buffer: _lastBuffer,
      playing: value.isPlaying,
      buffering: value.isBuffering,
      completed:
          value.duration > Duration.zero && value.position >= value.duration,
      rate: value.playbackSpeed,
      volume: value.volume * 100,
      width: size?.width.toDouble(),
      height: size?.height.toDouble(),
      videoParams: params ?? _lastParams,
    );
  }

  Future<void> open(
    String url, {
    required Map<String, String> headers,
    required Duration? start,
    required bool play,
  }) async {
    final previous = _controller;
    _controller = null;
    _lastParams = null;
    _lastBuffer = Duration.zero;
    _lastDuration = null;
    _completed.add(false);
    if (previous != null) {
      await previous.dispose().catchError((Object _) {});
    }
    // 保证原生侧的解码器偏好已经生效，再建 ExoPlayer 实例。
    await AppDevice.setDecoderMode(_decoder.name);
    // 走 PlatformView（SurfaceView 直通）渲染：与原生 Kotlin 版 ExoPlayer 路径一致。
    //
    // Flutter 默认的 texture 路径把视频解码到 SurfaceTexture 上，SurfaceTexture 的缓冲尺寸
    // 初始为 0x0，部分 32 位设备的硬解解码器在 configure 阶段协商不到匹配的图形缓冲区，
    // 初始化直接失败后静默回退软解。SurfaceView 有真实的窗口尺寸，不存在这个问题。
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
      viewType: VideoViewType.platformView,
    );
    _controller = controller;
    controller.addListener(_listen);
    try {
      await controller.initialize();
    } catch (failure) {
      if (!_closed && identical(_controller, controller)) {
        _error.add('$failure');
      }
      rethrow;
    }
    if (_closed || !identical(_controller, controller)) {
      await controller.dispose().catchError((Object _) {});
      return;
    }
    await controller.setPlaybackSpeed(_pendingRate);
    await controller.setVolume(_pendingVolume / 100);
    if (start != null && start > Duration.zero) {
      await controller.seekTo(start);
    }
    if (play) {
      await controller.play();
    }
  }

  void _listen() {
    final value = _controller?.value;
    if (value == null || !value.isInitialized || _closed) return;
    if (value.position != _lastPosition) {
      _lastPosition = value.position;
      _position.add(value.position);
    }
    final buffered = value.buffered.isEmpty
        ? Duration.zero
        : value.buffered.last.end;
    if (buffered != _lastBuffer) {
      _lastBuffer = buffered;
      _buffer.add(buffered);
    }
    if (value.duration != _lastDuration) {
      _lastDuration = value.duration;
      _duration.add(value.duration);
    }
    if (value.isPlaying != _lastPlaying) {
      _lastPlaying = value.isPlaying;
      _playing.add(value.isPlaying);
    }
    if (value.isBuffering != _lastBuffering) {
      _lastBuffering = value.isBuffering;
      _buffering.add(value.isBuffering);
    }
    if (value.playbackSpeed != _lastRate) {
      _lastRate = value.playbackSpeed;
      _rate.add(value.playbackSpeed);
    }
    final volume = value.volume * 100;
    if ((volume - _lastVolume).abs() > .5) {
      _lastVolume = volume;
      _volume.add(volume);
    }
    final size = value.size;
    if (size != null) {
      final params = VideoParams(
        w: size.width.round(),
        h: size.height.round(),
      );
      if (params.w != _lastParams?.w || params.h != _lastParams?.h) {
        _lastParams = params;
        _videoParams.add(params);
      }
    }
    if (value.duration > Duration.zero && value.position >= value.duration) {
      _completed.add(true);
    }
    if (value.errorDescription != null) {
      _error.add(value.errorDescription!);
    }
  }

  Future<void> applyDecoder(TelevisionDecoder decoder) async {
    _decoder = decoder;
    await AppDevice.setDecoderMode(decoder.name);
  }

  Future<void> play() => _controller?.play() ?? Future<void>.value();

  Future<void> pause() => _controller?.pause() ?? Future<void>.value();

  Future<void> playOrPause() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  Future<void> seek(Duration position) =>
      _controller?.seekTo(position) ?? Future<void>.value();

  Future<void> stop() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.pause().catchError((Object _) {});
    await controller.seekTo(Duration.zero).catchError((Object _) {});
  }

  Future<void> setRate(double value) async {
    _pendingRate = value;
    return _controller?.setPlaybackSpeed(value) ?? Future<void>.value();
  }

  Future<void> setVolume(double value) async {
    _pendingVolume = value;
    return _controller?.setVolume((value / 100).clamp(0.0, 1.0))
        ?? Future<void>.value();
  }

  Future<void> dispose() async {
    _closed = true;
    final controller = _controller;
    _controller = null;
    await controller?.dispose().catchError((Object _) {});
    _error.close();
    _completed.close();
    _position.close();
    _playing.close();
    _buffering.close();
    _duration.close();
    _buffer.close();
    _rate.close();
    _volume.close();
    _videoParams.close();
  }
}
