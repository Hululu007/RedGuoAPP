import 'core_bridge.dart';
import 'diary_service.dart';
import 'models.dart';

class PlaybackLoader {
  PlaybackLoader(this.repository);

  final AppRepository repository;
  int _generation = 0;
  bool _closed = false;

  Future<PlaybackPlan?> load(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) => _load(() async {
    if (online) {
      return repository.resolveOnline(drama, episode, quality: quality);
    }
    return repository.resolve(drama, episode, quality: quality);
  });

  Future<PlaybackPlan?> fallback(PlaybackPlan current) =>
      _load(() => repository.fallback(current));

  Future<PlaybackPlan?> use(PlaybackPlan prepared) =>
      _load(() async => prepared);

  Future<PlaybackPlan?> _load(Future<PlaybackPlan> Function() resolve) async {
    if (_closed) {
      return null;
    }
    final generation = ++_generation;
    try {
      // 不再先调 cancelPlayback：取消通道是全局的，两个会话同时在取地址时
      // （小窗自动连播 + 用户另开一部剧），新会话的这一下会把别人正在跑的
      // 取地址掐掉，对方直接报「context canceled」。旧请求的作废由
      // beginPlayback 的序列号检查和 generation 守卫负责，结果不会装错。
      if (_closed || generation != _generation) {
        return null;
      }
      final plan = await resolve();
      if (_closed || generation != _generation) {
        await repository.release(plan.session);
        return null;
      }
      return plan;
    } catch (_) {
      if (_closed || generation != _generation) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    // 诊断：确认取消通道的调用来自会话销毁。
    DiaryService.add('[Play] 播放加载器关闭（会话销毁）');
    await repository.cancelPlayback();
  }
}
