import 'package:flutter/material.dart';

import '../../picture_in_picture.dart';
import 'playback_handle.dart';
import 'player_video.dart';

bool playerVisible(AppLifecycleState? state) =>
    state == AppLifecycleState.resumed ||
    state == AppLifecycleState.inactive ||
    PictureInPicture.instance.active;

class PictureInPictureView extends StatelessWidget {
  const PictureInPictureView({super.key, required this.handle});
  final PlaybackHandle handle;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: handle.session,
    builder: (context, _) {
      final session = handle.session;
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PlayerVideo(
              key: ValueKey(session.player),
              player: session.player,
            ),
            if (session.booting || session.ready && session.stalled)
              const IgnorePointer(
                child: Center(
                  child: SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
