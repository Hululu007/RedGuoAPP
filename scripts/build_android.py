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
subprocess.run([sys.executable, str(root / 'scripts' / 'build_native.py'), '--platform', 'android', *abi_args],
               cwd=root, env=env, check=True)
subprocess.run([flutter, 'pub', 'get'], cwd=root, env=env, check=True)

# 不用 --split-per-abi：AGP 会给每个 ABI 拆分包按序号加 1000 的 versionCode
# 偏移（实测 +2000/+3000），客户端拿清单里的基准值比较就永远判成「已是最新」。
# 改成每个架构单独构建一次，靠 ONLY_ABI 裁掉其余架构的 so，版本号才是精确值，
# 包体也和拆分包一样小。
targets = {'arm64-v8a': 'android-arm64', 'armeabi-v7a': 'android-arm', 'x86_64': 'android-x64'}
apk_dir = root / 'build' / 'app' / 'outputs' / 'flutter-apk'
for abi in options.abi or ['arm64-v8a', 'armeabi-v7a']:
    build_env = dict(env, ONLY_ABI=abi)
    subprocess.run(
        [flutter, 'build', 'apk', '--release', '--no-pub',
         f'--target-platform={targets[abi]}', *app.flutter_arguments],
        cwd=root, env=build_env, check=True)
    # package_release.py 按 app-<abi>-release.apk 找产物，这里对齐成同样的名字。
    shutil.copy2(apk_dir / 'app-release.apk', apk_dir / f'app-{abi}-release.apk')
subprocess.run([sys.executable, str(root / 'scripts' / 'package_release.py'), '--platform', 'android', *abi_args],
               cwd=root, env=env, check=True)
