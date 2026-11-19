import 'package:duanju_app/playback_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MediaCodec 硬解失败算解码问题', () {
    const message =
        'PlatformException(VideoError, Video player had error qp: '
        'MediaCodecVideoRenderer error, index=0, format=Format(1, null, '
        'video/mp4, video/hevc, hvc1.1.6.L186.334510, und, [1920, 1080, '
        '30.000002], ...), format_supported=true, null)';
    expect(isDecoderFailure(message), isTrue);
  });

  test('解码器初始化异常算解码问题', () {
    expect(
      isDecoderFailure('DecoderInitializationException: Decoder init failed'),
      isTrue,
    );
    expect(isDecoderFailure('no decoder for video/av01'), isTrue);
  });

  test('网络与片源错误不算解码问题', () {
    expect(
      isDecoderFailure(
        'PlatformException(VideoError, Video player had error '
        r'Source error: HttpDataSource$HttpDataSourceException: 403, null)',
      ),
      isFalse,
    );
    expect(isDecoderFailure('读取播放地址超时'), isFalse);
    expect(isDecoderFailure(''), isFalse);
  });
}
