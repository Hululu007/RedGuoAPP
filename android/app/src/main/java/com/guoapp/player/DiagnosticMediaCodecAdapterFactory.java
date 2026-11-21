// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package com.guoapp.player;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.media3.exoplayer.mediacodec.DefaultMediaCodecAdapterFactory;
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import java.io.IOException;

/**
 * 记录 MediaCodec 创建失败的适配器工厂。
 *
 * <p>{@link MediaCodecAdapter.Factory#createAdapter} 内部会完成 MediaCodec 的创建、configure
 * 和 start。也就是说它成功返回，就意味着解码器已经真正跑起来了；它抛异常，就是硬解初始化
 * 失败的直接原因。ExoPlayer 会把异常吞掉并静默回退软解，这里把它记下来。
 */
public final class DiagnosticMediaCodecAdapterFactory implements MediaCodecAdapter.Factory {

  private final MediaCodecAdapter.Factory delegate;

  public DiagnosticMediaCodecAdapterFactory(@NonNull Context context) {
    this.delegate = new DefaultMediaCodecAdapterFactory(context);
  }

  @NonNull
  @Override
  public MediaCodecAdapter createAdapter(@NonNull MediaCodecAdapter.Configuration configuration)
      throws IOException {
    try {
      MediaCodecAdapter adapter = delegate.createAdapter(configuration);
      // 走到这里说明 configure 与 start 都成功了，记录真正用上的解码器。
      MediaCodecInfo codecInfo = configuration.codecInfo;
      String mime = configuration.format.sampleMimeType;
      // 标注音频/视频：音频 AAC 本来就是软解，不标轨道类型会被当成
      // 「视频掉到软解」的误报。
      String track =
          mime != null && mime.startsWith("audio/")
              ? "音频"
              : mime != null && mime.startsWith("video/") ? "视频" : "";
      DecoderPreference.addDiagnostic(
          (track.isEmpty() ? "" : track + " ")
              + "实际使用解码器："
              + codecInfo.name
              + (codecInfo.softwareOnly ? "(软解)" : "(硬解)")
              + (mime == null ? "" : "（" + mime + "）"));
      return adapter;
    } catch (IOException | RuntimeException error) {
      DecoderPreference.addDiagnostic(
          "MediaCodec 初始化失败："
              + error.getClass().getSimpleName()
              + ": "
              + error.getMessage()
              + "（格式 "
              + configuration.format.sampleMimeType
              + "）");
      throw error;
    }
  }
}
