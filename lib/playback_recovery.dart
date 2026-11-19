import 'models.dart';

enum PlaybackRecoveryAction { alternative, refresh, kernel, stop }

/// 判断播放器错误是否属于「解码器不可用」而不是网络/片源问题。
/// ExoPlayer 在电视盒子上硬解 HEVC 失败时抛出的是
/// `MediaCodecVideoRenderer error`，这类错误换线路没用，只会无限重试，
/// 应当换内核而不是换线路。
bool isDecoderFailure(String message) {
  final text = message.toLowerCase();
  const marks = [
    'mediacodec',
    'decoderinitializationexception',
    'decoder initialization',
    'decoder init failed',
    'no decoder',
    'decoder does not support',
    'decodersupport',
    'failed to initialize decoder',
  ];
  return marks.any(text.contains);
}

class PlaybackRecovery {
  static const maxAttempts = 3;
  int _attempts = 0;
  bool _refreshed = false;

  void reset() {
    _attempts = 0;
    _refreshed = false;
  }

  PlaybackRecoveryAction next(PlaybackPlan plan) {
    if (_attempts >= maxAttempts) {
      return PlaybackRecoveryAction.stop;
    }
    if (plan.hasAlternative) {
      _attempts++;
      return PlaybackRecoveryAction.alternative;
    }
    if (!_refreshed) {
      _attempts++;
      _refreshed = true;
      return PlaybackRecoveryAction.refresh;
    }
    return PlaybackRecoveryAction.stop;
  }
}

class PlaybackHealth {
  static const stallTimeout = Duration(seconds: 20);
  Duration? _position;
  DateTime? _lastProgress;

  void reset() {
    _position = null;
    _lastProgress = null;
  }

  bool stalled({
    required Duration position,
    required bool playing,
    required bool foreground,
    required DateTime now,
  }) {
    if (!playing || !foreground || position != _position) {
      _position = position;
      _lastProgress = now;
      return false;
    }
    _lastProgress ??= now;
    return now.difference(_lastProgress!) >= stallTimeout;
  }
}
