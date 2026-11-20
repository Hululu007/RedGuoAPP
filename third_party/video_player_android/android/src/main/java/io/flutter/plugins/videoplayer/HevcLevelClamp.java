// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import java.util.ArrayList;
import java.util.List;

/**
 * 修正片源里写过头的 HEVC 等级。
 *
 * <p>部分片源（常见于转码或拼接过的 MP4）在 hvcC 里把 general_level_idc 写成 Level 6.2，实际画面
 * 只有 1080p30 8bit。ExoPlayer 拿这个等级跟设备声明的能力比，会得出
 * NO_EXCEEDS_CAPABILITIES；Amlogic 一类电视盒子的 OMX 解码器随后在 start 阶段直接失败
 * （CodecException: start failed），最后整条视频只能走软解或直接播不出来。
 *
 * <p>等级只是能力声明，不参与实际解码：解码器按分辨率和码率工作。把声明夹到解码器支持的最高等级，
 * 画面不受影响，但能让硬解通过能力校验。只在「画面尺寸与帧率都在解码器舒适范围内」时才夹，
 * 真正的 4K120 这类片源不会被误处理。
 */
@UnstableApi
final class HevcLevelClamp {
  private static final long MAX_CLAMP_PIXELS = 3840L * 2160L;
  private static final float MAX_CLAMP_FRAMERATE = 60f;
  /** hvcC 里 general_level_idc 的下标：1 字节版本 + 1 字节 profile + 4 字节兼容位 + 6 字节约束位。 */
  private static final int LEVEL_OFFSET = 12;

  private HevcLevelClamp() {}

  static Format clamp(Format format, MediaCodecInfo codecInfo) {
    if (codecInfo == null || format == null) return format;
    if (!MimeTypes.VIDEO_H265.equals(format.sampleMimeType)) return format;
    if (format.width <= 0 || format.height <= 0) return format;
    if ((long) format.width * format.height > MAX_CLAMP_PIXELS) return format;
    if (format.frameRate > MAX_CLAMP_FRAMERATE) return format;

    List<byte[]> initData = format.initializationData;
    if (initData == null || initData.isEmpty()) return format;
    byte[] csd = initData.get(0);
    if (csd == null || csd.length <= LEVEL_OFFSET || (csd[0] & 0xFF) != 1) return format;

    int level = csd[LEVEL_OFFSET] & 0xFF;
    int profile = csd[1] & 0x1F;
    int maxLevel = maxLevelFor(codecInfo, profile);
    if (maxLevel <= 0 || level <= maxLevel) return format;
    // 画面本身要是真超出解码器能力，夹等级也没用，交回 ExoPlayer 走软解回退。
    int needed = requiredLevel(format.width, format.height, format.frameRate);
    if (needed <= 0 || maxLevel < needed) return format;

    byte[] patched = csd.clone();
    patched[LEVEL_OFFSET] = (byte) Math.min(level, maxLevel);
    ArrayList<byte[]> replaced = new ArrayList<>(initData);
    replaced.set(0, patched);
    return format.buildUpon().setInitializationData(replaced).build();
  }

  /** 取解码器对该 profile 声明的最高等级；没有该 profile 时退到该 mime 的最高等级。 */
  private static int maxLevelFor(MediaCodecInfo codecInfo, int profile) {
    android.media.MediaCodecInfo.CodecProfileLevel[] levels = codecInfo.getProfileLevels();
    if (levels == null) return 0;
    int matched = 0;
    int any = 0;
    for (android.media.MediaCodecInfo.CodecProfileLevel item : levels) {
      if (item.level > any) any = item.level;
      if (item.profile == profile && item.level > matched) matched = item.level;
    }
    return matched > 0 ? matched : any;
  }

  /** 按分辨率和帧率估算画面本身需要的 HEVC 等级，用于判断夹等级是否安全。 */
  private static int requiredLevel(int width, int height, float frameRate) {
    long pixels = (long) width * height;
    float rate = frameRate > 0 ? frameRate : 30f;
    if (pixels <= 1280L * 720L) return rate <= 30f ? 93 : 120;
    if (pixels <= 1920L * 1088L) return rate <= 30f ? 120 : 123;
    if (pixels <= 2560L * 1440L) return rate <= 30f ? 150 : 153;
    return rate <= 30f ? 153 : 156;
  }
}
