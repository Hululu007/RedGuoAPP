// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package com.guoapp.player;

import android.content.Context;
import androidx.annotation.Nullable;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import java.util.ArrayList;
import java.util.List;

/**
 * 全局解码器偏好。
 *
 * <p>Flutter 侧「解码方式」通过 duanju/device 通道置位，ExoPlayer 据此挑选解码器：
 *
 * <ul>
 *   <li>{@link #softwareOnly}：只用系统软解（c2.android.* / OMX.google.*）；
 *   <li>{@link #hardwareOnly}：只用硬件解码器，且关闭解码器回退——硬解起不来就直接报错，
 *       不再悄悄换成软解（否则这一档和默认档没有区别）；
 *   <li>两者都为 false：优先硬解，失败按系统列表回退。
 * </ul>
 */
public final class DecoderPreference {
  private DecoderPreference() {}

  /** 是否只使用软件解码器。 */
  public static volatile boolean softwareOnly = false;

  /** 是否只使用硬件解码器（显式选「硬解」时置位）。 */
  public static volatile boolean hardwareOnly = false;

  /** 把当前偏好应用到渲染器工厂。 */
  public static void applyTo(DefaultRenderersFactory factory) {
    if (softwareOnly) {
      factory.setMediaCodecSelector(SOFTWARE_ONLY);
    } else if (hardwareOnly) {
      factory.setMediaCodecSelector(HARDWARE_ONLY);
      // 即使列表里只剩硬解，回退机制仍可能在硬解之间反复尝试；关掉后失败即报错，
      // 用户能明确看到「这台设备硬解不了这个片源」，而不是无声无息掉到软解。
      factory.setEnableDecoderFallback(false);
    }
  }

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

  /**
   * 只返回硬件解码器。
   *
   * <p>没有可用硬解时返回空列表，ExoPlayer 会抛 DecoderInitializationException，
   * 而不是退到软解——这正是「硬解」这一档要的行为。
   */
  public static final MediaCodecSelector HARDWARE_ONLY =
      (mimeType, requiresSecureDecoder, requiresTunnelingDecoder) -> {
        List<MediaCodecInfo> infos =
            MediaCodecUtil.getDecoderInfos(
                mimeType, requiresSecureDecoder, requiresTunnelingDecoder);
        List<MediaCodecInfo> hardware = new ArrayList<>();
        for (MediaCodecInfo info : infos) {
          if (!info.softwareOnly) {
            hardware.add(info);
          }
        }
        return hardware;
      };
}
