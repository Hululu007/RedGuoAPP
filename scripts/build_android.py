import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import zipfile
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
# 内置站源：正式 APK 只内置红果（hongguo），其他站源由用户按需安装。
# 拉取失败时仅允许沿用本地红果副本，避免旧模块残留进安装包。
subprocess.run([sys.executable, str(root / 'scripts' / 'fetch_module.py'), '--id', 'hongguo', '--offline-ok'],
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

# Android 产物在本脚本内直接校验并整理，不再依赖已移除的
# scripts/package_release.py。保持原有 dist/android 文件名，兼容发布工作流。
match = re.search(r'^version:\\s*([\\w.+-]+)\\s*$', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE)
if not match:
    raise SystemExit('pubspec.yaml 缺少合法版本号。')
version = match.group(1)
output = root / 'dist' / 'android'
output.mkdir(parents=True, exist_ok=True)

for abi in abis:
    source = root / 'build' / 'app' / 'outputs' / 'flutter-apk' / f'app-{abi}-release.apk'
    if not source.is_file():
        raise SystemExit('缺少 APK：' + str(source))
    with zipfile.ZipFile(source) as archive:
        names = set(archive.namelist())
        required = [f'lib/{abi}/{library}' for library in
                    ['libduanju_core.so', 'libflutter.so', 'libapp.so', 'libmpv.so', 'libffmpegkit.so']]
        missing = set(required) - names
        if missing:
            raise SystemExit('APK 缺少原生库：' + ', '.join(sorted(missing)))
    target = output / f'{app.slug}-{version}-{abi}.apk'
    shutil.copy2(source, target)
    print(f'Android APK 已打包：{target}')
