import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from app_build import app

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'])
options = parser.parse_args()
env = os.environ.copy()
if platform.system() == 'Darwin':
    env['LANG'] = 'en_US.UTF-8'
    env['LC_ALL'] = 'en_US.UTF-8'
env.setdefault('GOPROXY', 'https://goproxy.cn,direct')
env.setdefault('GOSUMDB', 'off')
# 国外 CI 直连官方源更快；本地/国内环境走镜像，否则 Gradle 拉
# io.flutter:*_release 引擎产物会卡在 download.flutter.io 上十几分钟。
if not env.get('CI') and not env.get('GITHUB_ACTIONS'):
    env.setdefault('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn')
    env.setdefault('PUB_HOSTED_URL', 'https://pub.flutter-io.cn')
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')
abi_args = [item for abi in options.abi or [] for item in ['--abi', abi]]
# 内置站源：构建前从 RedGuoAPI 精简包（index.json + modules/）拉全部模块，
# 按索引版本校验后写入 bundled-modules/。拉不到时沿用本地已有副本，避免网络抖动把整次构建带崩。
subprocess.run([sys.executable, str(root / 'scripts' / 'fetch_module.py'), '--offline-ok'],
               cwd=root, env=env, check=True)
# 精简包里的模块全部内置，hongguo 排第一；没拉到任何模块时跳过 --bundle。
bundle_root = root / 'bundled-modules'
bundle_dirs = sorted(
    (path.parent for path in bundle_root.glob('*/main.js') if path.is_file()),
    key=lambda path: (path.name != 'hongguo', path.name)) if bundle_root.is_dir() else []
bundle_args = [item for path in bundle_dirs for item in ('--bundle', str(path))]
subprocess.run([sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'android', *abi_args, *bundle_args],
               cwd=root, env=env, check=True)
subprocess.run([flutter, 'pub', 'get'], cwd=root, env=env, check=True)

# --split-per-abi 一次构建同时出两个包。Flutter 默认会给每个 ABI 的
# versionCode 加偏移（+1000 × ABI序号，见 FlutterPlugin.kt 的 versionCodeOverride），
# 让设备读到的内部号与清单里的基准值对不上。android/gradle.properties 里的
# force-version-code-ignoring-abi=true 关掉了这个覆盖，两个包都等于设定值。
targets = {'arm64-v8a': 'android-arm64', 'armeabi-v7a': 'android-arm', 'x86_64': 'android-x64'}
abis = options.abi or ['arm64-v8a', 'armeabi-v7a']
subprocess.run(
    [flutter, 'build', 'apk', '--release', '--split-per-abi', '--no-pub',
     '--target-platform', ','.join(targets[abi] for abi in abis), *app.flutter_arguments],
    cwd=root, env=env, check=True)
subprocess.run([sys.executable, str(root / 'scripts' / 'package_release.py'), '--platform', 'android', *abi_args],
               cwd=root, env=env, check=True)
