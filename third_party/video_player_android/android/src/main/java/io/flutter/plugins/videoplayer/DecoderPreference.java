// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import androidx.annotation.Nullable;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import java.util.ArrayList;
import java.util.List;

/**
 * 全局解码器偏好。
 *
 * <p>Flutter 侧「解码方式」选软件解码时通过 duanju/device 通道置位 {@link #softwareOnly}，
 * ExoPlayer 就只用系统软解（c2.android.* / OMX.google.*），不再硬碰电视盒子上容易崩溃的
 * 硬件解码器；某类格式没有软解时退回默认的硬解列表，交给 Flutter 层的 MPV 兜底。
 */
public final class DecoderPreference {
  private DecoderPreference() {}

  /** 是否只使用软件解码器。 */
  public static volatile boolean softwareOnly = false;

  /**
   * 解码器诊断信息。
   *
   * <p>硬解初始化失败时 ExoPlayer 会静默回退到软解，应用层看不到失败原因。这里把设备上
   * 可用的解码器、实际选中的解码器、以及初始化失败的原因攒起来，由播放诊断日记取走显示。
   */
  private static final List<String> diagnostics = new ArrayList<>();

  /** 记录一条解码器诊断信息。 */
  public static void addDiagnostic(String message) {
    if (message == null || message.isEmpty()) {
      return;
    }
    synchronized (diagnostics) {
      // 诊断只保留最近的若干条，避免长时间播放后无限增长。
      if (diagnostics.size() >= 50) {
        diagnostics.remove(0);
      }
      diagnostics.add(message);
    }
  }

  /** 应用上下文，供查询解码器能力时使用。 */
  @Nullable private static Context appContext;

  /** 记录应用上下文。 */
  public static void setAppContext(@Nullable Context context) {
    appContext = context;
  }

  /** 取应用上下文。 */
  @Nullable
  public static Context getAppContext() {
    return appContext;
  }

  /** 取走并清空累积的解码器诊断信息。 */
  public static List<String> takeDiagnostics() {
    synchronized (diagnostics) {
      List<String> out = new ArrayList<>(diagnostics);
      diagnostics.clear();
      return out;
    }
  }

  public static final MediaCodecSelector SOFTWARE_ONLY =
      (mimeType, requiresSecureDecoder, requiresTunnelingDecoder) -> {
        List<MediaCodecInfo> infos =
            MediaCodecUtil.getDecoderInfos(
                mimeType, requiresSecureDecoder, requiresTunnelingDecoder);
        List<MediaCodecInfo> software = new ArrayList<>();
        for (MediaCodecInfo info : infos) {
          if (info.softwareOnly) {
            software.add(info);
          }
        }
        return software.isEmpty() ? infos : software;
      };
}
