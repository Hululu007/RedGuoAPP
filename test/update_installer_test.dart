import 'package:duanju_app/update_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('线路字符串还原，未知值回到自动', () {
    expect(parseUpdateChannel('auto'), UpdateChannel.auto);
    expect(parseUpdateChannel('domestic'), UpdateChannel.domestic);
    expect(parseUpdateChannel('direct'), UpdateChannel.direct);
    expect(parseUpdateChannel('proxy'), UpdateChannel.proxy);
    expect(parseUpdateChannel(''), UpdateChannel.auto);
    expect(parseUpdateChannel('something'), UpdateChannel.auto);
    expect(parseUpdateChannel(null), UpdateChannel.auto);
  });

  test('线路持久化值与枚举同名', () {
    for (final channel in UpdateChannel.values) {
      expect(parseUpdateChannel(channel.value), channel);
    }
  });

  test('手动代理转成 findProxy 字符串', () {
    expect(proxyFrom('manual', '127.0.0.1:7890'), 'PROXY 127.0.0.1:7890');
    expect(proxyFrom('manual', '127.0.0.1'), 'PROXY 127.0.0.1:80');
    expect(
      proxyFrom('manual', 'http://127.0.0.1:7890'),
      'PROXY 127.0.0.1:7890',
    );
    expect(proxyFrom('manual', ''), '');
    expect(proxyFrom('manual', 'https://127.0.0.1:7890'), '');
    expect(proxyFrom('auto', '127.0.0.1:7890'), '');
  });
}
