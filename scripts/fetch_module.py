#!/usr/bin/env python3
"""从 RedGuoAPI 的**精简包**（index.json + modules/）拉取内置站源，写入 bundled-modules/。

默认只拉取 hongguo；--id 可显式指定需要内置的模块。正式构建只内置红果。
精简索引不带 sha256，因此按索引声明的 version 与模块 manifest 逐一对齐校验，
版本对不上说明 CDN 缓存串版，换下一个源重试；条目里有 sha256 时仍然严格校验。
构建脚本在打包前调用，保证内置站源和线上发布一致，不用手工往仓库里塞副本。
"""

import argparse
import hashlib
import json
import shutil
import sys
import urllib.request
from pathlib import Path

# 精简索引：GitHub 直连优先，jsDelivr 兜底（国内环境更稳）
INDEX_URLS = (
    'https://raw.githubusercontent.com/xycvip/RedGuoAPI/refs/heads/main/index.json',
    'https://cdn.jsdelivr.net/gh/xycvip/RedGuoAPI@main/index.json',
)
# 精简包模块文件：走 main 分支，再退 CDN
FILE_URLS = (
    'https://raw.githubusercontent.com/{repo}/refs/heads/main/{path}/{name}',
    'https://cdn.jsdelivr.net/gh/{repo}@main/{path}/{name}',
)
MODULE_FILES = ('manifest.json', 'main.js')
PRIMARY = 'hongguo'
LIMIT = 4 << 20


def fetch(url, timeout=45):
    req = urllib.request.Request(url, headers={'User-Agent': 'RedGuo-Build'})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        data = response.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError('响应超过 %d 字节' % LIMIT)
    return data


def load_index():
    error = None
    for url in INDEX_URLS:
        try:
            index = json.loads(fetch(url).decode('utf-8'))
        except Exception as exc:  # 换下一个镜像
            error = '%s: %s' % (url, exc)
            print('索引不可用 %s（%s）' % (url, exc), flush=True)
            continue
        if not index.get('modules'):
            error = '%s: 索引里没有模块' % url
            continue
        print('精简索引 ← %s（%d 个模块）' % (url, len(index['modules'])), flush=True)
        return index
    raise SystemExit('模块索引全部失败：%s' % error)


def select(entries, ids):
    """默认只选择红果；显式指定 id 时仅选择指定模块。"""
    if ids:
        by_id = {item.get('id'): item for item in entries}
        missing = [i for i in ids if i not in by_id]
        if missing:
            raise SystemExit('索引里没有模块 %s' % '、'.join(missing))
        return [by_id[i] for i in ids]
    by_id = {item.get('id'): item for item in entries}
    if PRIMARY not in by_id:
        raise SystemExit('精简索引里没有红果内置源 hongguo')
    return [by_id[PRIMARY]]


def download(entry, name):
    """下载单个文件并校验，返回内容。"""
    repo = entry['repo']
    path = (entry.get('path') or '').strip('/')
    if not path:
        raise SystemExit('索引缺少 %s 的 path' % entry.get('id'))
    expected = (entry.get('sha256') or {}).get(name, '')

    failures = []
    for pattern in FILE_URLS:
        url = pattern.format(repo=repo, path=path, name=name)
        try:
            data = fetch(url)
        except Exception as exc:
            failures.append('%s（%s）' % (url, exc))
            continue
        if expected:
            actual = hashlib.sha256(data).hexdigest()
            if actual != expected:
                failures.append('%s（sha256 不符 %s）' % (url, actual[:12]))
                continue
        print('  %s ← %s' % (name, url), flush=True)
        return data
    raise SystemExit('下载 %s 失败：\n  %s' % (name, '\n  '.join(failures)))


def verify(entry, manifest):
    """精简索引没有 sha256，用版本号锁死内容，避免 CDN 缓存串版。"""
    module_id = entry.get('id')
    if manifest.get('id') != module_id:
        raise SystemExit('模块 id 不匹配：索引 %s，清单 %s' % (module_id, manifest.get('id')))
    want = str(entry.get('version') or '')
    got = str(manifest.get('version') or '')
    if want and got != want:
        raise SystemExit('模块 %s 版本不符：索引 %s，实际 %s' % (module_id, want, got))


def prune(dest_root, keep):
    """删掉索引里已经没有的旧模块，避免被一起打进内置核心。"""
    if not dest_root.is_dir():
        return
    for child in dest_root.iterdir():
        if child.is_dir() and child.name not in keep:
            print('  移除过期模块 %s' % child.name, flush=True)
            shutil.rmtree(child)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--id', action='append', default=[],
                        help='只拉指定模块，可多次指定；默认只拉红果 hongguo')
    parser.add_argument('--dest', default='bundled-modules',
                        help='输出目录，默认 bundled-modules')
    parser.add_argument('--offline-ok', action='store_true',
                        help='拉取失败时保留已有文件，不中断构建')
    options = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    dest_root = Path(options.dest)
    if not dest_root.is_absolute():
        dest_root = root / dest_root

    try:
        index = load_index()
    except SystemExit as exc:
        keep = set(options.id or [PRIMARY])
        ready = all((dest_root / i / 'main.js').is_file() and
                    (dest_root / i / 'manifest.json').is_file() for i in keep)
        if options.offline_ok and ready:
            print('索引不可用，仅沿用已有红果内置源：%s' % exc, flush=True)
            prune(dest_root, keep)
            return
        raise

    entries = select(index['modules'], options.id)
    print('内置站源 %d 个：%s' % (len(entries), '、'.join(item['id'] for item in entries)), flush=True)

    kept = set()
    for entry in entries:
        module_id = entry['id']
        version = entry.get('version', '?')
        print('内置模块 %s %s' % (module_id, version), flush=True)

        try:
            payload = {name: download(entry, name) for name in MODULE_FILES}
            manifest = json.loads(payload['manifest.json'].decode('utf-8'))
            verify(entry, manifest)
        except SystemExit:
            if options.offline_ok and all((dest_root / module_id / n).is_file() for n in MODULE_FILES):
                print('拉取失败，沿用已有模块 %s' % module_id, flush=True)
                kept.add(module_id)
                continue
            raise

        target = dest_root / module_id
        target.mkdir(parents=True, exist_ok=True)
        for name, data in payload.items():
            (target / name).write_bytes(data)
        kept.add(module_id)
        print('  校验通过，已写入 %s' % target, flush=True)

    prune(dest_root, kept)


if __name__ == '__main__':
    sys.exit(main())
