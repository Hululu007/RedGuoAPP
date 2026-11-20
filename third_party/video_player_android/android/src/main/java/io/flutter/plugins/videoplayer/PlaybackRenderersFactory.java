// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer;
import java.util.List;

/**
 * 带解码器诊断的渲染器工厂。
 *
 * <p>ExoPlayer 在硬件解码器初始化失败时会静默回退到软解并继续播放，应用层完全看不到失败
 * 原因，日志里只表现为「硬解用不上」。这里把关键信息记录到 {@link DecoderPreference}，
 * 由播放诊断日记取走显示，用来判断到底是设备没有硬解、还是选中了硬解但初始化失败。
 */
public final class PlaybackRenderersFactory extends DefaultRenderersFactory {

  @NonNull private final Context context;

  public PlaybackRenderersFactory(@NonNull Context context) {
    super(context);
    this.context = context;
    // 记下应用上下文：查询解码器能力（profile/level、分辨率、帧率）时要用。
    DecoderPreference.setAppContext(context.getApplicationContext());
    // 硬件解码器初始化失败时自动尝试其它解码器，避免整条视频直接播不出来。
    setEnableDecoderFallback(true);
  }

  @NonNull
  @Override
  protected androidx.media3.exoplayer.mediacodec.MediaCodecAdapter.Factory getCodecAdapterFactory() {
    // 换成带诊断的版本：捕获 MediaCodec 创建/configure/start 的失败原因，
    // 并记录真正跑起来的解码器名字。
    return new DiagnosticMediaCodecAdapterFactory(context);
  }

  @NonNull
  @Override
  protected void buildVideoRenderers(
      @NonNull Context context,
      int extensionRendererMode,
      @NonNull MediaCodecSelector mediaCodecSelector,
      boolean enableDecoderFallback,
      @Nullable android.os.Handler eventHandler,
      @Nullable VideoRendererEventListener eventListener,
      long allowedVideoJoiningTimeMs,
      @NonNull java.util.ArrayList<androidx.media3.exoplayer.Renderer> out) {
    super.buildVideoRenderers(
        context,
        extensionRendererMode,
        logDecoders(mediaCodecSelector),
        enableDecoderFallback,
        eventHandler,
        eventListener,
        allowedVideoJoiningTimeMs,
        out);
  }

  /** 包一层 selector，把设备上可用的解码器打印出来，其余行为不变。 */
  private static MediaCodecSelector logDecoders(MediaCodecSelector selector) {
    return (mimeType, requiresSecureDecoder, requiresTunnelingDecoder) -> {
      List<MediaCodecInfo> infos =
          selector.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder);
      StringBuilder builder = new StringBuilder();
      builder.append(mimeType).append(" 设备可用解码器 ").append(infos.size()).append(" 个:");
      for (MediaCodecInfo info : infos) {
        builder.append(' ').append(info.name).append(info.softwareOnly ? "(软解)" : "(硬解)");
      }
      DecoderPreference.addDiagnostic(builder.toString());
      return infos;
    };
  }

  /**
   * 把「这条轨道被哪些解码器支持」写进诊断。
   *
   * <p>用于区分两种情况：解码器能力不足（profile/level、分辨率、帧率不满足）导致没被选中，
   * 还是能力都满足、但真正初始化时失败。
   */
  public static void describeDecoderSupport(@NonNull Context context, @NonNull Format format) {
    String mimeType = format.sampleMimeType;
    if (mimeType == null) {
      return;
    }
    List<MediaCodecInfo> infos;
    try {
      infos = MediaCodecUtil.getDecoderInfos(mimeType, false, false);
    } catch (Throwable error) {
      DecoderPreference.addDiagnostic("查询解码器能力失败：" + error);
      return;
    }
    StringBuilder builder = new StringBuilder();
    builder.append("轨道支持情况：");
    boolean anySupported = false;
    for (MediaCodecInfo info : infos) {
      boolean supported;
      String reason = "";
      try {
        supported = info.isFormatSupported(context, format);
        if (!supported) {
          supported = info.isFormatFunctionallySupported(context, format);
        }
      } catch (Throwable error) {
        supported = false;
        reason = "判定异常";
      }
      if (supported) {
        anySupported = true;
      }
      builder
          .append(' ')
          .append(info.name)
          .append(info.softwareOnly ? "(软解)" : "(硬解)")
          .append(supported ? " 支持" : " 不支持")
          .append(reason.isEmpty() ? "" : "(" + reason + ")");
    }
    if (!anySupported) {
      builder.append(" —— 没有任何解码器支持这条轨道");
    }
    DecoderPreference.addDiagnostic(builder.toString());
  }
}
