import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_device.dart';
import '../../local_store.dart';
import '../../picture_in_picture.dart';
import '../../playback_engine.dart';
import '../../playback_session.dart';
import '../app_scope.dart';
import 'landscape_player_page.dart';
import 'mini_player.dart';
import 'playback_handle.dart';
import 'player_page.dart';
import 'portrait_player_page.dart';
import 'television_player_page.dart';

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key, required this.store, required this.handle});
  final LocalStore store;
  final PlaybackHandle handle;

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  final _padFullscreen = ValueNotifier(false);
  final _pageScope = FocusScopeNode(debugLabel: 'playbackPage');
  final _pip = PictureInPicture.instance;
  late bool _wideVideo = _measure();
  MediaQueryData? _media;
  bool _shown = false;
  bool _locked = false;
  EnginePlayer? _bound;
  StreamSubscription<bool>? _playing;

  PlaybackSession get _session => widget.handle.session;

  bool _measure() => _session.aspectKnown && _session.aspectRatio >= 1;

  bool get _television =>
      AppScope.formFactorOf(context) == FormFactor.television;

  @override
  void initState() {
    super.initState();
    _session.addListener(_changed);
    _padFullscreen.addListener(_padFullscreenChanged);
    _pip.addListener(_pipChanged);
    _pip.onAction = _action;
    _bind();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _session.removeListener(_changed);
    _pip.removeListener(_pipChanged);
    if (_pip.onAction == _action) _pip.onAction = null;
    _pip.clear();
    unawaited(_playing?.cancel());
    _pageScope.dispose();
    if (_padFullscreen.value) _applyPadFullscreen(false);
    _padFullscreen.dispose();
    unawaited(AppDevice.resetBrightness());
    widget.handle.dispose();
    super.dispose();
  }

  void _changed() {
    _bind();
    _sync();
    final wide = _measure();
    if (wide != _wideVideo) setState(() => _wideVideo = wide);
    if (_session.locked != _locked) {
      _locked = _session.locked;
      _holdOrientation(_locked);
    }
  }

  void _holdOrientation(bool locked) {
    if (!locked) {
      unawaited(AppDevice.releaseHeldOrientation());
      return;
    }
    final landscape =
        (_media ?? MediaQuery.of(context)).orientation == Orientation.landscape;
    unawaited(AppDevice.holdOrientation(landscape: landscape));
  }

  void _bind() {
    final player = _session.player;
    if (identical(player, _bound)) return;
    _bound = player;
    unawaited(_playing?.cancel());
    _playing = player.stream.playing.listen((_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    final session = _session;
    final playing = session.player.state.playing;
    _pip.update(
      aspectRatio: session.aspectRatio,
      playing: playing,
      hasPrevious: session.hasPrevious,
      hasNext: session.hasNext,
      autoEnter:
          playing &&
          !_television &&
          widget.store.playbackPreferences.autoPictureInPicture,
    );
  }

  void _pipChanged() {
    if (!mounted) return;
    final shown = _pip.shown;
    if (shown && !_shown) _closeRoutesAbove();
    if (!shown && _shown) _pageScope.requestFocus();
    _shown = shown;
    if (!_television) {
      _session.setForeground(
        playerVisible(WidgetsBinding.instance.lifecycleState),
      );
    }
    _sync();
    setState(() {});
  }

  void _closeRoutesAbove() {
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) return;
    Navigator.of(context).popUntil((other) => other == route);
  }

  void _action(String action) {
    switch (action) {
      case 'toggle':
        _session.togglePlayback();
      case 'previous':
        unawaited(_session.previous());
      case 'next':
        unawaited(_session.next());
    }
  }

  Future<void> _enterMini() async {
    _closeRoutesAbove();
    _session.setLocked(false);
    await _pip.enter(_session.aspectRatio);
  }

  void _padFullscreenChanged() {
    _applyPadFullscreen(_padFullscreen.value);
    setState(() {});
  }

  void _applyPadFullscreen(bool full) {
    unawaited(
      AppDevice.setPlayerOrientation(
        full ? PlayerOrientation.lockedLandscape : PlayerOrientation.auto,
      ),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      ).catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = MediaQuery.of(context);
    final shown = _pip.shown || _pip.leaving && live.size != _media?.size;
    if (!shown || _media == null) _media = live;
    return Stack(
      fit: StackFit.expand,
      children: [
        FocusScope(
          node: _pageScope,
          autofocus: true,
          child: Offstage(
            offstage: shown,
            child: MediaQuery(
              data: _media!,
              child: Builder(builder: _page),
            ),
          ),
        ),
        if (shown) PictureInPictureView(handle: widget.handle),
      ],
    );
  }

  Widget _page(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final mini = _pip.available ? () => unawaited(_enterMini()) : null;
    final portraitStyle = widget.store.playbackPreferences.portraitStyleForWide;
    return switch (form) {
      FormFactor.pad || FormFactor.window => _padPage(context, mini),
      FormFactor.phone
          when _wideVideo &&
              !(portraitStyle &&
                  MediaQuery.orientationOf(context) == Orientation.portrait) =>
        LandscapePlayerPage(
          store: widget.store,
          handle: widget.handle,
          followSensor: !portraitStyle,
          onMiniWindow: mini,
        ),
      FormFactor.phone => PortraitPlayerPage(
        store: widget.store,
        handle: widget.handle,
        onFullscreen: _wideVideo
            ? () => unawaited(
                AppDevice.setPlayerOrientation(PlayerOrientation.landscape),
              )
            : null,
        onMiniWindow: mini,
      ),
      FormFactor.television => TelevisionPlayerPage(handle: widget.handle),
    };
  }

  Widget _padPage(BuildContext context, VoidCallback? mini) {
    final size = MediaQuery.sizeOf(context);
    if (_padFullscreen.value || size.width > size.height) {
      return PlayerPage(
        store: widget.store,
        handle: widget.handle,
        padFullscreen: _padFullscreen,
        onMiniWindow: mini,
      );
    }
    final portraitStyle = widget.store.playbackPreferences.portraitStyleForWide;
    return _wideVideo && !portraitStyle
        ? LandscapePlayerPage(
            store: widget.store,
            handle: widget.handle,
            onFullscreen: () => _padFullscreen.value = true,
            onMiniWindow: mini,
          )
        : PortraitPlayerPage(
            store: widget.store,
            handle: widget.handle,
            onFullscreen: _wideVideo ? () => _padFullscreen.value = true : null,
            onMiniWindow: mini,
          );
  }
}
