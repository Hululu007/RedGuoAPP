import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'app_device.dart';
import 'core_bridge.dart';
import 'danmaku_controller.dart';
import 'danmaku_style.dart';
import 'diary_service.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'media_controls.dart';
import 'models.dart';
import 'playback_engine.dart';
import 'playback_loader.dart';
import 'playback_preferences.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';

Size? videoDisplaySize(VideoParams parameters) {
  final width = (parameters.dw ?? 0) > 0 ? parameters.dw! : parameters.w ?? 0;
  final height = (parameters.dh ?? 0) > 0 ? parameters.dh! : parameters.h ?? 0;
  if (width <= 0 || height <= 0) return null;
  final rotation = (parameters.rotate ?? 0) % 180;
  return rotation == 90
      ? Size(height.toDouble(), width.toDouble())
      : Size(width.toDouble(), height.toDouble());
}

String _diagnostic(Object error) {
  final text = error.toString().replaceAll(
    RegExp(r'[a-z]+://\S+', caseSensitive: false),
    '[地址]',
  );
  return text.length > 300 ? text.substring(0, 300) : text;
}

/// 提前准备下一集的剩余时点（毫秒）：本集快结束前才把备用播放器开起来，
/// 开一整路解码占资源重，取播放地址很轻、开播几秒后就该做。
const preloadLeadMs = 45000;

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.repository,
    required this.store,
    required this.detail,
    required this._player,
    this._standby,
    required int index,
    double position = 0,
    bool autoplay = true,
  }) : _engaged = autoplay,
       _index = index,
       _epoch = store.profileEpoch {
    final preferences = store.playbackPreferences;
    _speed = preferences.speed;
    _quality = preferences.quality;
    _danmakuEnabled = preferences.danmaku;
    _videoFit = preferences.videoFit;
    _unmutedVolume = store.playerVolume.clamp(1.0, 100.0);
    unawaited(_player.setVolume(_unmutedVolume));
    _loader = PlaybackLoader(repository);
    _preloader = PlaybackPreloader(repository)..addListener(_prime);
    // 「预开下一集」是用户明确控制的开关，关掉就完全不预加载。
    unawaited(_syncPreloadSetting());
    danmaku = DanmakuController(repository)
      ..setEnabled(_danmakuEnabled)
      ..setMergeWindow(preferences.danmakuMerge)
      ..setBlockedWords(preferences.danmakuWords);
    store.addListener(_accessChanged);
    store.addListener(_syncDanmakuOptions);
    store.addListener(_syncMedia);
    _bind();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => saveProgress(quiet: true),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || !_acceptErrors || _loading || _error != null) return;
      if (_health.stalled(
        position: player.state.position,
        playing: player.state.playing && _playIntent,
        foreground: _foreground,
        now: DateTime.now(),
      )) {
        DiaryService.add(
          '[Play] 停滞检测 位置=${player.state.position.inSeconds}s '
          '播放=${player.state.playing} 缓冲=${player.state.buffering}',
        );
        unawaited(_recover('position_stalled_20s'));
      }
    });
    unawaited(play(index, position: position, playWhenReady: autoplay));
  }

  void _bind() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final size = videoDisplaySize(player.state.videoParams);
    if (size != null) _videoSize = size;
    _buffering(player.state.buffering);
    final stream = player.stream;
    _subscriptions.addAll([
      stream.error.listen(_playerError),
      stream.completed.listen(_completed),
      stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
        _sync();
      }),
      stream.playing.listen((playing) {
        if (playing) {
          _started = true;
        } else {
          endBoost();
          _networkSpeed = 0;
        }
        _sync();
      }),
      stream.buffering.listen((buffering) {
        _buffering(buffering);
        _sync();
      }),
      for (final changes in [stream.duration, stream.buffer, stream.rate])
        changes.listen((_) => _sync()),
      stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size == null || _closed) return;
        _videoSize = size;
        _notify();
      }),
    ]);
  }

  int? _networkSpeed;
  bool _speedReading = false;
  Duration? _speedResumeAt;
  DateTime? _speedResumeDeadline;
  int? _speedBytes;
  DateTime? _speedBytesAt;

  void _holdNetworkSpeed() {
    _speedResumeAt = player.state.position;
    _speedResumeDeadline = DateTime.now().add(const Duration(seconds: 15));
  }

  final AppRepository repository;
  final LocalStore store;
  DramaDetail detail;
  EnginePlayer _player;
  EnginePlayer? _standby;
  Future<void>? _standbyOpening;

  /// 设置里的「预开下一集」是否开启。关闭后完全不预加载。
  bool _preloadEnabled = true;
  late final DanmakuController danmaku;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  final _recovery = PlaybackRecovery();
  final _health = PlaybackHealth();
  final int _epoch;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _boostTimer;
  Timer? _stallTimer;
  Timer? _volumeTimer;
  Timer? _sleepTimer;
  Timer? _standbyIdleTimer;
  Timer? _resumeTimer;
  Timer? _seekWatchdog;
  DateTime? _pausedSince;
  DateTime? _sleepAt;
  int _sleepMinutes = 0;
  bool _sleepAtEpisodeEnd = false;
  bool _advancingSeason = false;
  Future<void> _operations = Future<void>.value();
  Future<void> _rates = Future<void>.value();
  int _index;
  int _openedIndex = -1;
  int _generation = 0;
  int _seekSequence = 0;
  bool _loading = true;
  bool _online = false;
  bool _localFailure = false;
  bool _loginRequired = false;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _visible = true;
  bool _playIntent = true;
  bool _pendingError = false;
  bool _canceledRetry = false;
  bool _timeoutRetry = false;
  bool _boosting = false;
  bool _boostLocked = false;
  bool _locked = false;
  bool _engaged;
  bool _staleAudio = false;
  bool _stalled = false;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  String? _savedProgressKey;
  bool _savedQuietly = false;
  PlaybackPlan? _plan;
  PlaybackPlan? _standbyPlan;
  int _standbyIndex = -1;
  bool _standbyOpen = false;
  DateTime _standbyAt = DateTime(2000);
  double _openedAt = 0;
  double _speed = 1;
  int _quality = 0;
  bool _danmakuEnabled = true;
  Size? _videoSize;
  VideoFit _videoFit = VideoFit.auto;
  double _resumePosition = 0;
  double _unmutedVolume = 100;

  EnginePlayer get player => _player;

  EnginePlayer? get standby => _standbyOpen ? _standby : null;
  int get standbyIndex => _standbyOpen ? _standbyIndex : -1;

  /// 预热那一路的画面由 Exo 兼容内核负责（已删除），原生内核的预热
  /// 走 [NativePlayerCore.preload]，不需要在这里暴露控制器。
  int get index => _index;
  Episode get episode => detail.episodes[_index];
  bool get loading => _loading;
  String get loadingMessage => _loadingMessage;
  String? get error => _error;
  bool get localFailure => _localFailure;
  bool get loginRequired => _loginRequired;
  String? get saveWarning => _saveWarning;
  bool get ready => !_loading && _error == null;

  bool get stalled => _stalled;

  /// 本集是否已经真正起播过。起播前的缓冲与播放中的卡顿要用不同的 UI 反馈：
  /// 前者沿用加载遮罩（全程同一个转圈，不会「转圈消失又冒出来一个」），
  /// 后者才在画面上单独转圈。
  bool _started = false;
  bool get started => _started;

  /// 秒切接管后的转圈稳定窗截止时间戳（借鉴 HongGuoTV 的 350ms 稳定窗口）：
  /// 新集起播瞬间常有一次极短的 BUFFERING，直接看 buffering 状态会让刚接上
  /// 的画面闪现转圈。窗口期内不显示起播转圈，窗口过后恢复普通逻辑——持续
  /// 缓冲仍会转圈，不会遮掩真实卡顿。
  int _swapStableUntil = 0;

  /// 起播前阶段的加载反馈：取地址/开流期间与首帧缓冲期间都算，
  /// 中间不留「既不转圈也没画面」的空档。
  bool get booting {
    if (_closed ||
        _started ||
        _error != null ||
        _localFailure ||
        _loginRequired) {
      return false;
    }
    if (DateTime.now().millisecondsSinceEpoch < _swapStableUntil) return false;
    return _loading || player.state.buffering;
  }

  bool get paused => !_playIntent;
  bool get boosting => _boosting;
  bool get boostLocked => _boostLocked;
  bool get locked => _locked;
  Size? get videoSize => _videoSize;
  double get aspectRatio => switch (_videoSize) {
    final size? => size.width / size.height,
    null => 9 / 16,
  };
  bool get aspectKnown => _videoSize != null;
  VideoFit get videoFit => _videoFit;
  double get speed => _speed;
  DateTime? get sleepAt => _sleepAt;
  int get sleepMinutes => _sleepMinutes;
  bool get sleepAtEpisodeEnd => _sleepAtEpisodeEnd;
  int get quality => _quality;
  bool get local => _plan?.local == true;
  List<int> get qualities => _plan?.qualities ?? const [];
  bool get danmakuSupported => SourceSite.byId(detail.drama.source).danmaku;
  bool get danmakuEnabled => _danmakuEnabled;
  PlaybackPreferences get preferences => _preferences;
  DanmakuStyle get danmakuStyle => DanmakuStyle.of(store.playbackPreferences);
  bool get hasPrevious => _index > 0;
  bool get hasNext => _index + 1 < detail.episodes.length;
  String get qualityLabel {
    final plan = _plan;
    if (plan != null && plan.local) {
      return plan.quality > 0 ? '本地 ${plan.quality}P' : '本地';
    }
    if (_quality > 0) return '${_quality}P';
    return plan != null && plan.quality > 0 ? '自动（${plan.quality}P）' : '自动';
  }

  double get currentPosition =>
      _openedIndex == _index && player.state.position > Duration.zero
      ? player.state.position.inMilliseconds / 1000
      : _resumePosition;

  bool get _usable => !_closed && store.profileEpoch == _epoch;
  bool _current(int ticket) => _usable && ticket == _generation;

  PlaybackPreferences get _preferences => store.playbackPreferences.copyWith(
    speed: _speed,
    quality: _quality,
    danmaku: _danmakuEnabled,
    videoFit: _videoFit,
    autoAdvance: true,
    preload: true,
  );

  double get _rate => _boosting ? store.playbackPreferences.boostSpeed : _speed;

  void _buffering(bool buffering) {
    _stallTimer?.cancel();
    if (buffering) {
      _stallTimer = Timer(const Duration(milliseconds: 500), () {
        if (_closed || !player.state.buffering) return;
        _stalled = true;
        _notify();
      });
    } else if (_stalled) {
      _stalled = false;
      _notify();
    }
  }

  void _notify() {
    if (_closed) return;
    notifyListeners();
    _syncMedia();
  }

  void _accessChanged() {
    if (_closed) return;
    if (store.profileEpoch != _epoch || store.locked) {
      _preloader.clear();
      _dropStandby();
      _playIntent = false;
      endBoost();
      unawaited(player.pause());
    }
    if (store.profileEpoch != _epoch ||
        store.locked ||
        !store.allowsSource(detail.drama.source)) {
      danmaku.setPlan(null);
    }
  }

  void _syncDanmakuOptions() {
    if (_closed) return;
    final preferences = store.playbackPreferences;
    danmaku.setMergeWindow(preferences.danmakuMerge);
    danmaku.setBlockedWords(preferences.danmakuWords);
  }

  void _sync() {
    _syncDanmaku();
    _syncPreload();
    _syncMedia();
  }

  bool get _backgroundPlayback => store.playbackPreferences.backgroundPlayback;

  void _syncMedia() {
    if (_closed) return;
    // 设置变了，「预开下一集」开关可能也变了。
    unawaited(_syncPreloadSetting());
    final controls = MediaControls.instance;
    if (!_backgroundPlayback || !_engaged || !_usable || store.locked) {
      controls.release(this);
      return;
    }
    if (!_playIntent && !controls.owns(this)) return;
    final state = player.state;
    final opened = ready && _openedIndex == _index;
    controls.update(
      this,
      MediaState(
        title: detail.drama.title,
        subtitle: episode.title,
        artwork: repository.knownCover(detail.drama) ?? '',
        active: _playIntent && _error == null,
        playing: _playIntent && state.playing,
        position: opened ? state.position : Duration.zero,
        duration: opened ? state.duration : Duration.zero,
        rate: state.rate,
        hasPrevious: hasPrevious,
        hasNext: hasNext,
      ),
      _mediaCommand,
    );
  }

  void _mediaCommand(MediaCommand command, Duration? position) {
    if (_closed) return;
    switch (command) {
      case MediaCommand.play:
        if (paused) togglePlayback();
      case MediaCommand.pause:
        _pause();
      case MediaCommand.toggle:
        if (paused) {
          togglePlayback();
        } else {
          _pause();
        }
      case MediaCommand.next:
        unawaited(next());
      case MediaCommand.previous:
        unawaited(previous());
      case MediaCommand.seek:
        if (position != null) unawaited(seekTo(position));
    }
  }

  void pause() => _pause();

  void _pause() {
    if (!_usable || !_playIntent) return;
    if (ready && player.state.playing) {
      togglePlayback();
      return;
    }
    _stop();
    _cancelResumeWatchdog();
    _pausedSince = DateTime.now();
    _scheduleStandbyIdle();
    _notify();
  }

  void _syncDanmaku() {
    if (_closed) return;
    final state = player.state;
    danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          ready &&
          _openedIndex == _index &&
          _usable &&
          !store.locked &&
          store.allowsSource(detail.drama.source),
    );
  }

  /// 提前准备下一集的剩余时点：本集快结束时才开备用播放器，省资源。

  /// 同步设置里的「预开下一集」开关。
  ///
  /// 关掉时立刻停掉已有的预加载并释放备用播放器；打开时从下一轮同步开始预加载。
  Future<void> _syncPreloadSetting() async {
    if (_closed) return;
    final television = await AppDevice.isTelevisionDevice();
    if (_closed) return;
    final enabled = store.playbackPreferences.preopens(television: television);
    if (_preloadEnabled == enabled) return;
    _preloadEnabled = enabled;
    if (!enabled) {
      _preloader.clear();
      _dropStandby();
    }
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_foreground ||
        _plan?.local == true ||
        !ready ||
        _openedIndex != _index ||
        !_usable ||
        !_engaged ||
        store.locked ||
        !hasNext) {
      _preloader.clear();
      return;
    }
    // 设置里的「预开下一集」关掉就完全不预加载：既不取下一集的播放地址，也不留备用
    // 播放器，切集时现取地址（会慢一点，但省内存和电量）。
    if (!_preloadEnabled) {
      _preloader.clear();
      _dropStandby();
      return;
    }
    final state = player.state;
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    final ahead = state.buffer.inMilliseconds - position;
    // 对齐 HongGuoTV 的积极策略：主播放器就绪就尽早开始准备下一集，
    // 只要求缓冲不处于饥饿状态（1.5 秒），不再等缓冲攒够 3 秒。
    if (duration <= 0 || ahead < 1500) {
      return;
    }
    if (_standby != null) {
      if (_standbyOpen &&
          DateTime.now().difference(_standbyAt) > const Duration(minutes: 8)) {
        _dropStandby();
      }
      if (_standbyIndex >= 0) {
        // 备用播放器已经在预热下一集，不用再管地址。
        return;
      }
      // 备用播放器要开一整路解码，占资源重，等本集快结束再开。
      // 但取下一集的播放地址很轻，开播几秒后就该做，用户手动切集才不用现取。
      if (duration - position > preloadLeadMs) {
        if (position >= 2000 && state.playing && !state.buffering) {
          _preloader.prepare(
            detail.drama,
            detail.episodes[_index + 1],
            quality: _quality,
            online: _online,
          );
        }
        return;
      }
    } else {
      if (!state.playing || state.buffering || !_playIntent) {
        _preloader.pause();
        return;
      }
      // 预加载要尽早开始（HongGuoTV 是主播放器一 READY 就备下一集）。
      // 短剧一集两三分钟，等到播过一半才准备，用户在前半段手动切集就
      // 一定赶不上，每次都得现取播放地址（实测 1~4 秒）。
      if (position < 1200) {
        return;
      }
    }
    _preloader.prepare(
      detail.drama,
      detail.episodes[_index + 1],
      quality: _quality,
      online: _online,
    );
  }

  void _playerError(String error) {
    if (_closed || !_acceptErrors || error.trim().isEmpty) return;
    DiaryService.add('[Play] 播放器报错：${_diagnostic(error)}');
    if (isDecoderFailure(error)) {
      if (_strictHardware) {
        // 硬解档不降级，交给恢复流程换线路/换清晰度，最终失败就明确报错。
        _queueRecovery('decoder_unavailable');
      } else {
        unawaited(_retryWithSoftDecoder('解码器不可用'));
      }
      return;
    }
    _queueRecovery('player_error');
  }

  Future<void> _completed(bool completed) async {
    if (!completed || _loading || _closed || !_acceptErrors || _error != null) {
      return;
    }
    final duration = player.state.duration;
    final position = player.state.position;
    if (duration <= Duration.zero
        ? position <= Duration.zero
        : position < duration - const Duration(seconds: 2)) {
      _queueRecovery('early_completion');
    } else if (_foreground && hasNext && !_sleepAtEpisodeEnd) {
      final index = _index;
      final opening = _standbyOpening;
      if (opening != null && _standbyIndex == index + 1) {
        // 自动连播且下一集还在预热：本集已播完、画面停在末帧，此时放弃预热
        // 改走全量打开是最浪费的——回执可能马上就到。这里最多等 8 秒回执，
        // 等到了 play() 直接秒切备用（原生门槛保证接管即带 3 秒起播跑道）；
        // 等不到再按「未就绪立即释放备用」规则走主播放器。手动切集不经过
        // 这里，仍然是切了就立即释放备用。
        DiaryService.add('[Play] 片尾等待下一集预热回执');
        try {
          await opening.timeout(const Duration(seconds: 8));
        } catch (_) {}
        if (_closed || _index != index || !_current(_generation)) {
          return;
        }
        DiaryService.add('[Play] 片尾预热回执=${_standbyOpen ? '就绪' : '未就绪'}');
      }
      unawaited(play(index + 1));
    } else if (_foreground &&
        !_sleepAtEpisodeEnd &&
        detail.nextSeason != null) {
      unawaited(_playNextSeason());
    } else {
      final sleeping = _sleepAtEpisodeEnd;
      if (sleeping) _clearSleep();
      _stop();
      if (sleeping) _notify();
    }
  }

  void _stop() {
    _playIntent = false;
    endBoost();
    unawaited(player.pause());
    unawaited(saveProgress());
  }

  void syncSeasons(List<DramaSeason> seasons) {
    if (_closed ||
        seasons.isEmpty ||
        identical(seasons, detail.seasons) ||
        !seasons.any((season) => season.drama.id == detail.drama.id)) {
      return;
    }
    detail = DramaDetail(
      detail.drama,
      detail.episodes,
      warning: detail.warning,
      seasons: seasons,
    );
  }

  bool get switchingSeason => _advancingSeason;

  Future<void> _playNextSeason() async {
    final season = detail.nextSeason;
    if (season == null) return;
    DiaryService.add('[Play] 本季播完，切换到${season.label}');
    await _switchSeason(season, resume: false);
  }

  Future<bool> playSeason(DramaSeason season) async {
    if (season.drama.id == detail.drama.id) return true;
    DiaryService.add('[Play] 手动切换到${season.label}');
    return _switchSeason(season, resume: true);
  }

  Future<bool> _switchSeason(DramaSeason season, {required bool resume}) async {
    if (_advancingSeason || !_usable) return false;
    _advancingSeason = true;
    final ticket = _generation;
    _dropStandby();
    _preloader.clear();
    _notify();
    try {
      await saveProgress();
      final next = await repository.detail(season.drama);
      if (!_current(ticket) || !_foreground) return false;
      if (next.episodes.isEmpty) throw AppFailure('${season.label}暂时没有可播放的分集');
      final watch = resume ? store.watched(season.drama.id) : null;
      final index = resumeEpisodeIndex(next.episodes, watch);
      final position =
          watch != null &&
              !watch.finished &&
              watch.episode == next.episodes[index].number
          ? watch.position
          : 0.0;
      detail = DramaDetail(
        repository.catalogUpdates.current(season.drama).merge(next.drama),
        next.episodes,
        warning: next.warning,
        seasons: detail.seasons,
      );
      _openedIndex = -1;
      _index = index;
      _online = false;
      _notify();
      await play(index, position: position);
      return true;
    } catch (error) {
      DiaryService.add('[Play] 切换${season.label}失败：${_diagnostic(error)}');
      if (_current(ticket)) _stop();
      _notify();
      return false;
    } finally {
      _advancingSeason = false;
    }
  }

  void _clearSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepAt = null;
    _sleepMinutes = 0;
    _sleepAtEpisodeEnd = false;
  }

  void setSleepTimer({int minutes = 0, bool episodeEnd = false}) {
    if (_closed) return;
    _clearSleep();
    if (episodeEnd) {
      _sleepAtEpisodeEnd = true;
    } else if (minutes > 0) {
      final after = Duration(minutes: minutes);
      _sleepMinutes = minutes;
      _sleepAt = DateTime.now().add(after);
      _sleepTimer = Timer(after, () {
        _clearSleep();
        if (!_closed) _stop();
        _notify();
      });
    }
    _notify();
  }

  void _queueRecovery(String reason) {
    if (_closed || !_acceptErrors || _error != null) return;
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) return;
    final ticket = _generation;
    final position = player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_current(ticket) || !_foreground || !_acceptErrors) return;
      _pendingError = false;
      final state = player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover(reason));
    });
  }

  Future<void> _recover(String reason) async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    DiaryService.add(
      '[Play] 自动恢复 原因=$reason 处理=${action.name} 线路=${current.routeIndex + 1}/${current.routeCount}',
    );
    if (action != PlaybackRecoveryAction.stop) {
      await play(_index, position: position, recovery: action);
      return;
    }
    _resumePosition = position;
    final ticket = _generation;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        try {
          await saveProgress();
          _openedIndex = -1;
          await player.stop();
        } finally {
          await _release(current.session);
        }
      });
    } catch (_) {}
    if (!_current(ticket)) return;
    _loading = false;
    _localFailure = current.local;
    _loginRequired = false;
    final symptom = switch (reason) {
      'position_stalled_20s' => '画面长时间没有进度',
      'early_completion' => '视频提前结束',
      'open_exception' => '视频打开失败',
      'decoder_unavailable' => '设备硬解不了这个片源',
      _ => '播放器报错',
    };
    _error = current.local
        ? '$symptom，本地视频没能播放。可重试或改为在线播放。'
        : '$symptom，自动恢复未成功。可重试、换一集或选择其他清晰度。';
    _notify();
  }

  /// Exo / 原生内核都走 MediaCodec：硬解起不来时先把解码方式降为软解，
  /// 从原位置重开当前集。硬解能不能用是逐个片源的事，只影响这一集。
  Future<void>? _softDecoderRetry;

  Future<void> _retryWithSoftDecoder(String reason) {
    final running = _softDecoderRetry;
    if (running != null) return running;
    final retry = _retryWithSoftDecoderOnce(reason);
    _softDecoderRetry = retry;
    return retry;
  }

  /// 用户显式选了「硬解」：这一档的语义就是只用硬解，不自动改用软解。
  bool get _strictHardware =>
      store.playbackPreferences.televisionDecoder == TelevisionDecoder.hardware;

  Future<void> _retryWithSoftDecoderOnce(String reason) async {
    final plan = _plan;
    if (_closed || plan == null) return;
    if (_strictHardware) {
      DiaryService.add('[Play] 已选「硬解」，不自动改用软解（$reason）');
      return;
    }
    final position = currentPosition;
    DiaryService.add(
      '[Play] 解码器不可用（$reason），改用软解从 '
      '${position.toStringAsFixed(1)}s 重新打开',
    );
    await player.applyDecoder(TelevisionDecoder.software);
    if (_closed) return;
    await play(
      _index,
      position: position,
      recovery: PlaybackRecoveryAction.kernel,
      reuse: plan,
    );
  }

  Future<void> _release(String session) async {
    if (session.isEmpty) return;
    await repository.release(session).catchError((Object _) {});
  }

  /// Exo / 原生内核都无法通过解密属性解 CENC 媒体（原来是 mpv 的
  /// `decryption_key` 才能做），统一改由 Go 本地流服务器对该会话解密。
  Future<void> _prepareDecrypt(PlaybackPlan plan) async {
    if (plan.local || plan.decryptionKey.isEmpty) return;
    try {
      await repository.enableDecrypt(plan.session);
    } catch (error) {
      DiaryService.add('[Play] 启用服务端解密失败：${_diagnostic(error)}');
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  /// 解码偏好下发给内核。只区分「只用软解 / 只用硬解 / 优先硬解」，
  /// 不再有 mpv 的 hwdec、demuxer 属性需要逐条设置。
  ///
  /// 用户**显式**选了「硬解」时不自动降级：那一档就是要强制硬解，解不了
  /// 交给恢复流程明确报错。
  Future<void> _configure(EnginePlayer target, PlaybackPlan plan) async {
    await target.applyDecoder(store.playbackPreferences.televisionDecoder);
  }

  Future<void> play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recovery,
    bool playWhenReady = true,
    PlaybackPlan? reuse,
  }) async {
    if (!_usable || index < 0 || index >= detail.episodes.length) return;
    endBoost();
    _staleAudio = false;
    _cancelResumeWatchdog();
    // 切集策略：备用预热就绪（回执已收到）→ 秒切备用；备用未就绪（没预热
    // 或还在预热中）→ 不等它，立即释放备用资源，由主播放器接手完成这次
    // 切集（全量打开路径会先存进度再停旧集，「切了就是切了」）。
    final standbyEligible =
        recovery == null && position == 0 && _standbyIndex == index && !_online;
    if (standbyEligible) {
      if (_standbyOpening == null) {
        // 预热回执已收到（就绪或失败都算完成）：就绪就秒切备用；失败的
        // 情况由 _swapNative 尝试 swap 被拒后带着已解析计划走全量打开。
        return _switchToStandby(index, playWhenReady);
      }
      // 备用还在预热中：立即释放备用，主播放器接手。地址已经解析好就
      // 直接用（不重新取地址），没解析好才现场解析。
      final reuse = _standbyPlan;
      _standbyPlan = null;
      _dropStandby();
      // _standbyPlan 已清空，_dropStandby 不会认为备用开过，这里显式停用，
      // 别让还在预热的备用播放器占着解码器和带宽。
      if (_standby != null) {
        unawaited(_standby!.stop().catchError((Object _) {}));
      }
      _preloader.clear();
      return play(
        index,
        position: position,
        playWhenReady: playWhenReady,
        reuse: reuse,
      );
    }
    if (index != _index) _online = false;
    _dropStandby();
    final warmed = recovery == null
        ? _preloader.take(
            detail.drama,
            detail.episodes[index],
            quality: _quality,
            online: _online,
          )
        : null;
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _seekWatchdog?.cancel();
    danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recovery == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _openedAt = position;
    _index = index;
    _loading = true;
    _started = false;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loadingMessage = switch (recovery) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      PlaybackRecoveryAction.kernel => '正在切换播放内核',
      _ => '正在准备播放',
    };
    _notify();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    var installed = false;
    // 记录各阶段耗时：切集等待时间长时，能从日记看出是取地址慢、还是播放器初始化慢。
    final stopwatch = Stopwatch()..start();
    var markAddress = 0;
    var markOpen = 0;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        await saveProgress();
        if (!_current(ticket)) return;
        _openedIndex = -1;
        // 切了就是切了：立即停旧集、释放旧会话，不给"黑屏却还有声音"留可能。
        await player.stop();
        final previous = _plan;
        _plan = null;
        if (recovery == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null && !identical(previous, reuse)) {
          await _release(previous.session);
        }
      });
      if (!_current(ticket)) return;
      // 诊断：取地址开始与模式，两条取地址日记时间重叠说明有并发竞争。
      DiaryService.add(
        '[Play] 开始取地址（第${index + 1}集，${reuse != null ? '复用预热' : warmed != null ? '预热命中' : retained != null ? '备用线路' : '现场解析'}）',
      );
      prepared = reuse != null
          ? await _loader.use(reuse)
          : retained != null
          ? await _loader.fallback(retained!)
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              detail.drama,
              detail.episodes[index],
              quality: _quality,
              online: _online,
            );
      if (prepared == null) return;
      markAddress = stopwatch.elapsedMilliseconds;
      final plan = prepared;
      await _serialize(() async {
        if (!_current(ticket)) {
          await _release(plan.session);
          return;
        }
        if (plan.url.isEmpty) throw AppFailure('站源未返回播放地址，请重试');
        await _configure(player, plan);
        await _limitCache(player, !_engaged);
        await _selectAudio(player, true);
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        await _prepareDecrypt(plan);
        if (!_current(ticket)) {
          await _release(plan.session);
          return;
        }
        await player.open(
          plan.url,
          headers: plan.headers,
          start: position > 0
              ? Duration(milliseconds: (position * 1000).round())
              : null,
          play: _foreground && _playIntent,
        );
        markOpen = stopwatch.elapsedMilliseconds;
        if (!_current(ticket)) return;
        _openedIndex = index;
        _health.reset();
        await _setRate(_rate);
        if (!_current(ticket)) return;
        await _ensurePlaying();
        // 诊断里有 1.2s 的二次采样延时，不能 await：卡住打开完成会让
        // loading 迟迟不落、自动连播也等不到，测试里则表现为 ready 永远为假。
        unawaited(_reportDecoderDiagnostics());
        _loading = false;
        _notify();
        danmaku.setPlan(plan);
        _syncDanmaku();
        // 切集等待时间长时，从这里能看出慢在取播放地址还是播放器初始化。
        DiaryService.add(
          '[Play] 第 ${index + 1} 集打开耗时 ${stopwatch.elapsedMilliseconds}ms'
          '（取地址 ${markAddress}ms，播放器 ${markOpen - markAddress}ms，'
          '预加载${warmed != null ? '已命中' : '未命中'}）',
        );
      });
    } catch (error) {
      if (_current(ticket)) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery('open_exception');
        } else {
          if (prepared != null) await _release(prepared.session);
          if (_current(ticket)) {
            if (error is AppFailure && error.code == 'canceled') {
              // 取地址被我们自己的取消通道掐掉：多半是另一个会话同时取地址
              // （小窗自动连播时又开了新剧、快速退出再点开等），不是站源的
              // 错。自动重试一次，别让用户看到「暂时无法播放，context
              // canceled」这种死胡同；再次被取消才真正报错。
              DiaryService.add(
                '[Play] 取地址被取消，${_canceledRetry ? '不再重试' : '自动重试'}',
              );
              if (_canceledRetry) {
                _canceledRetry = false;
                _loading = false;
                _error = '播放请求被中断，请重试';
                _notify();
              } else {
                _canceledRetry = true;
                unawaited(
                  play(
                    index,
                    position: position,
                    recovery: recovery,
                    playWhenReady: _playIntent,
                  ).whenComplete(() => _canceledRetry = false),
                );
              }
              return;
            }
            if (error is AppFailure && error.code == 'timeout') {
              // 取地址超时（站源慢或核心请求名额排队满）：核心侧现在 25 秒
              // 就会失败并释放名额，自动重试一次往往就能过；连续超时才报错，
              // 别让用户盯着转圈一分多钟。
              DiaryService.add(
                '[Play] 取地址超时，${_timeoutRetry ? '不再重试' : '自动重试'}',
              );
              if (_timeoutRetry) {
                _timeoutRetry = false;
                _loading = false;
                _error = '获取播放地址超时，请重试或稍后再试';
                _notify();
              } else {
                _timeoutRetry = true;
                unawaited(
                  play(
                    index,
                    position: position,
                    recovery: recovery,
                    playWhenReady: _playIntent,
                  ).whenComplete(() => _timeoutRetry = false),
                );
              }
              return;
            }
            DiaryService.add('[Play] 无法播放：${_diagnostic(error)}');
            _loading = false;
            _localFailure = error is AppFailure && error.code == 'local_media';
            _loginRequired =
                error is AppFailure && error.code == 'source_login';
            _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
            _notify();
          }
        }
      } else if (prepared != null && !installed) {
        await _release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) await _release(warmed.session);
      if (retained != null) await _release(retained!.session);
    }
  }

  /// 下一集可能还在打开，稍等片刻就能直接切过去，
  /// 省掉重新取地址和初始化播放器的时间。

  Future<void> _swap(int index, bool playWhenReady) async {
    final plan = _standbyPlan!;
    final next = _standby!;
    DiaryService.add(
      '[Play] 第 ${index + 1} 集已预加载，直接切换'
      '${next.isNative ? '（原生）' : '（Exo）'}',
    );
    final previous = _player;
    final previousPlan = _plan;
    final volume = previous.state.volume;
    unawaited(saveProgress());
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _seekWatchdog?.cancel();
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    _recovery.reset();
    _playIntent = playWhenReady;
    _resumePosition = 0;
    _openedAt = 0;
    _index = index;
    _started = false;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loading = false;
    _standbyPlan = null;
    _standbyIndex = -1;
    _standbyOpen = false;
    _standbyOpening = null;
    _player = next;
    _standby = previous;
    _plan = plan;
    _bind();
    _openedIndex = index;
    _acceptErrors = true;
    final stopping = previous.stop().catchError((Object _) {});
    if (previousPlan != null) unawaited(_release(previousPlan.session));
    danmaku.setPlan(plan);
    _notify();
    _syncDanmaku();
    try {
      await _limitCache(next, false);
      await next.setVolume(volume);
      await _setRate(_rate);
      await stopping;
      await _selectAudio(next, true);
      if (_current(ticket) && _foreground && _playIntent) {
        await next.play();
      }
    } catch (_) {
      if (_current(ticket)) _queueRecovery('open_exception');
    }
  }

  void _prime() {
    if (_player.isNative) {
      unawaited(_primeNative());
      return;
    }
    final standby = _standby;
    final next = _index + 1;
    if (_closed ||
        standby == null ||
        _standbyIndex >= 0 ||
        !_preloader.ready ||
        next >= detail.episodes.length) {
      return;
    }
    _standbyIndex = next;
    final plan = _preloader.take(
      detail.drama,
      detail.episodes[next],
      quality: _quality,
      online: _online,
    );
    if (plan == null) {
      _standbyIndex = -1;
      return;
    }
    _standbyPlan = plan;
    final opening = _open(standby, plan);
    _standbyOpening = opening;
    unawaited(
      opening.whenComplete(() {
        if (identical(_standbyOpening, opening)) _standbyOpening = null;
      }),
    );
  }

  /// 原生内核的预热：不下发到第二个 EnginePlayer，而是让原生侧那个常驻的
  /// 备用 ExoPlayer 直接 prepare。它有自己的 SurfaceView，不需要 Flutter 参与。
  Future<void> _primeNative() async {
    final next = _index + 1;
    if (_closed ||
        _standbyIndex >= 0 ||
        !_preloader.ready ||
        next >= detail.episodes.length) {
      return;
    }
    final plan = _preloader.take(
      detail.drama,
      detail.episodes[next],
      quality: _quality,
      online: _online,
    );
    if (plan == null) return;
    _standbyIndex = next;
    _standbyPlan = plan;
    _standbyOpen = true;
    _standbyAt = DateTime.now();
    _notify();
    // 预热路径也必须先下发解密密钥：Go 侧只有会话带 cencKey 才走解密服务，
    // 否则备用播放器 prepare 拿到的是密文，切过去必然解码失败再走一遍完整打开。
    await _prepareDecrypt(plan);
    final opening = _player.preload(plan.url, headers: plan.headers);
    _standbyOpening = opening;
    unawaited(
      opening.whenComplete(() {
        if (identical(_standbyOpening, opening)) _standbyOpening = null;
      }),
    );
    _notify();
  }

  Future<void> _switchToStandby(int index, bool playWhenReady) {
    return _player.isNative
        ? _swapNative(index, playWhenReady)
        : _swap(index, playWhenReady);
  }

  /// 原生内核的切集：Surface 不重建，只把两张 SurfaceView 的位置对调，
  /// 所以这里没有任何「停旧播放器 / 等新播放器初始化」的动作。
  Future<void> _swapNative(int index, bool playWhenReady) async {
    final plan = _standbyPlan;
    if (plan == null) {
      // 状态不一致时先清掉预热标记，避免 play() 再次走进本方法形成递归。
      _standbyIndex = -1;
      _standbyOpen = false;
      _standbyOpening = null;
      return play(index, position: 0, playWhenReady: playWhenReady);
    }
    DiaryService.add('[Play] 第 ${index + 1} 集已预加载，直接切换（原生）');
    final previousPlan = _plan;
    unawaited(saveProgress());
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _seekWatchdog?.cancel();
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    _recovery.reset();
    _playIntent = playWhenReady;
    _resumePosition = 0;
    _openedAt = 0;
    _index = index;
    _started = false;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loading = false;
    _standbyPlan = null;
    _standbyIndex = -1;
    _standbyOpen = false;
    _standbyOpening = null;
    _plan = plan;
    _openedIndex = index;
    _acceptErrors = true;
    if (previousPlan != null) unawaited(_release(previousPlan.session));
    danmaku.setPlan(plan);
    _notify();
    _syncDanmaku();
    // 走到这里说明预热回执已收到（play() 只在 _standbyOpening == null 时
    // 进入本方法），swap 若被拒就是预热实际失败：带着已解析好的计划走
    // 完整打开，不重新取地址。
    if (_closed || !_current(ticket)) return;
    final swapped = await _player.swapToStandby();
    if (_closed || !_current(ticket)) return;
    if (!swapped) {
      DiaryService.add('[Play] 原生预热实例未就绪，携带已解析计划重新打开');
      return play(
        index,
        position: 0,
        playWhenReady: playWhenReady,
        reuse: plan,
      );
    }
    // 预热回执已含真实首帧（原生层以 READY + onRenderedFirstFrame 双门槛放行），
    // 接管后给一个短稳定窗吸收起播瞬间的短暂 BUFFERING，避免转圈闪现。
    _swapStableUntil = DateTime.now().millisecondsSinceEpoch + 400;
    if (_foreground && _playIntent) unawaited(_player.play());
  }

  Future<void> _open(EnginePlayer standby, PlaybackPlan plan) async {
    try {
      await _configure(standby, plan);
      await _limitCache(standby, true);
      await _selectAudio(standby, false);
      await _prepareDecrypt(plan);
      await standby.open(plan.url, headers: plan.headers, play: false);
    } catch (_) {
      if (identical(_standbyPlan, plan)) _dropStandby();
      return;
    }
    if (_closed || !identical(_standbyPlan, plan)) return;
    _standbyOpen = true;
    _standbyAt = DateTime.now();
    _notify();
  }

  void _dropStandby() {
    _cancelStandbyIdle();
    final plan = _standbyPlan;
    final opened = _standbyOpen || plan != null;
    _standbyPlan = null;
    _standbyIndex = -1;
    _standbyOpen = false;
    _standbyOpening = null;
    if (opened) unawaited(_standby?.stop().catchError((Object _) {}));
    if (plan != null) unawaited(_release(plan.session));
  }

  /// ExoPlayer 的缓冲由 LoadControl 决定，没有 mpv 的 `demuxer-max-bytes`
  /// 可调。保留签名，调用点不必逐个判断内核。
  Future<void> _limitCache(EnginePlayer target, bool limited) async {}

  /// 当前下载速率（字节/秒）。
  ///
  /// 原来读 mpv 的 `cache-speed` 属性；改用原生内核暴露的
  /// `totalBytesRead` 做差分。没有这个指标时返回 null，UI 不显示速率。
  Future<int?> networkSpeed() async {
    if (_closed || local) return null;
    if (_speedReading || _loading || !_foreground || !player.state.playing) {
      return _networkSpeed;
    }
    final resumeAt = _speedResumeAt;
    if (resumeAt != null) {
      final progressed =
          player.state.position > resumeAt + const Duration(milliseconds: 500);
      if (!progressed && DateTime.now().isBefore(_speedResumeDeadline!)) {
        return _networkSpeed;
      }
      _speedResumeAt = null;
      _speedResumeDeadline = null;
    }
    if (player.state.buffering) return _networkSpeed;
    _speedReading = true;
    try {
      final bytes = await player.bytesRead();
      if (bytes == null) return _networkSpeed;
      final now = DateTime.now();
      final previousBytes = _speedBytes;
      final previousAt = _speedBytesAt;
      _speedBytes = bytes;
      _speedBytesAt = now;
      if (previousBytes != null && previousAt != null) {
        final elapsed = now.difference(previousAt).inMilliseconds;
        final delta = bytes - previousBytes;
        // 采样窗口太短时差值噪声大，沿用上一次结果。
        if (elapsed >= 400 && delta >= 0) {
          _networkSpeed = (delta * 1000 / elapsed).round();
        }
      }
      return _networkSpeed;
    } finally {
      _speedReading = false;
    }
  }

  /// 音轨由 ExoPlayer 自行选择，mpv 的 `aid` 属性不存在，保留空实现。
  Future<void> _selectAudio(EnginePlayer target, bool enabled) async {}

  void start(int index, {double position = 0}) {
    if (!_usable) return;
    final wasEngaged = _engaged;
    _engaged = true;
    if (index != _index ||
        (position - _openedAt).abs() > .5 ||
        _error != null) {
      unawaited(play(index, position: position));
      return;
    }
    _playIntent = true;
    if (!wasEngaged) unawaited(_limitCache(player, false));
    if (ready) unawaited(player.play());
  }

  Future<void> retry() =>
      play(_index, position: currentPosition, playWhenReady: true);

  Future<void> switchOnline() {
    _online = true;
    return retry();
  }

  Future<bool> next() async {
    if (!hasNext) return false;
    await play(_index + 1);
    return true;
  }

  Future<bool> previous() async {
    if (!hasPrevious) return false;
    await play(_index - 1);
    return true;
  }

  void togglePlayback() {
    if (!_usable || !ready) return;
    endBoost();
    _playIntent = !player.state.playing;
    _health.reset();
    if (_playIntent) {
      _cancelStandbyIdle();
      final paused = _takePausedSeconds();
      if (paused >= 5) DiaryService.add('[Play] 恢复播放，已暂停 $paused 秒');
      if (!local && paused >= 5) _armResumeWatchdog();
      _holdNetworkSpeed();
    } else {
      _cancelResumeWatchdog();
      _pausedSince = DateTime.now();
      _scheduleStandbyIdle();
    }
    if (_playIntent && player.state.completed) {
      unawaited(play(_index));
      return;
    }
    if (_playIntent && _staleAudio) {
      _staleAudio = false;
      final position = player.state.position;
      if (player.state.duration > Duration.zero && position > Duration.zero) {
        unawaited(
          player
              .seek(position)
              .then(
                (_) => player.state.playing
                    ? Future<void>.value()
                    : player.playOrPause(),
              )
              .catchError((Object _) {}),
        );
      } else {
        unawaited(player.playOrPause());
      }
    } else {
      unawaited(player.playOrPause());
    }
    if (!_playIntent) unawaited(saveProgress());
    _syncDanmaku();
  }

  int _takePausedSeconds() {
    final since = _pausedSince;
    _pausedSince = null;
    if (since == null) return 0;
    return DateTime.now().difference(since).inSeconds;
  }

  void _armResumeWatchdog() {
    _cancelResumeWatchdog();
    final position = player.state.position;
    _resumeTimer = Timer(const Duration(seconds: 5), () {
      _resumeTimer = null;
      if (_closed || !_playIntent) return;
      if (player.state.position > position) return;
      DiaryService.add('[Play] 恢复后 5 秒没有进展，重新加载当前集');
      unawaited(_reviveCurrent());
    });
  }

  void _cancelResumeWatchdog() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  Future<void> _reviveCurrent() =>
      _reopen(Duration(milliseconds: (_resumePosition * 1000).round()));

  /// 打开完成后按当前播放意图校正一次播放状态。
  /// 打开过程中用户可能已经点了播放（`start` 里的 `ready` 判据此时为假），
  /// 而 `play` 参数在发起打开时就已经定死为 false，需要在这里补一次，
  /// 否则会一直停在首帧等用户再点一下。Exo 内核初始化更慢，最容易出现。
  Future<void> _ensurePlaying() async {
    if (_closed || !_foreground || !_playIntent) return;
    if (player.state.playing) return;
    try {
      await player.play();
    } catch (error) {
      DiaryService.add('[Play] 打开后自动播放失败：${_diagnostic(error)}');
    }
  }

  /// 把原生侧的解码器诊断写进播放诊断日记。
  ///
  /// 硬解初始化失败时 ExoPlayer 会静默回退软解，应用层完全感知不到失败原因，
  /// 只有原生侧记录下来的信息能说明到底是设备没有硬解，还是选中了硬解但初始化失败。
  Future<void> _collectDecoderDiagnostics() async {
    final lines = await AppDevice.takeDecoderDiagnostics();
    if (lines.isEmpty) return;
    // 开头补一句当前播放的基本信息，方便对照着看。
    final params = player.state.videoParams;
    final size = videoDisplaySize(params);
    final resolution = size == null
        ? '分辨率未知'
        : '${size.width.round()}x${size.height.round()}';
    DiaryService.add('[Video] 播放信息：内核=${player.kernel.label} 分辨率=$resolution');
    for (final line in lines) {
      DiaryService.add('[Video] $line');
    }
  }

  /// 播放地址打开后收集一次解码器诊断。
  ///
  /// 单独成一步而不是挂在自动播放里：自动播放可能被用户手动点击抢先，或本来就已在
  /// 播放，诊断就永远拉不到，日记里也就看不到真实解码情况。
  Future<void> _reportDecoderDiagnostics() async {
    if (_closed) return;
    try {
      await _collectDecoderDiagnostics();
      // 解码器是在轨道选定之后才初始化的，第一轮诊断可能还没产生信息。
      // 隔一小段时间再取一次，把真正跑起来的解码器记下来。
      if (_closed) return;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (_closed) return;
      await _collectDecoderDiagnostics();
    } catch (_) {
      // 诊断信息拿不到不影响播放。
    }
  }

  Future<void> _reopen(Duration target) async {
    if (_closed) return;
    final position = target.inMilliseconds / 1000;
    final plan = _plan;
    if (plan == null || plan.local || plan.url.isEmpty) {
      if (!local) await play(_index, position: position);
      return;
    }
    try {
      _health.reset();
      _staleAudio = false;
      if (_closed) return;
      await player.open(
        plan.url,
        headers: plan.headers,
        start: position > 0
            ? Duration(milliseconds: (position * 1000).round())
            : null,
        play: _foreground && _playIntent,
      );
      _openedIndex = _index;
      await _ensurePlaying();
    } catch (_) {
      if (_closed) return;
      await play(_index, position: position);
    }
  }

  void _scheduleStandbyIdle() {
    _cancelStandbyIdle();
    if (_standby == null) return;
    _standbyIdleTimer = Timer(const Duration(minutes: 1), () {
      _standbyIdleTimer = null;
      if (_closed || _playIntent || _standbyIndex < 0) return;
      _dropStandby();
    });
  }

  void _cancelStandbyIdle() {
    _standbyIdleTimer?.cancel();
    _standbyIdleTimer = null;
  }

  Future<bool> seekTo(Duration target) async {
    if (!_usable || !ready) return false;
    _cancelResumeWatchdog();
    final ticket = ++_seekSequence;
    final generation = _generation;
    danmaku.beginSeek();
    var succeeded = false;
    try {
      await player.seek(target);
      succeeded = true;
    } catch (error) {
      DiaryService.add('[Play] 跳转失败 目标=${target.inSeconds}s：$error');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        danmaku.endSeek(succeeded ? target : player.state.position);
      }
    }
    if (succeeded && ticket == _seekSequence) _watchSeek(target);
    return succeeded;
  }

  void _watchSeek(Duration target) {
    _seekWatchdog?.cancel();
    final ticket = _seekSequence;
    Duration? settled;
    _seekWatchdog = Timer(const Duration(milliseconds: 2500), () {
      if (!_seekWatchStillValid(ticket)) return;
      settled = player.state.position;
      _seekWatchdog = Timer(const Duration(milliseconds: 2500), () {
        _seekWatchdog = null;
        if (!_seekWatchStillValid(ticket)) return;
        final position = player.state.position;
        if ((position - target).abs() <= const Duration(seconds: 2)) return;
        if (position > settled! + const Duration(milliseconds: 800)) return;
        DiaryService.add(
          '[Play] 跳转未生效 目标=${target.inSeconds}s '
          '位置=${position.inSeconds}s，重新打开当前线路',
        );
        unawaited(_reopen(target));
      });
    });
  }

  bool _seekWatchStillValid(int ticket) =>
      !_closed &&
      ticket == _seekSequence &&
      _playIntent &&
      _foreground &&
      !_loading &&
      _error == null;

  Duration? seekBy(int seconds) {
    final duration = player.state.duration;
    if (!ready || duration <= Duration.zero) return null;
    final target = Duration(
      milliseconds: (player.state.position.inMilliseconds + seconds * 1000)
          .clamp(0, duration.inMilliseconds),
    );
    unawaited(seekTo(target));
    return target;
  }

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    return _rates.catchError((Object _) {});
  }

  void beginBoost() {
    if (!ready || _boostTimer != null || _boosting) return;
    _boostTimer = Timer(const Duration(milliseconds: 350), () {
      _boostTimer = null;
      if (_closed ||
          !ready ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      unawaited(_setRate(_rate));
      _notify();
    });
  }

  void holdBoost() {
    if (!_usable || _boosting) return;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = true;
    unawaited(_setRate(_rate));
    _notify();
  }

  void setBoostLocked(bool locked) {
    if (_boostLocked == locked) return;
    if (locked) {
      holdBoost();
      _boostLocked = true;
      _notify();
    } else {
      _boostLocked = false;
      endBoost();
      _notify();
    }
  }

  void setLocked(bool locked) {
    if (_locked == locked) return;
    _locked = locked;
    _notify();
  }

  bool endBoost() {
    if (_boostLocked) return false;
    final boosted = _boosting;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(_speed));
      _notify();
    }
    return boosted;
  }

  void setVolume(double value) {
    final volume = value.clamp(0.0, 100.0);
    if (volume > 0) {
      _unmutedVolume = volume;
      _volumeTimer?.cancel();
      _volumeTimer = Timer(const Duration(milliseconds: 500), _saveVolume);
    }
    _applyVolume(volume);
  }

  void _saveVolume() {
    _volumeTimer = null;
    unawaited(store.setPlayerVolume(_unmutedVolume).catchError((Object _) {}));
  }

  void _applyVolume(double volume) {
    if (!player.state.playing) _staleAudio = true;
    unawaited(player.setVolume(volume));
  }

  double changeVolume(double delta) {
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    setVolume(volume);
    return volume;
  }

  double toggleMute() {
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    _applyVolume(target);
    return target;
  }

  Future<void> _savePreferences(PlaybackPreferences preferences) async {
    if (!_usable) throw StateError('当前用户已变更');
    await store.setPlaybackPreferences(preferences);
    if (!_usable) throw StateError('当前用户已变更');
  }

  Future<void> setSpeed(double value) async {
    if (value == _speed) return;
    await _savePreferences(_preferences.copyWith(speed: value));
    _speed = value;
    _notify();
    if (!_boosting) await _setRate(value);
  }

  Future<void> setVideoFit(VideoFit value) async {
    if (value == _videoFit) return;
    final previous = _videoFit;
    _videoFit = value;
    _notify();
    try {
      await _savePreferences(_preferences);
    } catch (_) {
      if (_videoFit == value) {
        _videoFit = previous;
        _notify();
      }
      rethrow;
    }
  }

  Future<void> setQuality(int value) async {
    if (value == _quality) return;
    await _savePreferences(_preferences.copyWith(quality: value));
    _quality = value;
    _preloader.clear();
    _notify();
    if (_plan?.local == true) return;
    await play(
      _index,
      position: currentPosition,
      playWhenReady: _error != null || player.state.playing,
    );
  }

  Future<void> toggleDanmaku() async {
    if (!danmakuSupported) return;
    final enabled = !_danmakuEnabled;
    await _savePreferences(_preferences.copyWith(danmaku: enabled));
    _danmakuEnabled = enabled;
    danmaku.setEnabled(enabled);
    _syncDanmaku();
    _notify();
  }

  Future<void> setDanmakuScale(double value) async {
    final scale = value.clamp(danmakuScaleMin, danmakuScaleMax);
    await _savePreferences(_preferences.copyWith(danmakuScale: scale));
    _notify();
  }

  Future<void> setDanmakuColor(int value) async {
    await _savePreferences(_preferences.copyWith(danmakuColor: value));
    _notify();
  }

  Future<void> setDanmakuOpacity(double value) async {
    final opacity = value.clamp(.1, 1.0);
    await _savePreferences(_preferences.copyWith(danmakuOpacity: opacity));
    _notify();
  }

  Future<void> setDanmakuBold(bool value) async {
    await _savePreferences(_preferences.copyWith(danmakuBold: value));
    _notify();
  }

  Future<void> setDanmakuStroke(double value) async {
    final stroke = value.clamp(danmakuStrokeMin, danmakuStrokeMax);
    await _savePreferences(_preferences.copyWith(danmakuStroke: stroke));
    _notify();
  }

  Future<void> setDanmakuShadow(double value) async {
    final shadow = value.clamp(danmakuShadowMin, danmakuShadowMax);
    await _savePreferences(_preferences.copyWith(danmakuShadow: shadow));
    _notify();
  }

  Future<void> setDanmakuSpeed(double value) async {
    final speed = value.clamp(danmakuSpeedMin, danmakuSpeedMax);
    await _savePreferences(_preferences.copyWith(danmakuSpeed: speed));
    _notify();
  }

  Future<void> setDanmakuCoverage(DanmakuCoverage value) async {
    await _savePreferences(_preferences.copyWith(danmakuCoverage: value));
    _notify();
  }

  Future<void> setDanmakuMerge(DanmakuMerge value) async {
    await _savePreferences(_preferences.copyWith(danmakuMerge: value));
    _notify();
  }

  Future<void> setDanmakuWords(List<String> words) async {
    final normalized = normalizeDanmakuWords(words);
    await _savePreferences(_preferences.copyWith(danmakuWords: normalized));
    _notify();
  }

  void setForeground(bool visible) {
    if (_closed) return;
    _setVisible(visible);
    final foreground = visible || _backgroundPlayback;
    if (_foreground == foreground) return;
    DiaryService.add(foreground ? '[Play] 应用回到前台' : '[Play] 应用不可见，暂停播放');
    _foreground = foreground;
    _health.reset();
    _sync();
    if (!foreground) {
      endBoost();
      _playIntent = false;
      _pausedSince = DateTime.now();
      _cancelResumeWatchdog();
      _cancelStandbyIdle();
      _dropStandby();
      _preloader.clear();
      unawaited(player.pause());
      unawaited(saveProgress());
    } else {
      _holdNetworkSpeed();
      if (_pendingError) _queueRecovery('foreground_pending_error');
    }
  }

  void _setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (!visible && _backgroundPlayback) {
      DiaryService.add('[Play] 应用不可见，后台继续播放');
    }
  }

  Future<void> saveProgress({bool quiet = false}) async {
    if (!_engaged || _openedIndex < 0 || store.profileEpoch != _epoch) return;
    final position = player.state.position.inMilliseconds / 1000;
    final duration = player.state.duration.inMilliseconds / 1000;
    if (position < .1) return;
    final key = '${detail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == key &&
        _saveWarning == null &&
        (quiet || !_savedQuietly)) {
      return;
    }
    final entry = WatchEntry(
      drama: repository.catalogUpdates.current(detail.drama),
      episode: detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await store.saveWatch(entry, quiet: quiet);
      _savedProgressKey = key;
      _savedQuietly = quiet;
      if (_saveWarning != null) {
        _saveWarning = null;
        _notify();
      }
    } catch (_) {
      if (_saveWarning == null) {
        _saveWarning = '观看进度尚未保存，请检查存储空间后重试。';
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    // 播放器最先释放：本方法后面任何一步若抛异常，也不能让解码器和声音继续跑
    // （退出后音频仍在播放最常见的原因就是释放被跳过或被排队操作顶掉）。
    try {
      unawaited(player.dispose());
    } catch (_) {}
    try {
      unawaited(_standby?.dispose());
    } catch (_) {}
    unawaited(saveProgress());
    store.removeListener(_accessChanged);
    store.removeListener(_syncDanmakuOptions);
    store.removeListener(_syncMedia);
    MediaControls.instance.release(this);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _boostTimer?.cancel();
    _stallTimer?.cancel();
    _seekWatchdog?.cancel();
    _volumeTimer?.cancel();
    _sleepTimer?.cancel();
    _standbyIdleTimer?.cancel();
    _resumeTimer?.cancel();
    if (_volumeTimer != null) _saveVolume();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    danmaku.dispose();
    _preloader.dispose();
    final session = _plan?.session ?? '';
    unawaited(_release(session));
    final standbyPlan = _standbyPlan;
    if (standbyPlan != null) unawaited(_release(standbyPlan.session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _rates.catchError((Object _) {});
      }),
    );
    super.dispose();
  }
}
