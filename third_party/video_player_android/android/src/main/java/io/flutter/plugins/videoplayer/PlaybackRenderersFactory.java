// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.media.MediaFormat;
import android.os.Handler;
import androidx.annotation.Nullable;
import androidx.media3.common.Format;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import java.util.ArrayList;

/**
 * 视频渲染器工厂：默认开启解码器回退，并把片源里过高的 HEVC 等级夹到设备支持的范围内。
 *
 * <p>等级夹取只影响传给解码器的 hvcC 头部，不改分辨率、码率与画面内容。
 */
@UnstableApi
public final class PlaybackRenderersFactory extends DefaultRenderersFactory {
  private static final int MAX_DROPPED_FRAMES_TO_NOTIFY = 50;

  public PlaybackRenderersFactory(Context context) {
    super(context);
    setEnableDecoderFallback(true);
  }

  @Override
  protected void buildVideoRenderers(
      Context context,
      @DefaultRenderersFactory.ExtensionRendererMode int extensionRendererMode,
      MediaCodecSelector mediaCodecSelector,
      boolean enableDecoderFallback,
      Handler eventHandler,
      VideoRendererEventListener eventListener,
      long allowedVideoJoiningTimeMs,
      ArrayList<Renderer> out) {
    if (extensionRendererMode != EXTENSION_RENDERER_MODE_OFF) {
      // 用到扩展渲染器时保持系统默认行为，避免丢能力。
      super.buildVideoRenderers(
          context,
          extensionRendererMode,
          mediaCodecSelector,
          enableDecoderFallback,
          eventHandler,
          eventListener,
          allowedVideoJoiningTimeMs,
          out);
      return;
    }
    out.add(
        new LevelTolerantVideoRenderer(
            context,
            mediaCodecSelector,
            enableDecoderFallback,
            eventHandler,
            eventListener,
            allowedVideoJoiningTimeMs));
  }

  /** 在交给 MediaCodec 之前修正 HEVC 等级声明。 */
  private static final class LevelTolerantVideoRenderer extends MediaCodecVideoRenderer {
    LevelTolerantVideoRenderer(
        Context context,
        MediaCodecSelector mediaCodecSelector,
        boolean enableDecoderFallback,
        @Nullable Handler eventHandler,
        @Nullable VideoRendererEventListener eventListener,
        long allowedVideoJoiningTimeMs) {
      super(
          new Builder(context)
              .setMediaCodecSelector(mediaCodecSelector)
              .setEnableDecoderFallback(enableDecoderFallback)
              .setEventHandler(eventHandler)
              .setEventListener(eventListener)
              .setAllowedJoiningTimeMs(allowedVideoJoiningTimeMs)
              .setMaxDroppedFramesToNotify(MAX_DROPPED_FRAMES_TO_NOTIFY));
    }

    @Override
    protected MediaFormat getMediaFormat(
        Format format,
        String codecMimeType,
        CodecMaxValues codecMaxValues,
        float operatingRate,
        boolean ignoreMaxBitrate,
        int maxInputSize) {
      MediaCodecInfo codecInfo = getCodecInfo();
      return super.getMediaFormat(
          HevcLevelClamp.clamp(format, codecInfo),
          codecMimeType,
          codecMaxValues,
          operatingRate,
          ignoreMaxBitrate,
          maxInputSize);
    }
  }
}
