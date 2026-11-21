import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_engine.dart';
import '../../playback_session.dart';

class PlaybackHandle {
  PlaybackHandle({
    required AppRepository repository,
    required LocalStore store,
    required DramaDetail detail,
    required int index,
    double position = 0,
    bool autoplay = true,
  }) {
    session = PlaybackSession(
      repository: repository,
      store: store,
      detail: detail,
      player: EnginePlayer.open(),
      index: index,
      position: position,
      autoplay: autoplay,
    );
  }

  late final PlaybackSession session;

  void dispose() => session.dispose();
}
