import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'danmaku_models.dart';
import 'local_store.dart';
import 'ranking_models.dart';
import 'catalog_updates.dart';
import 'cover_compat.dart';
import 'resource_settings.dart';
import 'diary_service.dart';
import 'app_update.dart';
import 'update_channel.dart';
import 'sorani_account.dart';
import 'source_modules.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

String _nativeRequest(String body) {
  final library = DynamicLibrary.open('libduanju_core.so');
  final request = library.lookupFunction<_NativeRequest, _DartRequest>(
    'DuanjuRequest',
  );
  final free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) {
      throw StateError('本地核心没有返回结果');
    }
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) {
      free(output);
    }
  }
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  Future<List<CastDevice>> castDevices() async => throw AppFailure('当前环境不支持投屏');
  Future<void> castPlay(
    CastDevice device,
    Drama drama,
    Episode episode, {
    int quality = 0,
    double position = 0,
  }) async => throw AppFailure('当前环境不支持投屏');
  Future<CastStatus> castStatus() async => throw AppFailure('当前环境不支持投屏');
  Future<void> castControl(String command, {double position = 0}) async {}
  Future<void> cancelDanmaku() async {}
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<List<DramaSeason>> seasons(Drama drama) async => const [];
  Future<Drama> followCheck(Drama drama) async => (await detail(drama)).drama;
  Future<CatalogPage> recommendations(
    String source,
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    RankingBoard board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;
  Future<List<SourceModule>> modules() async => const [];
  Future<ModuleStore> moduleIndex({bool all = false}) async =>
      throw AppFailure('当前环境不支持模块商店');
  Future<SourceModule> prepareModule({
    String file = '',
    String url = '',
    String indexed = '',
    bool bundled = false,
    bool all = false,
  }) async => throw AppFailure('当前环境不支持安装模块');
  Future<String> installModule(String token) async =>
      throw AppFailure('当前环境不支持安装模块');
  Future<void> uninstallModule(String id) async =>
      throw AppFailure('当前环境不支持卸载模块');
  Future<List<String>> suggestions(String source, String query) async =>
      const [];
  Future<int> cacheBytes() async => 0;
  Future<void> clearCache() async => throw AppFailure('当前环境不支持清理缓存');
  Future<List<String>> deleteAllData() async => throw AppFailure('当前环境不支持删除数据');
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<AppUpdate?> checkUpdate() async => null;
  Future<bool> sourceDevices(String source, {bool register = false}) async =>
      true;
  Future<SoraniAccount> soraniAccount() async => const SoraniAccount();
  Future<SoraniCaptcha> soraniCaptcha() async =>
      throw AppFailure('当前版本不支持登录青空次元');
  Future<SoraniAccount> soraniLogin({
    required String identifier,
    required String password,
    required String captchaId,
    required SoraniCaptchaTrack track,
  }) async => throw AppFailure('当前版本不支持登录青空次元');
  Future<SoraniAccount> soraniLogout() async => const SoraniAccount();
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<String> cover(Drama drama, {bool force = false});
  bool coverCached(Drama drama) => false;
  String? knownCover(Drama drama) => null;
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<void> cancelPlayback();
  Future<void> release(String session);
  Future<void> enableDecrypt(String session) async {}
}

