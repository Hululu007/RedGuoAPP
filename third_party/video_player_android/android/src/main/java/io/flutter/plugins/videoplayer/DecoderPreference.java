// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

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
