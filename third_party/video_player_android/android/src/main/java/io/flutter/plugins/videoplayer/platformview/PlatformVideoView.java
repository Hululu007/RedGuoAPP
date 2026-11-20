// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.platformview;

import android.content.Context;
import android.os.Build;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugin.platform.PlatformView;

/**
 * A class used to create a native video view that can be embedded in a Flutter app. It wraps an
 * {@link ExoPlayer} instance and displays its video content.
 */
public final class PlatformVideoView implements PlatformView {
  @NonNull private final SurfaceView surfaceView;

  /**
   * 当前绑定的播放器。
   *
   * <p>切集时 ExoPlayer 是新实例，平台视图可能被复用：如果这里继续拿着已释放的旧实例，
   * 新解码器就绑不上 Surface，画面只剩黑屏。所以播放器引用可替换，替换时立刻重新绑定。
   */
  @NonNull private ExoPlayer exoPlayer;

  /**
   * Constructs a new PlatformVideoView.
   *
   * @param context The context in which the view is running.
   * @param exoPlayer The ExoPlayer instance used to play the video.
   */
  @OptIn(markerClass = UnstableApi.class)
  public PlatformVideoView(@NonNull Context context, @NonNull ExoPlayer exoPlayer) {
    this.exoPlayer = exoPlayer;
    this.surfaceView = new VideoSurfaceView(context, this);

    setupSurfaceWithCallback();

    if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.N_MR1) {
      // Avoid blank space instead of a video on Android versions below 8 by adjusting video's
      // z-layer within the Android view hierarchy:
      surfaceView.setZOrderMediaOverlay(true);
    }
  }

  /**
   * 换成新的播放器，并把当前 Surface 交给它。
   *
   * @param exoPlayer the new player instance.
   */
  @OptIn(markerClass = UnstableApi.class)
  public void rebindPlayer(@NonNull ExoPlayer exoPlayer) {
    if (this.exoPlayer == exoPlayer) {
      return;
    }
    this.exoPlayer.clearVideoSurface();
    this.exoPlayer = exoPlayer;
    bindPlayerToSurface(exoPlayer, surfaceView.getHolder().getSurface());
    forceFirstFrameForAndroid9(exoPlayer);
  }

  private void setupSurfaceWithCallback() {
    surfaceView
        .getHolder()
        .addCallback(
            new SurfaceHolder.Callback() {
              @Override
              public void surfaceCreated(@NonNull SurfaceHolder holder) {
                bindPlayerToSurface(exoPlayer, holder.getSurface());
                forceFirstFrameForAndroid9(exoPlayer);
              }

              @Override
              public void surfaceChanged(
                  @NonNull SurfaceHolder holder, int format, int width, int height) {
                // Surface 重建后需要重新绑定，否则新解码器的画面没有出口。
                bindPlayerToSurface(exoPlayer, holder.getSurface());
              }

              @Override
              public void surfaceDestroyed(@NonNull SurfaceHolder holder) {
                // Use clearVideoSurface to ensure we only unbind if this surface is currently
                // active.
                exoPlayer.clearVideoSurface(holder.getSurface());
              }
            });
  }

  /** Binds the ExoPlayer to the provided surface. */
  static void bindPlayerToSurface(@NonNull ExoPlayer exoPlayer, @NonNull Surface surface) {
    if (surface.isValid()) {
      exoPlayer.setVideoSurface(surface);
    }
  }

  /**
   * Workaround for a rendering bug on Android 9 (API 28) where the decoder does not flush its
   * output buffer when a new surface is attached while the player is paused.
   */
  static void forceFirstFrameForAndroid9(@NonNull ExoPlayer exoPlayer) {
    if (Build.VERSION.SDK_INT == Build.VERSION_CODES.P && !exoPlayer.getPlayWhenReady()) {
      long position = exoPlayer.getCurrentPosition();
      exoPlayer.seekTo(position == 0 ? 1 : position);
    }
  }

  /**
   * A custom SurfaceView that re-attaches the player surface when the view becomes visible again,
   * such as after returning from a full-screen route transition.
   */
  private static class VideoSurfaceView extends SurfaceView {
    private final PlatformVideoView owner;

    public VideoSurfaceView(Context context, PlatformVideoView owner) {
      super(context);
      this.owner = owner;
    }

    @Override
    protected void onVisibilityChanged(@NonNull View changedView, int visibility) {
      super.onVisibilityChanged(changedView, visibility);
      // When the view becomes visible again, re-attach the current surface.
      if (visibility == View.VISIBLE && isShown()) {
        bindPlayerToSurface(owner.exoPlayer, getHolder().getSurface());
      }
    }
  }

  /**
   * Returns the view associated with this PlatformView.
   *
   * @return The SurfaceView used to display the video.
   */
  @NonNull
  @Override
  public View getView() {
    return surfaceView;
  }

  /** Disposes of the resources used by this PlatformView. */
  @Override
  public void dispose() {
    surfaceView.getHolder().getSurface().release();
  }
}