class NativeRepository extends AppRepository {
  static final _coverPaths = <String, String>{};
  LocalStore? access;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  void _adminPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可修改本机资源设置');
    }
  }

  @override
  Future<ResourceSettings> resourceSettings() async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
  }

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      });
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelDanmaku() => _cancelReads('danmaku');

  @override
  Future<void> cancelPreload() => _cancelReads('preload');

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => PlaybackPlan.fromJson(
    await _read('preload', {
      'action': 'preload',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': online,
    }),
  );

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    if (plan.local || plan.session.isEmpty || plan.danmakuId.isEmpty) {
      throw AppFailure('本集暂不支持弹幕');
    }
    return DanmakuPage.fromJson(
      await _read('danmaku', {
        'action': 'danmaku',
        'playbackSession': plan.session,
        'startMs': startMs,
        'durationMs': durationMs,
      }),
      episodeId: plan.danmakuId,
      startMs: startMs,
      durationMs: durationMs,
    );
  }

  @override
  Future<List<CastDevice>> castDevices() async {
    final result = await _call({'action': 'cast', 'command': 'discover'});
    return [
      for (final row in (result['items'] as List? ?? []).whereType<Map>())
        (id: row['id'] as String? ?? '', name: row['name'] as String? ?? ''),
    ];
  }

  @override
  Future<void> castPlay(
    CastDevice device,
    Drama drama,
    Episode episode, {
    int quality = 0,
    double position = 0,
  }) async {
    await _call({
      'action': 'cast',
      'command': 'play',
      'device': device.id,
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'startMs': (position * 1000).round(),
    });
  }

  @override
  Future<CastStatus> castStatus() async {
    final result = await _call({'action': 'cast', 'command': 'status'});
    return (
      state: result['state'] as String? ?? 'stopped',
      position: intValue(result['positionMs']) / 1000,
      duration: intValue(result['durationMs']) / 1000,
    );
  }

  @override
  Future<void> castControl(String command, {double position = 0}) async {
    await _call({
      'action': 'cast',
      'command': command,
      'startMs': (position * 1000).round(),
    });
  }

  @override
  Future<void> cancelCatalog() => _cancelReads('catalog-');
  @override
  Future<void> cancelSuggestions() => _cancelReads('suggestions');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');

  @override
  Future<CatalogPage> recommendations(
    String source,
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    _authorize(source);
    return CatalogPage.fromJson(
      await _read('recommendations-$source-$genre', {
        'action': 'recommendations',
        'source': source,
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!SourceSite.byId(drama.source).metadata) return null;
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  Future<Drama> followCheck(Drama drama) async {
    _authorize(drama.source);
    final result = await _call({
      'action': 'followCheck',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final result = await _call({'action': 'rankingBoards'});
    return [
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isAvailable(board.source) &&
              (access?.allowsSource(board.source) ?? true),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    RankingBoard board, {
    int page = 1,
    bool force = false,
  }) async {
    _authorize(board.source);
    return RankingPage.fromJson(
      await _call({
        'action': 'rankings',
        'board': board.id,
        'page': page,
        'force': force,
      }),
    );
  }

  void _authorize(String source) {
    if (!SourceSite.isAvailable(source)) {
      throw AppFailure('当前版本不包含此站源');
    }
    if (access == null) return;
    if (access!.locked || !access!.allowsSource(source)) {
      throw AppFailure('当前用户没有此操作权限');
    }
  }

  @override
  Future<List<String>> suggestions(String source, String query) async {
    _authorize(source);
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'source': source,
      'query': query,
    });
    return (result['items'] as List? ?? []).whereType<String>().toList();
  }

  @override
  Future<int> cacheBytes() async =>
      intValue((await _call({'action': 'cache'}))['bytes']);

  @override
  Future<void> clearCache() async {
    await _call({'action': 'clearCache'});
    _coverPaths.clear();
  }

  @override
  Future<List<String>> deleteAllData() async {
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可删除全部数据');
    }
    final result = await _call({'action': 'deleteAllData'});
    return [
      for (final item in result['leftover'] as List? ?? const []) '$item',
    ];
  }

  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

  @override
  Future<AppUpdate?> checkUpdate() async {
    final channel = parseUpdateChannel(access?.updateChannel);
    final settings = await _updateSettings();
    final proxy = proxyFrom(
      settings?.proxyMode ?? 'auto',
      settings?.proxyUrl ?? '',
    );
    try {
      return await fetchLatestUpdate(
        channel: channel,
        installed: await currentVersionCode(),
        proxy: proxy,
      );
    } on UpdateFailure catch (error) {
      throw AppFailure(error.message);
    }
  }

  /// 资源设置可能因为权限或平台原因取不到，检查更新时退回直连。
  Future<ResourceSettings?> _updateSettings() async {
    try {
      return await resourceSettings();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> sourceDevices(String source, {bool register = false}) async =>
      (await _call({
        'action': 'sourceDevices',
        'source': source,
        if (register) 'command': 'register',
      }))['ready'] ==
      true;

  void _soraniPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可登录或退出青空次元账号');
    }
  }

  @override
  Future<SoraniAccount> soraniAccount() async =>
      SoraniAccount.fromJson(await _call({'action': 'soraniAccount'}));

  @override
  Future<SoraniCaptcha> soraniCaptcha() async {
    _soraniPermission();
    return SoraniCaptcha.fromJson(
      await _call({'action': 'soraniAccount', 'command': 'captcha'}),
    );
  }

  @override
  Future<SoraniAccount> soraniLogin({
    required String identifier,
    required String password,
    required String captchaId,
    required SoraniCaptchaTrack track,
  }) async {
    _soraniPermission();
    return SoraniAccount.fromJson(
      await _call({
        'action': 'soraniAccount',
        'command': 'login',
        'account': {
          'identifier': identifier,
          'password': password,
          'captchaId': captchaId,
          'track': track.toJson(),
        },
      }),
    );
  }

  @override
  Future<SoraniAccount> soraniLogout() async {
    _soraniPermission();
    return SoraniAccount.fromJson(
      await _call({'action': 'soraniAccount', 'command': 'logout'}),
    );
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'cast' && {'stop', 'active'}.contains(input['command']) ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
      if ({
        'catalog',
        'cached',
        'categories',
        'recommendations',
        'cachedRecommendations',
        'suggestions',
      }.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
            'cover',
            'prepareCover',
            'detail',
            'seasons',
            'metadata',
            'resolve',
            'preload',
          }.contains(action) ||
          action == 'cast' && input['command'] == 'play') {
        _authorize((input['drama'] as Map)['source'] as String);
      }
      final body = jsonEncode(input);
      final response =
          await Isolate.run(
            () => jsonDecode(_nativeRequest(body)) as Map<String, dynamic>,
          ).timeout(
            Duration(
              seconds: action == 'deleteAllData'
                  ? 620
                  : action == 'danmaku'
                  ? 15
                  : action == 'preload'
                  ? 20
                  : 70,
            ),
          );
      if (response['ok'] != true) {
        final raw = response['error'] as String? ?? '读取失败，请重试';
        // 诊断：取消类错误把 Go 侧的原始描述写进日记，
        // 「序列号过期」和「执行中被取消」会带不同的括号说明。
        if (raw.contains('context canceled')) {
          DiaryService.add('[Core] $action 取消详情：$raw');
        }
        final timeout =
            raw.contains('context deadline exceeded') ||
            raw.contains('排队超时');
        throw AppFailure(
          // 取地址超时给用户看人话，原始英文进日记。
          timeout && {'resolve', 'fallback', 'preload'}.contains(action)
              ? '获取播放地址超时，请重试'
              : raw,
          // Go 侧请求上下文被取消（context canceled）只可能来自应用自己的
          // 取消通道（退出播放、切换请求、另一个会话在同时取地址），不是站源
          // 的错。打上 canceled 标记，播放层据此自动重试而不是直接报错。
          // deadline exceeded 是 Go 侧 60 秒/25 秒超时到点，打 timeout 标记。
          code: raw.contains('context canceled')
              ? 'canceled'
              : timeout
              ? 'timeout'
              : response['code'] as String? ?? '',
        );
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'danmaku',
            'preload',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      DiaryService.add('[Core] ${input['action']} 超时');
      throw AppFailure(
        const {
              'catalog',
              'categories',
              'suggestions',
              'recommendations',
              'rankings',
              'rankingBoards',
              'metadata',
              'danmaku',
              'preload',
              'detail',
              'seasons',
              'followCheck',
              'resolve',
              'fallback',
            }.contains(input['action'])
            ? '站源响应超时，请重试'
            : '操作超时，请重试',
      );
    } catch (error) {
      DiaryService.add('[Core] ${input['action']} 调用异常：$error');
      final text = '$error';
      throw AppFailure(
        error is UnsupportedError ||
                text.contains('Failed to load dynamic library') ||
                text.contains('Failed to lookup symbol')
            ? '本地核心加载失败，请使用完整安装包重新安装'
            : '应用内部出错，请重试；反复出现时请带上日记反馈',
      );
    }
  }

  void _installSources(Object? rows) {
    SourceSite.install([
      for (final row in rows as List? ?? const [])
        SourceSite.fromJson(Map<String, dynamic>.from(row as Map)),
    ]);
    access?.sourcesChanged();
  }

  @override
  Future<List<SourceModule>> modules() async {
    _adminPermission();
    final result = await _call({'action': 'modules'});
    return [
      for (final row in result['items'] as List? ?? const [])
        SourceModule.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<ModuleStore> moduleIndex({bool all = false}) async {
    _adminPermission();
    final result = await _call({'action': 'moduleIndex', 'allSources': all});
    return ModuleStore([
      for (final row in result['items'] as List? ?? const [])
        ModuleIndexEntry.fromJson(Map<String, dynamic>.from(row as Map)),
    ], warning: result['warning'] as String? ?? '');
  }

  @override
  Future<SourceModule> prepareModule({
    String file = '',
    String url = '',
    String indexed = '',
    bool bundled = false,
    bool all = false,
  }) async {
    _adminPermission();
    return SourceModule.fromJson(
      await _call({
        'action': 'prepareModule',
        'file': file,
        'url': url,
        'source': indexed,
        'bundled': bundled,
        'allSources': all,
      }),
    );
  }

  @override
  Future<String> installModule(String token) async {
    _adminPermission();
    final result = await _call({'action': 'installModule', 'token': token});
    _installSources(result['sources']);
    return result['source'] as String;
  }

  @override
  Future<void> uninstallModule(String id) async {
    _adminPermission();
    final result = await _call({'action': 'uninstallModule', 'source': id});
    _installSources(result['sources']);
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    DiaryService.nativeLogPath = path.join(directory.path, 'logs', 'app.log');
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
      'cache': (await getApplicationCacheDirectory()).path,
    });
    _installSources(build['sources']);
    SystemProxyMonitor.start((value) async {
      await _call({'action': 'updateSystemProxy', 'systemProxy': value});
    });
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final result = await _read('categories-$source', {
      'action': 'categories',
      'source': source,
      'force': force,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => CatalogPage.fromJson(
    await _read(query.isEmpty ? 'catalog-$source' : 'catalog-$source-search', {
      'action': 'catalog',
      'source': source,
      'page': page,
      'query': query,
      'category': category,
      'force': force,
    }),
  );
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage.fromJson(
        await _call({
          'action': 'cached',
          'source': source,
          'category': category,
        }),
      );
  @override
  bool coverCached(Drama drama) =>
      _coverPaths.containsKey('${drama.id}\u0000${drama.cover}');

  @override
  String? knownCover(Drama drama) =>
      _coverPaths['${drama.id}\u0000${drama.cover}'];

  /// 只在原生转码失败时记住：下次命中缓存还要再试一次，成功后不再重复调用。
  static final _heicCovers = <String>{};

  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final key = '${drama.id}\u0000${drama.cover}';
    final known = force ? null : _coverPaths[key];
    if (known != null) {
      _authorize(drama.source);
      if (await File(known).exists()) {
        if (!_heicCovers.contains(key)) return known;
        final converted = await CoverCompat.convert(known);
        if (converted == null) return known;
        _heicCovers.remove(key);
        return _rememberCover(key, converted);
      }
      _coverPaths.remove(key);
      _heicCovers.remove(key);
    }
    final epoch = access?.profileEpoch;
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    var file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    // HEIC 交给系统 ImageDecoder 转 JPEG；转不了才退回原图，至少不阻塞列表。
    if (result['heic'] == true) {
      final converted = await CoverCompat.convert(file);
      if (converted != null) {
        file = converted;
      } else {
        _heicCovers.add(key);
      }
    }
    _authorize(drama.source);
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return _rememberCover(key, file);
  }

  String _rememberCover(String key, String path) {
    _coverPaths.remove(key);
    _coverPaths[key] = path;
    if (_coverPaths.length > 2000) _coverPaths.remove(_coverPaths.keys.first);
    return path;
  }

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail.fromJson(
    await _call({'action': 'detail', 'drama': drama.toJson()}),
  );

  @override
  Future<List<DramaSeason>> seasons(Drama drama) async {
    final result = await _call({'action': 'seasons', 'drama': drama.toJson()});
    return [
      for (final row in result['items'] as List? ?? const [])
        DramaSeason.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'sequence': ++_playbackSequence,
    }),
  );
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
    // 诊断：全应用只有会话销毁会走这里，出现这条日记就能锁定取消通道的调用方。
    DiaryService.add('[Core] cancelPlayback 调用（播放取消通道）');
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': true,
      'sequence': ++_playbackSequence,
    }),
  );

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }

  @override
  Future<void> enableDecrypt(String session) async {
    if (session.isEmpty) {
      return;
    }
    await _call({'action': 'enableDecrypt', 'session': session});
  }
}
