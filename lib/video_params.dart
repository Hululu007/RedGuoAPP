/// 视频参数快照。
///
/// 原先直接复用 media_kit 的 `VideoParams`；去掉 mpv 内核后本地保留同名类型，
/// 让会话层、UI 层和测试的调用点保持原样。
class VideoParams {
  const VideoParams({
    this.w,
    this.h,
    this.dw,
    this.dh,
    this.rotate,
    this.pixelformat,
    this.hwPixelformat,
  });

  /// 编码尺寸。
  final int? w;
  final int? h;

  /// 显示尺寸（容器声明的宽高），为空时回退到编码尺寸。
  final int? dw;
  final int? dh;

  /// 容器旋转角度，只有 90 需要交换宽高。
  final int? rotate;

  final String? pixelformat;
  final String? hwPixelformat;

  bool get isEmpty => (w ?? 0) <= 0 || (h ?? 0) <= 0;

  @override
  String toString() => 'VideoParams(${w ?? 0}x${h ?? 0})';
}
