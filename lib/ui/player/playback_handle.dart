import '../../core_bridge.dart';
import '../../diary_service.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_engine.dart';
import '../../playback_preferences.dart';
import '../../playback_session.dart';

class PlaybackHandle {
  PlaybackHandle({
    required AppRepository repository,
    required LocalStore store,
    required DramaDetail detail,
    required int index,
    double position = 0,
    bool autoplay = true,
    bool preopen = true,
  }) {
    final preferred = store.playbackPreferences.playbackKernel;
    // 这台设备之前 ExoPlayer 硬解失败过（比如电视盒子解不了高 level 的
    // HEVC），直接起 MPV，免得上一次播放的失败再重演一遍。
    final kernel = preferred == PlaybackKernel.exo && store.exoDecoderBroken
        ? PlaybackKernel.mpv
        : preferred;
    if (kernel != preferred) {
      DiaryService.add('[Play] 本机 ExoPlayer 解码失败过，改用 MPV 内核打开');
    }
    final main = EnginePlayer.open(kernel: kernel);
    final standby = preopen ? EnginePlayer.open(kernel: kernel) : null;
    session = PlaybackSession(
      repository: repository,
      store: store,
      detail: detail,
      player: main,
      standby: standby,
      index: index,
      position: position,
      autoplay: autoplay,
    );
  }

  late final PlaybackSession session;

  void dispose() => session.dispose();
}
