# 本地改动说明

上游版本：`video_player_android 2.12.4`。仅改 ExoPlayer 的解码器选择，其余保持原样。
升级上游时把下面两处补丁重新应用一遍即可。

## 1. 打开解码器回退

`android/src/main/java/io/flutter/plugins/videoplayer/texture/TextureVideoPlayer.java`
`android/src/main/java/io/flutter/plugins/videoplayer/platformview/PlatformViewVideoPlayer.java`

```java
DefaultRenderersFactory renderersFactory =
    new DefaultRenderersFactory(context).setEnableDecoderFallback(true);
if (DecoderPreference.softwareOnly) {
  renderersFactory.setMediaCodecSelector(DecoderPreference.SOFTWARE_ONLY);
}
ExoPlayer.Builder builder = new ExoPlayer.Builder(context, renderersFactory);
```

`DefaultRenderersFactory` 默认 `enableDecoderFallback = false`，硬件解码器初始化失败会直接抛
`MediaCodecVideoRenderer error`，不会尝试系统软解，换线路也没用。

## 2. 新增 DecoderPreference

`android/src/main/java/io/flutter/plugins/videoplayer/DecoderPreference.java`

- `softwareOnly`：由 Flutter 侧「解码方式」经 `duanju/device` 通道的 `setDecoderMode` 置位；
- `SOFTWARE_ONLY`：只返回 `MediaCodecInfo.softwareOnly` 的解码器，该类格式没有软解时退回默认列表。

## 3. 应用侧兜底

`lib/playback_session.dart` 的 `_swapKernelToMpv`：Exo 报解码类错误时保持线路和进度不变，
换 MPV 内核续播，并在 `LocalStore` 记下 `exoDecoderBroken`，之后开播直接用 MPV；
在设置里重新选回 ExoPlayer 会清掉该标记。
